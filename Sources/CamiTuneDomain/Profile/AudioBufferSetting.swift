import Foundation

/// Preferences and resolved engine frames are deliberately separate: Automatic
/// is never encoded as a zero-sized processing block.
package enum AudioBufferSetting: Hashable, Sendable, Codable, ExpressibleByIntegerLiteral {
    case automatic
    case fixed(Int)

    package init(integerLiteral value: Int) { self = .fixed(value) }
    package static var choices: [Self] { [.automatic] + DeviceProfile.audioBufferSizes.map(Self.fixed) }
    package var fixedFrames: Int? { if case .fixed(let frames) = self { return frames }; return nil }
    package var isSupported: Bool { self == .automatic || fixedFrames.map(DeviceProfile.audioBufferSizes.contains) == true }
    package var displayName: String {
        switch self { case .automatic: return "Automatic"; case .fixed(let frames): return "\(frames) samples" }
    }
    package init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let frames = try? value.decode(Int.self), frames > 0 { self = .fixed(frames) }
        else if (try? value.decode(String.self)) == "automatic" { self = .automatic }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid audio buffer setting") }
    }
    package func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .automatic: try value.encode("automatic"); case .fixed(let frames): try value.encode(frames) }
    }
}

/// Observations can only change a recommendation. The runtime decides when to
/// use it at verified silence or at the start of a session.
package struct AutomaticAudioBufferPolicy: Sendable {
    package struct Evidence: Sendable {
        package var audioSeconds: Double
        package var dspLoad: Double?
        package var writerLoad: Double
        package var pluginLoad: Double
        package var underruns: UInt64?
        package var deliveryFault: Bool
        package var pluginFailed: Bool
        package init(audioSeconds: Double, dspLoad: Double?, writerLoad: Double, pluginLoad: Double,
                     underruns: UInt64?, deliveryFault: Bool = false, pluginFailed: Bool = false) {
            self.audioSeconds = audioSeconds; self.dspLoad = dspLoad; self.writerLoad = writerLoad
            self.pluginLoad = pluginLoad; self.underruns = underruns
            self.deliveryFault = deliveryFault; self.pluginFailed = pluginFailed
        }
    }
    package static let sizes = DeviceProfile.audioBufferSizes + [4096, 8192]
    package private(set) var recommendedFrames: Int
    package private(set) var minimumFrames: Int
    private var stableSeconds = 0.0
    private var pressureObservations = 0
    package init(frames: Int, minimumFrames: Int = 128) {
        self.recommendedFrames = Self.sizes.contains(frames) ? frames : 1024
        self.minimumFrames = Self.sizes.contains(minimumFrames) ? minimumFrames : 128
        self.recommendedFrames = max(self.recommendedFrames, self.minimumFrames)
    }
    package static func startingFrames(sampleRate: Int) -> Int {
        Self.sizes.first { $0 >= max(1024, sampleRate * 1024 / 48000) } ?? 8192
    }
    package mutating func observe(_ evidence: Evidence, currentFrames: Int) {
        guard let index = Self.sizes.firstIndex(of: currentFrames),
              evidence.audioSeconds.isFinite, evidence.audioSeconds > 0,
              evidence.writerLoad.isFinite, evidence.writerLoad >= 0,
              evidence.pluginLoad.isFinite, evidence.pluginLoad >= 0 else { stableSeconds = 0; pressureObservations = 0; return }
        let dsp = evidence.dspLoad
        let validDSP = dsp.map { $0.isFinite && $0 >= 0 } == true
        let combined = evidence.writerLoad + (validDSP ? dsp! : 0)
        let pressure = combined >= 0.65 || evidence.pluginLoad >= 0.55
        pressureObservations = pressure ? pressureObservations + 1 : 0
        if (evidence.underruns ?? 0) > 0 || evidence.deliveryFault || evidence.pluginFailed || pressureObservations >= 3 {
            let larger = Self.sizes[min(index + 1, Self.sizes.count - 1)]
            minimumFrames = max(minimumFrames, larger)
            recommendedFrames = max(recommendedFrames, minimumFrames)
            stableSeconds = 0
            return
        }
        // Unknown clocks/load, silence, and interrupted observations cannot be
        // evidence for lowering latency. Leave generous headroom for a smaller
        // block's higher overhead and signal-dependent third-party processing.
        guard validDSP, evidence.underruns != nil, combined < 0.20,
              evidence.pluginLoad < 0.15, !evidence.pluginFailed, !evidence.deliveryFault else {
            stableSeconds = 0; return
        }
        stableSeconds += min(evidence.audioSeconds, 2)
        guard stableSeconds >= 60, recommendedFrames == currentFrames, index > 0 else { return }
        recommendedFrames = max(minimumFrames, Self.sizes[index - 1])
        stableSeconds = 0
    }
}
