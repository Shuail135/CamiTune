import CamiTuneAudio
import CamiTuneDomain
import AVFoundation
import Foundation

/// Serializes retention, manifest commits and quit-time cleanup. A retained file
/// awaiting its manifest must survive cleanup if an import is still finishing.
private final class RoomRecordingFileAccess: @unchecked Sendable {
    static let shared = RoomRecordingFileAccess()
    let lock = NSLock()
    var pendingImports: Set<URL> = []
}

struct RoomMeasurementStore: Sendable {
    var directory = CamiTunePaths.supportDirectory.appendingPathComponent("RoomMeasurements", isDirectory: true)
    func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    func save(_ session: RoomMeasurementSession) throws {
        let access = RoomRecordingFileAccess.shared
        access.lock.lock(); defer { access.lock.unlock() }
        try session.validate()
        let folder = folder(session.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(session).write(to: folder.appendingPathComponent("session.plist"), options: .atomic)
        for recording in session.recordings {
            access.pendingImports.remove(folder.appendingPathComponent(recording.fileName).standardizedFileURL)
        }
    }
    func load(_ id: UUID) throws -> RoomMeasurementSession {
        let url = folder(id).appendingPathComponent("session.plist")
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 100_000_000 else { throw RoomCorrectionError.invalidSession }
        let session = try PropertyListDecoder().decode(RoomMeasurementSession.self, from: Data(contentsOf: url))
        guard session.id == id, session.measurementFormatVersion == 1, session.measurementSignalVersion == 1 else { throw RoomCorrectionError.invalidSession }
        try session.validate()
        return session
    }
    func retain(_ url: URL, sessionID: UUID, blocks: [RoomMeasurementBlock], format: String, isLossy: Bool) throws -> RoomRecordingReference {
        let access = RoomRecordingFileAccess.shared
        access.lock.lock(); defer { access.lock.unlock() }
        let name = UUID().uuidString.lowercased() + "." + url.pathExtension.lowercased()
        try FileManager.default.createDirectory(at: folder(sessionID), withIntermediateDirectories: true)
        let destination = folder(sessionID).appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: destination)
        access.pendingImports.insert(destination.standardizedFileURL)
        return .init(fileName: name, sourceFormat: format, isLossy: isLossy, blockIDs: blocks.map(\.id))
    }
    /// Only removes app-generated files absent from a readable session manifest.
    /// Referenced recordings (including shared sessions), originals, unknown
    /// files, symbolic links and files still being imported remain untouched.
    @discardableResult
    func removeUnreferencedRecordings() throws -> Int {
        let access = RoomRecordingFileAccess.shared
        access.lock.lock(); defer { access.lock.unlock() }
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var removed = 0
        for folder in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let attributes = try? folder.resourceValues(forKeys: keys),
                  attributes.isDirectory == true, attributes.isSymbolicLink != true,
                  let manifest = try? folder.appendingPathComponent("session.plist").resourceValues(forKeys: keys),
                  manifest.isRegularFile == true, manifest.isSymbolicLink != true,
                  let session = try? load(id) else { continue }
            let referenced = Set(session.recordings.map(\.fileName))
            for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) {
                guard !referenced.contains(file.lastPathComponent), !file.pathExtension.isEmpty,
                      UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                      !access.pendingImports.contains(file.standardizedFileURL),
                      let attributes = try? file.resourceValues(forKeys: keys),
                      attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
                try manager.removeItem(at: file)
                removed += 1
            }
        }
        return removed
    }
    func recordingURL(_ reference: RoomRecordingReference, sessionID: UUID) throws -> URL {
        guard URL(fileURLWithPath: reference.fileName).lastPathComponent == reference.fileName,
              !reference.fileName.contains("..") else { throw RoomCorrectionError.invalidSession }
        return folder(sessionID).appendingPathComponent(reference.fileName)
    }
    static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { throw RoomCorrectionError.invalidSession }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
    static func read(_ url: URL) throws -> (samples: [Float], rate: Double, format: String, isLossy: Bool) {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 1_000_000_000 else { throw RoomCorrectionError.invalidSession }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat, rate = format.sampleRate
        guard rate.isFinite, (8000...192000).contains(rate), (1...8).contains(format.channelCount),
              file.length > 0, file.length <= 57_600_000, Double(file.length) / rate <= 1200,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw RoomCorrectionError.invalidSession }
        var samples: [Float] = []; samples.reserveCapacity(Int(file.length))
        // Use one microphone lane, avoiding destructive stereo downmix cancellation.
        var selectedChannel = 0
        if format.channelCount > 1 {
            // Inspect the complete recording: its first packet may be silent or contain speech.
            // Two bounded passes avoid retaining all microphone lanes in memory.
            var energies = [Double](repeating: 0, count: Int(format.channelCount))
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: 8192)
                guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
                for channel in energies.indices {
                    for frame in 0..<Int(buffer.frameLength) {
                        let sample = Double(data[channel][frame])
                        if sample.isFinite { energies[channel] += sample * sample }
                    }
                }
            }
            selectedChannel = energies.indices.max { energies[$0] < energies[$1] } ?? 0
            file.framePosition = 0
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: 8192)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[selectedChannel], count: Int(buffer.frameLength)))
        }
        guard samples.allSatisfy(\.isFinite) else { throw RoomCorrectionError.invalidSession }
        let codec = file.fileFormat.streamDescription.pointee.mFormatID
        return (samples, rate, url.pathExtension.lowercased(), codec != kAudioFormatLinearPCM && codec != kAudioFormatAppleLossless && codec != kAudioFormatFLAC)
    }
    static func analyze(_ recording: (samples: [Float], rate: Double, format: String, isLossy: Bool),
                        blocks: [RoomMeasurementBlock], session: RoomMeasurementSession) throws -> RoomMeasurementSession {
        var session = session
        var observations: [UUID: [Int: [RoomChannelObservation]]] = [:]
        var matched: [(block: RoomMeasurementBlock, response: RoomChannelObservation)] = []
        let prepared = try RoomMeasurementAnalyzer.Recording(samples: recording.samples, sampleRate: recording.rate, isLossy: recording.isLossy)
        var issues: [RoomMeasurementIssue] = []
        var clockAnchors: [UUID: (host: Double, recorded: Double, ratio: Double)] = [:]
        var firstFailure: Error?
        for block in blocks {
            try Task.checkCancellation()
            do {
                let hint: Double?
                if let clock = block.playbackClockID, let host = block.playbackStartTime, host.isFinite,
                   let anchor = clockAnchors[clock] {
                    hint = anchor.recorded + (host - anchor.host) * anchor.ratio
                } else { hint = nil }
                let response = try RoomMeasurementAnalyzer().analyze(recording: prepared,
                    block: block, playbackRate: session.context.topology.sampleRate, calibration: session.source.calibration,
                    expectedMarkerTime: hint)
                if let clock = block.playbackClockID, let host = block.playbackStartTime, host.isFinite,
                   let marker = response.recordingMarkerTime {
                    clockAnchors[clock] = (host, marker, response.clockRatio)
                }
                matched.append((block, response))
            } catch is CancellationError { throw CancellationError() }
            catch {
                if firstFailure == nil { firstFailure = error }
                let missing: Bool
                if case RoomCorrectionError.missingBlocks = error { missing = true } else { missing = false }
                issues.append(.init(positionID: block.positionID, channel: block.channel, missingSweep: missing))
                continue
            }
        }
        // Different speaker/position codes cannot own overlapping sweeps.
        // Resolve a weak cross-match in favour of the stronger paired markers.
        for (index, match) in matched.enumerated() {
            let conflict = matched.enumerated().contains { otherIndex, other in
                guard index != otherIndex, let a = match.response.recordingMarkerTime,
                      let b = other.response.recordingMarkerTime, abs(a - b) < 5.05 else { return false }
                let quality = match.response.markerConfidence ?? 0, otherQuality = other.response.markerConfidence ?? 0
                return otherQuality > quality || (otherQuality == quality && otherIndex < index)
            }
            if conflict { issues.append(.init(positionID: match.block.positionID, channel: match.block.channel, missingSweep: true)); continue }
            observations[match.block.positionID, default: [:]][match.block.channel, default: []].append(match.response)
        }
        guard !observations.isEmpty else { throw firstFailure ?? RoomCorrectionError.missingBlocks }
        for i in session.positions.indices {
            guard let channels = observations[session.positions[i].id] else { continue }
            for (channel, takes) in channels {
                var observation = takes.last!
                if takes.count >= 2 {
                    observation = compareRepeats(takes[takes.count - 2], observation, recorder: session.source.kind == .recorder)
                } else if blocks.contains(where: { $0.positionID == session.positions[i].id && $0.channel == channel && $0.isRepeat }),
                          let previous = session.positions[i].observations.first(where: { $0.channel == channel }) {
                    observation = compareRepeats(previous, observation, recorder: session.source.kind == .recorder)
                } else if session.positions[i].isMain {
                    observation.timingEligible = false; observation.relativeTimingEligible = false
                }
                session.positions[i].observations.removeAll { $0.channel == channel }
                session.positions[i].observations.append(observation)
            }
        }
        let analyzedIDs = Set(blocks.map(\.positionID))
        session.analysisIssues = (session.analysisIssues ?? []).filter { !analyzedIDs.contains($0.positionID) } + issues
        session.measurementAnalysisVersion = 2; session.roomAnalysisVersion = 2
        return session
    }
    /// A phone's AGC may change overall gain between the normal and quieter
    /// sweeps. Preserve repeatable shape, but never turn that into trusted level
    /// or alignment data. Frequency-dependent changes still reduce confidence.
    private static func compareRepeats(_ first: RoomChannelObservation, _ next: RoomChannelObservation, recorder: Bool) -> RoomChannelObservation {
        guard first.bins.count == next.bins.count,
              zip(first.bins, next.bins).allSatisfy({ abs(log2($0.frequency / $1.frequency)) < 0.001 }) else {
            var result = first; result.timingEligible = false; result.relativeTimingEligible = false; return result
        }
        let differences = zip(first.bins, next.bins).map { $1.magnitudeDB - $0.magnitudeDB }
        let usable = first.bins.indices.filter {
            first.bins[$0].snrDB > 18 && next.bins[$0].snrDB > 18 && (100...8000).contains(first.bins[$0].frequency)
        }
        let offsets = usable.map { differences[$0] }.sorted()
        let gain = offsets.isEmpty ? 0 : offsets[offsets.count / 2]
        let residuals = usable.map { abs(differences[$0] - gain) }.sorted()
        let shape = residuals.isEmpty ? 100 : residuals[residuals.count / 2]
        let difference = differences.map(abs).reduce(0, +) / Double(max(1, differences.count))
        var result = recorder ? first : next
        result.repeatDifferenceDB = difference; result.repeatGainDifferenceDB = gain; result.repeatShapeDifferenceDB = shape
        let clockAgrees = abs(first.clockRatio - next.clockRatio) < 0.0002
        result.timingEligible = first.timingEligible && next.timingEligible && difference < 2 && clockAgrees
        for i in result.bins.indices {
            let residual = recorder && usable.count >= 12 ? abs(differences[i] - gain) : abs(differences[i])
            let gainTrust = recorder && abs(gain) > 1 ? 0.85 : 1.0
            let shapeTrust = recorder && shape > 3 ? 0.4 : 1.0
            result.bins[i].reliability = min(first.bins[i].reliability, next.bins[i].reliability)
                * max(0, 1 - residual / 6) * gainTrust * shapeTrust
            let delta = first.bins[i].phase - next.bins[i].phase
            let phaseError = abs(atan2(sin(delta), cos(delta)))
            let delayError = abs((first.bins[i].groupDelayMS ?? 0) - (next.bins[i].groupDelayMS ?? 0))
            let delayLimit = max(0.15, 300 / first.bins[i].frequency)
            let agrees = clockAgrees && first.hasUsableImpulse && next.hasUsableImpulse
                && phaseError < .pi / 6 && usable.count >= 12
            result.bins[i].timingReliability = agrees ? min(0.75, result.bins[i].reliability) : 0
            if !agrees || delayError >= delayLimit { result.bins[i].groupDelayMS = nil }
        }
        result.relativeTimingEligible = result.bins.filter { ($0.timingReliability ?? 0) > 0.4 }.count >= 12
        result.timingEligible = result.timingEligible && result.relativeTimingEligible == true
            && result.bins.filter { ($0.timingReliability ?? 0) > 0.4 && $0.groupDelayMS != nil }.count >= 24
        return result
    }
    static func materialize(_ design: RoomCorrectionDesign, store: ImpulseResponseStore = .init()) throws -> RoomCorrectionResult {
        var result = design.result
        for (channel, samples) in design.impulses {
            try Task.checkCancellation()
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("room-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try writeWAV(samples: samples, sampleRate: result.context.topology.sampleRate, to: temporary)
            var asset = try store.importWAV(at: temporary, expectedSampleRate: Int(result.context.topology.sampleRate))
            asset.displayName = "Room Correction · Channel \(channel + 1)"
            result.channelFIR[channel] = .init(asset: asset)
        }
        return result
    }
}
