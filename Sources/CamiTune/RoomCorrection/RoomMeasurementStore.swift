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
        try RoomRecordingAnalyzer.analyze(recording, blocks: blocks, session: session)
    }
    /// Calibration edits always start from retained audio, never corrected bins.
    func updatingSource(_ source: RoomMeasurementSource, in snapshot: RoomMeasurementSession,
                        force: Bool = false) throws -> RoomMeasurementSession {
        guard source.kind == snapshot.source.kind else { throw RoomCorrectionError.stale }
        var source = source
        if source.kind == .recorder { source.calibration = nil }
        try source.calibration?.validateForRoomMeasurement()
        if source.kind == .microphone, source.deviceID != snapshot.source.deviceID,
           snapshot.usablePositionCount > 0 || !snapshot.recordings.isEmpty { throw RoomCorrectionError.stale }
        let needsUpgrade = !snapshot.recordings.isEmpty
            && snapshot.measurementAnalysisVersion < RoomRecordingAnalyzer.currentAnalysisVersion
        guard force || source != snapshot.source || needsUpgrade else { return snapshot }
        var result = snapshot
        result.source = source
        if snapshot.usablePositionCount > 0 && snapshot.recordings.isEmpty { throw RoomCorrectionError.calibrationChanged }
        for i in result.positions.indices { result.positions[i].observations = [] }
        result.analysisIssues = nil
        for reference in snapshot.recordings {
            let blocks = snapshot.blocks.filter { reference.blockIDs.contains($0.id) }
            guard !blocks.isEmpty else { continue }
            let decoded = try Self.read(recordingURL(reference, sessionID: snapshot.id))
            result = try Self.analyze(decoded, blocks: blocks, session: result)
        }
        try save(result)
        return result
    }
    static func materialize(_ design: RoomCorrectionDesign, store: ImpulseResponseStore = .init()) throws -> RoomCorrectionResult {
        var result = design.result
        var created: [ImpulseResponseAsset] = []
        var committed = false
        defer {
            if !committed { for asset in created { try? FileManager.default.removeItem(at: store.url(for: asset)) } }
        }
        for (channel, samples) in design.impulses.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("room-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try writeWAV(samples: samples, sampleRate: result.context.topology.sampleRate, to: temporary)
            var asset = try store.importWAV(at: temporary, expectedSampleRate: Int(result.context.topology.sampleRate))
            created.append(asset)
            asset.displayName = "Room Correction · Channel \(channel + 1)"
            result.channelFIR[channel] = .init(asset: asset)
        }
        committed = true
        return result
    }
}
