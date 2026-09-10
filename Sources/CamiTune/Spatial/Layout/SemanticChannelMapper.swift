import Foundation

struct SemanticChannelMapper {
    private(set) var left: Int?
    private(set) var right: Int?
    private(set) var center: Int?
    private(set) var lfe: Int?
    private(set) var sideLeft: Int?
    private(set) var sideRight: Int?
    private(set) var rearLeft: Int?
    private(set) var rearRight: Int?

    init(layout: LPCMChannelLayout) {
        let roles = layout.roles
        left = roles.firstIndex(of: .left)
        right = roles.firstIndex(of: .right)
        center = roles.firstIndex(of: .center)
        lfe = roles.firstIndex(of: .lowFrequencyEffects)
        sideLeft = roles.firstIndex(of: .leftSurround)
        sideRight = roles.firstIndex(of: .rightSurround)
        rearLeft = roles.firstIndex(of: .leftRearSurround)
        rearRight = roles.firstIndex(of: .rightRearSurround)
        if left == nil, right == nil, center == nil {
            if roles.first == .unknown { left = 0 }
            if roles.count > 1, roles[1] == .unknown { right = 1 }
        }
    }

    func sample(_ index: Int?, source: UnsafeBufferPointer<Float>, offset: Int) -> Float {
        guard let index else { return 0 }
        return SpatialSafety.sample(source[offset + index])
    }
}

struct ChannelEnergyDetector {
    func hasDiscreteContent(_ frame: PCMFrame) -> Bool {
        var front = Double.zero, discrete = Double.zero
        for i in 0..<frame.frameCount {
            for channel in 0..<frame.channelCount {
                let x = Double(SpatialSafety.sample(frame.interleaved[i * frame.channelCount + channel]))
                switch frame.channelLayout.roles[channel] {
                case .left, .right: front += x * x
                case .unknown: break
                default: discrete += x * x
                }
            }
        }
        return discrete > max(Double(frame.frameCount) * 1e-12, front * 1e-6)
    }
}
