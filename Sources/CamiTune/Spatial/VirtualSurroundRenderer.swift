import Foundation

/// A bounded stereo virtual-speaker bed, not discrete hardware 7.1 output or
/// individualized HRTF rendering. Runs on the existing PCM writer worker.
final class VirtualSurroundRenderer {
    private struct Parameters {
        var left: Float = 0
        var right: Float = 0
        var leftDelay: Float = 0
        var rightDelay: Float = 0
        var rear: Float = 0
        var lowpass: Float = 1
        mutating func approach(_ target: Self, alpha: Float) {
            left += (target.left - left) * alpha
            right += (target.right - right) * alpha
            leftDelay += (target.leftDelay - leftDelay) * alpha
            rightDelay += (target.rightDelay - rightDelay) * alpha
            rear += (target.rear - rear) * alpha
            lowpass += (target.lowpass - lowpass) * alpha
        }
    }
    private struct Speaker {
        var delay: [Float] = []
        var index = 0
        var filtered: Float = 0
        var parameters = Parameters()
        mutating func process(_ sample: Float, target: Parameters, alpha: Float, reflectionDelay: Int) -> (Float, Float) {
            parameters.approach(target, alpha: alpha)
            filtered += parameters.lowpass * (sample - filtered)
            delay[index] = filtered
            func read(_ offset: Float) -> Float {
                let lower = Int(offset)
                let fraction = offset - Float(lower)
                let a = delay[(index - lower + delay.count) % delay.count]
                let b = delay[(index - lower - 1 + delay.count) % delay.count]
                return a + (b - a) * fraction
            }
            let reflection = read(Float(reflectionDelay)) * parameters.rear * 0.12
            let left = (read(parameters.leftDelay) + reflection) * parameters.left
            let right = (read(parameters.rightDelay) + reflection) * parameters.right
            index = (index + 1) % delay.count
            return (left, right)
        }
    }
    private var speakers = [Speaker](repeating: Speaker(), count: 8)
    private var rate = 0.0
    private var upmix: Float = 0
    private var headroom: Float = 1
    private var ambienceMix: Float = 1
    private var centerMix: Float = 1

    func reset() {
        rate = 0; speakers = [Speaker](repeating: Speaker(), count: 8)
        upmix = 0; headroom = 1; ambienceMix = 1; centerMix = 1
    }

