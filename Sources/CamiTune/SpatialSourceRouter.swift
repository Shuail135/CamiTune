import Foundation

/// Prototype-1 source routing. It keeps the source layout intact for meters and
/// analysis while supplying the stereo FrontStageRenderer/CamillaDSP path with
/// a conservative, bounded fallback mix. Front Stage mode replaces this path
/// with role-specific multichannel rendering; Standard mode retains it.
struct SpatialSourceRouter {
    func stereoFallback(for frame: PCMFrame) -> PCMFrame? {
        guard frame.channelCount > 0,
              frame.channelLayout.channelCount == frame.channelCount,
              frame.interleaved.count.isMultiple(of: frame.channelCount) else {
            return nil
        }
        if frame.channelLayout.roles == LPCMChannelLayout.stereo.roles {
            return frame
        }

        let matrix = stereoMatrix(for: frame.channelLayout.roles)
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
            channelLayout: .stereo,
            sourceBufferedFrames: frame.sourceBufferedFrames,
            sourceCapacityFrames: frame.sourceCapacityFrames
        )
    }

    private func stereoMatrix(
        for roles: [ChannelRole]
    ) -> [(left: Float, right: Float)] {
        roles.enumerated().map { index, role in
            switch role {
            case .left:
                return (left: Float(1), right: Float(0))
            case .right:
                return (left: Float(0), right: Float(1))
            case .center:
                return (left: Float.squareRootOfOneHalf, right: Float.squareRootOfOneHalf)
            case .leftSurround, .leftRearSurround:
                return (left: Float.squareRootOfOneHalf, right: Float(0))
            case .rightSurround, .rightRearSurround:
                return (left: Float(0), right: Float.squareRootOfOneHalf)
            case .lowFrequencyEffects:
                // Do not send an unfiltered LFE channel directly to small
                // full-range speakers. Protected impact handling belongs to
                // the later FrontStageRenderer milestone.
                return (left: Float(0), right: Float(0))
            case .unknown:
                // Preserve the conventional first stereo pair for an otherwise
                // unknown layout. Additional unknown positions cannot be mixed
                // safely without inventing a role.
                if index == 0 { return (left: Float(1), right: Float(0)) }
                if index == 1 { return (left: Float(0), right: Float(1)) }
                return (left: Float(0), right: Float(0))
            }
        }
    }
}

private extension Float {
    static let squareRootOfOneHalf = Float(0.5).squareRoot()
}
