import AVFoundation
import Foundation

/// Conservative low-frequency peak reduction in the measured output chain.
/// Never boosts a null or claims to separate room response from the microphone.
struct SpatialRoomCorrection {
    static let stageID = UUID(uuidString: "CA117B70-0000-4000-8000-000000000051")!

    static func bands(for measurement: SpatialAcousticProfile) -> [EQBand] {
        guard let center = measurement.positions.first(where: { $0.position == .listeningPosition }),
              center.left.signalToNoiseDB >= 18, center.right.signalToNoiseDB >= 18 else { return [] }
        let calibrated = measurement.microphoneCalibration != nil && !measurement.microphone.isBuiltIn
        let cap = calibrated ? 3.0 : 1.5
        var cuts: [(Double, Double)] = []
        for left in center.left.response where (125...500).contains(left.frequency) {
            guard left.coherence >= 0.65,
                  let right = center.right.response.first(where: { $0.frequency == left.frequency }),
                  right.coherence >= 0.65 else { continue }
            // Only peaks shared by both physical outputs justify shared EQ.
            let peak = min(left.relativeDB, right.relativeDB)
            guard peak.isFinite, peak > 2 else { continue }
            cuts.append((left.frequency, min(cap, (peak - 1) * (calibrated ? 0.6 : 0.3))))
        }
        cuts = Array(cuts.prefix(3))
        let budget = calibrated ? 6.0 : 3.0
        let scale = min(1, budget / max(0.001, cuts.reduce(0) { $0 + $1.1 }))
        return cuts.map { EQBand(kind: .peaking, frequency: $0.0, gain: -$0.1 * scale, q: 1) }
    }

    static func isApplied(to processing: ProcessingProfile) -> Bool {
        processing.global.stages.contains { $0.id == stageID }
    }

    /// The imported recording must contain this session's complete two sweeps.
    /// Limit decoding to 16 seconds from a user-specified leading trim offset.
    static func readRecording(url: URL, trimSeconds: Double) throws -> AcousticRecording {
        guard trimSeconds.isFinite, (0...120).contains(trimSeconds),
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 100_000_000 else {
            throw AcousticMeasurementError.captureFailed
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 1, format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
              file.length > 0, Double(file.length) / format.sampleRate <= 120 else {
            throw AcousticMeasurementError.captureFailed
        }
        let offset = AVAudioFramePosition(trimSeconds * format.sampleRate)
        guard offset < file.length else { throw AcousticMeasurementError.recordingTooShort }
        let count = AVAudioFrameCount(min(file.length - offset, AVAudioFramePosition(format.sampleRate * 16)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw AcousticMeasurementError.captureFailed
        }
        // Decode sequentially: some AudioFile converters seek at packet
        // granularity and return short reads. Trim exact decoded sample counts.
        var skip = Int(offset)
        var samples: [Float] = []
        samples.reserveCapacity(Int(count))
        while samples.count < Int(count) {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let request = AVAudioFrameCount(min(4_096, skip + Int(count) - samples.count))
            try file.read(into: buffer, frameCount: request)
            guard buffer.frameLength > 0 else { break }
            guard let pointer = buffer.floatChannelData?[0] else { throw AcousticMeasurementError.captureFailed }
            let discarded = min(skip, Int(buffer.frameLength))
            skip -= discarded
            let remaining = Int(buffer.frameLength) - discarded
            if remaining > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: pointer + discarded, count: remaining))
            }
        }
        return AcousticRecording(samples: samples, sampleRate: format.sampleRate, discontinuity: false)
    }
}
