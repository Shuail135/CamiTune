import CamiTuneDomain
import Foundation

/// Prototype-1 source routing. It keeps the source layout intact for meters and
/// analysis while supplying the stereo renderer/CamillaDSP path with
/// a conservative, bounded fallback mix. Front Stage mode replaces this path
/// with role-specific multichannel rendering; Standard mode retains it.
package struct SpatialSourceRouter {
    package init() {}

    package func stereoFallback(for frame: PCMFrame) -> PCMFrame? {
        guard frame.channelCount > 0,
              frame.channelLayout.channelCount == frame.channelCount,
              frame.interleaved.count.isMultiple(of: frame.channelCount) else {
            return nil
        }
        if frame.channelLayout.roles == LPCMChannelLayout.stereo.roles {
            return frame
        }

        guard (try? frame.channelLayout.validate()) != nil else { return nil }
        var matrix = stereoMatrix(for: frame.channelLayout.roles)
        if frame.channelLayout.roles.contains(.unknown) {
            let solver = VBAPSolver(positions: [StandardSpeakerPositions.position(for: .left)!, StandardSpeakerPositions.position(for: .right)!])
            for (index, role) in frame.channelLayout.roles.enumerated() where role == .unknown {
                guard let position = frame.channelLayout.positions?[index] else { return nil }
                let gains = solver.gains(for: position).gains
                matrix[index] = (gains[0], gains[1])
            }
        }
        var output = [Float]()
        output.reserveCapacity(frame.frameCount * 2)
        var peak = Float.zero
        for frameIndex in 0..<frame.frameCount {
            let sourceOffset = frameIndex * frame.channelCount
            var left: Float = 0
            var right: Float = 0
            for channel in 0..<frame.channelCount {
                let sample = frame.interleaved[sourceOffset + channel]
                left += sample * matrix[channel].left
                right += sample * matrix[channel].right
            }
            output.append(left)
            output.append(right)
            peak = max(peak, max(abs(left), abs(right)))
        }

        // Reserve headroom only when the samples in this block really need it.
        // A fixed matrix normalization attenuates ordinary stereo carried by an
        // eight-channel endpoint even though all six extra channels are silent.
        if peak > 1, peak.isFinite {
            let gain = Float(1) / peak
            for index in output.indices {
                output[index] *= gain
            }
        }
        return PCMFrame(
            interleaved: output,
            channelCount: 2,
            sampleRate: frame.sampleRate,
            channelLayout: .stereo)
    }

    private func stereoMatrix(
        for roles: [ChannelRole]
    ) -> [(left: Float, right: Float)] {
        roles.map { role in
            switch role {
            case .left:
                return (left: Float(1), right: Float(0))
            case .right:
                return (left: Float(0), right: Float(1))
            case .center, .topCenter:
                return (left: Float.squareRootOfOneHalf, right: Float.squareRootOfOneHalf)
            case .leftSurround, .leftRearSurround, .topFrontLeft, .topMiddleLeft, .topRearLeft, .frontLeftCenter, .wideLeft:
                return (left: Float.squareRootOfOneHalf, right: Float(0))
            case .rightSurround, .rightRearSurround, .topFrontRight, .topMiddleRight, .topRearRight, .frontRightCenter, .wideRight:
                return (left: Float(0), right: Float.squareRootOfOneHalf)
            case .lowFrequencyEffects:
                // Do not send an unfiltered LFE channel directly to small
                // full-range speakers. Protected impact handling belongs to
                // semantic spatial rendering.
                return (left: Float(0), right: Float(0))
            case .unknown:
                // Coordinates are resolved by the caller; unpositioned custom
                // channels produce an explicit unsupported result.
                return (left: Float(0), right: Float(0))
            }
        }
    }
}

private extension Float {
    static let squareRootOfOneHalf = Float(0.5).squareRoot()
}