    func render(frame: PCMFrame, layout: VirtualSurroundLayout,
                contentMode: SpatialContentMode = .fixed,
                estimate: SpatialContentEstimate = .unknown) -> PCMFrame? {
        guard frame.channelCount > 0, frame.channelCount <= 8,
              frame.channelLayout.roles.count == frame.channelCount,
              frame.interleaved.count.isMultiple(of: frame.channelCount),
              frame.sampleRate.isFinite, (8_000...384_000).contains(frame.sampleRate) else { return nil }
        let starting = rate != frame.sampleRate
        if starting {
            reset(); rate = frame.sampleRate
            for index in speakers.indices { speakers[index].delay = .init(repeating: 0, count: Int(rate * 0.020) + 4) }
        }
        let roles = VirtualSurroundLayout.roles
        let indices = roles.map { frame.channelLayout.roles.firstIndex(of: $0) }
        // Source metadata, never momentary channel energy, authorizes upmix.
        // A quiet surround channel in a real movie must remain quiet.
        let stereoPayload = frame.channelCount == 2
            && Set(frame.channelLayout.roles) == Set([ChannelRole.left, .right])
        let upmixTarget: Float = layout.upmixStereo && stereoPayload ? 1 : 0
        let ambience: Float
        let centerAmount: Float
        switch contentMode {
        case .musicSafe: ambience = 0.35; centerAmount = 0.4
        case .movieVideo: ambience = 1.25; centerAmount = 1
        case .automatic:
            ambience = min(1.2, max(0.35, 0.65 + 0.55 * estimate.ambience - 0.3 * estimate.music))
            centerAmount = min(1, max(0.4, 0.6 + 0.4 * estimate.speech))
        case .fixed: ambience = 1; centerAmount = 1
        }
        let targets = roles.map { role -> Parameters in
            let position = layout.position(for: role)
            // Independent control axes. Normalizing x by the combined x/y
            // radius made a tiny x change jump to hard pan when y was zero.
            // 0.8 is the reference diagram radius, preserving default directions.
            let pan = max(-1, min(1, position.x / 0.8))
            let rear = max(0, min(1, position.y / 0.8))
            // Coordinates are perceptual steering controls, not measured
            // listener distance. Keep nominal channel gain independent of radius.
            // Unity for a correlated stereo pair at the default ±30° layout.
            let gain: Float = 1 / (sqrt(0.75) + sqrt(0.25))
            if role == .lowFrequencyEffects {
                return Parameters(left: gain * 0.18, right: gain * 0.18,
                                  lowpass: Float(1 - exp(-2 * .pi * 120 / rate)))
            }
            return Parameters(left: gain * sqrt((1 - pan) * 0.5), right: gain * sqrt((1 + pan) * 0.5),
                leftDelay: max(0, pan) * Float(rate * 0.0006),
                rightDelay: max(0, -pan) * Float(rate * 0.0006), rear: rear,
                lowpass: Float(1 - exp(-2 * .pi * Double(12_000 - 8_000 * rear) / rate)))
        }
        if starting {
            // Begin at the requested timing/tone instead of sweeping delay
            // from zero. Only gain fades in; dragging later still smooths.
            for index in speakers.indices {
                speakers[index].parameters = targets[index]
                speakers[index].parameters.left = 0
                speakers[index].parameters.right = 0
            }
        }
        // Limit the actual rendered sum, not hypothetical full-scale signals
        // in all eight channels. Quiet/absent channels need no fixed attenuation.
        let alpha = Float(1 - exp(-1 / (rate * 0.080)))
        let ceiling: Float = 0.95
        var output = [Float](); output.reserveCapacity(frame.frameCount * 2)
        for offset in stride(from: 0, to: frame.interleaved.count, by: frame.channelCount) {
            upmix += (upmixTarget - upmix) * alpha
            ambienceMix += (ambience - ambienceMix) * alpha
            centerMix += (centerAmount - centerMix) * alpha
            let l = indices[0].map { clean(frame.interleaved[offset + $0]) } ?? 0
            let r = indices[2].map { clean(frame.interleaved[offset + $0]) } ?? 0
            let mid = (l + r) * 0.5
            let side = (l - r) * 0.5
            var left: Float = 0, right: Float = 0
            for index in roles.indices {
                var sample = indices[index].map { clean(frame.interleaved[offset + $0]) } ?? 0
                // Derived ambience is optional and never replaces true bed channels.
                if stereoPayload {
                    switch roles[index] {
                    case .left, .right: sample -= mid * 0.4 * upmix * centerMix
                    case .center: sample += mid * 0.8 * upmix * centerMix
                    case .leftSurround: sample += side * 0.22 * upmix * ambienceMix
                    case .rightSurround: sample -= side * 0.22 * upmix * ambienceMix
                    case .leftRearSurround: sample += side * 0.12 * upmix * ambienceMix
                    case .rightRearSurround: sample -= side * 0.12 * upmix * ambienceMix
                    default: break
                    }
                }
                let pair = speakers[index].process(sample, target: targets[index], alpha: alpha, reflectionDelay: Int(rate * 0.012))
                left += pair.0; right += pair.1
            }
            let targetHeadroom = min(1, ceiling / max(ceiling, max(abs(left), abs(right))))
            if targetHeadroom < headroom { headroom = targetHeadroom }
            else { headroom += (targetHeadroom - headroom) * alpha }
            output.append(max(-ceiling, min(ceiling, left * headroom)))
            output.append(max(-ceiling, min(ceiling, right * headroom)))
        }
        return PCMFrame(interleaved: output, channelCount: 2, sampleRate: rate, channelLayout: .stereo,
                        sourceBufferedFrames: frame.sourceBufferedFrames, sourceCapacityFrames: frame.sourceCapacityFrames)
    }

    private func clean(_ value: Float) -> Float { value.isFinite ? max(-1, min(1, value)) : 0 }
}
