import Foundation

struct ChannelActivityState: Sendable {
    var fastRMS: Float = 0
    var slowRMS: Float = 0
    var recentPeak: Float = 0
    var lastMeaningfulActivitySampleTime: Int64?
}

enum SpatialInputCapability: String, Sendable {
    case unproven, stereo, multichannel, immersiveHeight
}

struct SpatialInputDiagnostics: Sendable {
    var declaredLayout: LPCMChannelLayout
    var activeChannels: Set<Int>
    var provenChannels: Set<Int>
    var capability: SpatialInputCapability
}

/// Evidence accumulates per physical source stream, never from endpoint capacity.
/// Silence holds proven capability; seek, source reuse and format changes reset it.
struct EffectiveLayoutDetector {
    private(set) var channels: [ChannelActivityState] = []
    private var layout: LPCMChannelLayout?
    private var rate: Double = 0
    private var nextSampleTime: Int64?
    private var evidence: [Double] = []
    private var proven = Set<Int>()
    private(set) var diagnostics = SpatialInputDiagnostics(declaredLayout: .stereo,
        activeChannels: [], provenChannels: [], capability: .unproven)

    mutating func reset() { self = Self() }

    mutating func ingest(_ frame: PCMFrame, sampleTime: Int64) {
        guard (1...32).contains(frame.channelCount), frame.channelLayout.channelCount == frame.channelCount,
              frame.interleaved.count.isMultiple(of: frame.channelCount), frame.sampleRate.isFinite,
              (8000...384000).contains(frame.sampleRate), frame.frameCount > 0,
              sampleTime >= 0, sampleTime <= Int64.max - Int64(frame.frameCount) else { return }
        if layout != frame.channelLayout || rate != frame.sampleRate ||
            (nextSampleTime != nil && nextSampleTime != sampleTime) {
            reset()
            layout = frame.channelLayout; rate = frame.sampleRate
            channels = Array(repeating: ChannelActivityState(), count: frame.channelCount)
            evidence = Array(repeating: 0, count: frame.channelCount)
        }
        nextSampleTime = sampleTime + Int64(frame.frameCount)
        let seconds = Double(frame.frameCount) / rate
        var rms = [Float](repeating: 0, count: frame.channelCount)
        var peaks = rms
        for channel in 0..<frame.channelCount {
            var energy: Double = 0
            for i in 0..<frame.frameCount {
                let x = frame.interleaved[i * frame.channelCount + channel]
                if x.isFinite { energy += Double(x) * Double(x); peaks[channel] = max(peaks[channel], abs(x)) }
            }
            rms[channel] = Float(sqrt(energy / Double(frame.frameCount)))
        }
        let threshold = max(Float(0.00001), (rms.max() ?? 0) * 0.001)
        var active = Set<Int>()
        for channel in channels.indices {
            channels[channel].fastRMS += Float(1 - exp(-seconds / 0.05)) * (rms[channel] - channels[channel].fastRMS)
            channels[channel].slowRMS += Float(1 - exp(-seconds / 0.5)) * (rms[channel] - channels[channel].slowRMS)
            channels[channel].recentPeak = max(peaks[channel], channels[channel].recentPeak * Float(exp(-seconds / 0.5)))
            if rms[channel] >= threshold {
                active.insert(channel)
                channels[channel].lastMeaningfulActivitySampleTime = sampleTime + Int64(frame.frameCount)
                evidence[channel] += seconds
                if evidence[channel] >= 0.35 { proven.insert(channel) }
            } else {
                evidence[channel] = 0
                if let last = channels[channel].lastMeaningfulActivitySampleTime,
                   Double(sampleTime - last) / rate >= 20 { proven.remove(channel) }
            }
        }
        let roles = proven.map { frame.channelLayout.roles[$0] }
        let capability: SpatialInputCapability
        if roles.contains(where: { $0.speakerLayer == .height }) { capability = .immersiveHeight }
        else if roles.contains(where: { $0 != .left && $0 != .right && $0 != .unknown }) { capability = .multichannel }
        else if roles.contains(.left) || roles.contains(.right) { capability = .stereo }
        else { capability = .unproven }
        diagnostics = SpatialInputDiagnostics(declaredLayout: frame.channelLayout,
            activeChannels: active, provenChannels: proven, capability: capability)
    }
}
