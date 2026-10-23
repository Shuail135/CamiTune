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
    package mutating func process(_ samples: inout [Float], sampleRate: Double, enabled: Bool, channelCount: Int = 2) {
        guard (1...last.count).contains(channelCount), samples.count.isMultiple(of: channelCount) else { return }
        let release = Float(1 - exp(-1 / (max(8000, sampleRate) * 0.1)))
        for frame in 0..<(samples.count / channelCount) {
            let offset = frame * channelCount
            var peak: Float = 0.98
            for c in 0..<channelCount {
                if !samples[offset + c].isFinite { samples[offset + c] = 0 }
                peak = max(peak, abs(samples[offset + c]))
            }
            if enabled {
                let target = min(1, Float(0.98) / peak)
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
