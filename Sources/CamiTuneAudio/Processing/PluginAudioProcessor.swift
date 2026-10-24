import CamiTuneDomain
import Foundation

/// The application owns process launching and UI. The delivery worker only
/// receives an already prepared, bounded processor and never loads plug-in code.
package protocol PluginAudioProcessor: AnyObject, Sendable {
    var channelCount: Int { get }
    var tailFrames: Int { get }
    var requiresContinuousRendering: Bool { get }
    /// Uncapped tail/latency horizon for retiring a silent processing session.
    func bufferChangeTailSeconds(sampleRate: Double) -> Double
    func process(_ samples: inout [Float], sampleRate: Double, reset: Bool) -> Bool
}
package extension PluginAudioProcessor {
    var channelCount: Int { 2 }
    var requiresContinuousRendering: Bool { false }
    func bufferChangeTailSeconds(sampleRate: Double) -> Double { Double(tailFrames) / sampleRate }
}

/// Writer-owned output protection, independent of a third-party effect's bypass.
package struct PluginOutputProtection {
    private var gain: Float = 1
    private var last = [Float](repeating: 0, count: SpeakerTopology.maximumOutputChannels)
    private var transition: Int = 0
    package init() {}
    package var isTransitioning: Bool { transition > 0 }
    package mutating func beginTransition() { transition = 128 }
    package mutating func process(_ samples: inout [Float], sampleRate: Double, enabled: Bool, channelCount: Int = 2, ceiling: Float = 0.98) {
        guard (1...last.count).contains(channelCount), samples.count.isMultiple(of: channelCount) else { return }
        let release = Float(1 - exp(-1 / (max(8000, sampleRate) * 0.1)))
        for frame in 0..<(samples.count / channelCount) {
            let offset = frame * channelCount
            var peak: Float = ceiling
            for c in 0..<channelCount {
                if !samples[offset + c].isFinite { samples[offset + c] = 0 }
                peak = max(peak, abs(samples[offset + c]))
            }
            if enabled {
                let target = min(1, ceiling / peak)
                gain = target < gain ? target : gain + release * (target - gain)
            } else { gain = 1 }
            for c in 0..<channelCount {
                let value = samples[offset + c] * gain
                if transition > 0 {
                    // A continuous short transition also covers a failed helper
                    // fading to silence, without using stale plug-in output.
                    samples[offset + c] = last[c] + (value - last[c]) / Float(transition)
                } else { samples[offset + c] = value }
                last[c] = samples[offset + c]
            }
            if transition > 0 { transition -= 1 }
        }
    }
}

/// Writer-owned final mapping and protection, shared by direct hardware output
/// and offline verification. Device callbacks only consume its prepared samples.
package struct FinalOutputProcessor {
    private let inputChannels: Int
    private let outputChannels: Int
    private let channelMap: [Int]
    private let sampleRate: Double
    private var limiter = PluginOutputProtection()

    package init?(inputChannels: Int, outputChannels: Int, channelMap: [Int], sampleRate: Double) {
        guard (1...SpeakerTopology.maximumOutputChannels).contains(inputChannels),
              (1...SpeakerTopology.maximumOutputChannels).contains(outputChannels),
              channelMap.count == inputChannels, Set(channelMap).count == inputChannels,
              channelMap.allSatisfy({ (0..<outputChannels).contains($0) }),
              sampleRate.isFinite, (8000...384000).contains(sampleRate) else { return nil }
        self.inputChannels = inputChannels; self.outputChannels = outputChannels
        self.channelMap = channelMap; self.sampleRate = sampleRate
    }

    package mutating func process(_ bytes: Data) throws -> [Float] {
        guard bytes.count.isMultiple(of: inputChannels * MemoryLayout<Float>.size) else { throw Failure.incompleteFrame }
        let frames = bytes.count / (inputChannels * MemoryLayout<Float>.size)
        var mapped = [Float](repeating: 0, count: frames * outputChannels)
        bytes.withUnsafeBytes { raw in
            for frame in 0..<frames {
                for channel in 0..<inputChannels {
                    mapped[frame * outputChannels + channelMap[channel]] = raw.loadUnaligned(
                        fromByteOffset: (frame * inputChannels + channel) * MemoryLayout<Float>.size, as: Float.self)
                }
            }
        }
        limiter.process(&mapped, sampleRate: sampleRate, enabled: true, channelCount: outputChannels,
            ceiling: Float(pow(10, LimiterProcessor.standard.clipLimitDB / 20)))
        return mapped
    }

    private enum Failure: LocalizedError {
        case incompleteFrame
        var errorDescription: String? { "Incomplete direct output frame." }
    }
}
