import CamiTuneDomain
import Foundation

package struct RoomMeasurementSignal: Sendable {
    package static let volumeRangeDB: ClosedRange<Double> = -24...12
    package static let maximumSourcePeak: Float = 0.1
    /// Leave 12 dB of output margin below clipping and limiter onset anywhere in the active graph.
    package static func boundedGainDB(_ requested: Double, graph: ProcessingGraph) throws -> Double {
        guard requested.isFinite,
              let linearPeak = ProcessingGraphHeadroomCalculator().maximumLinearInputPeak(for: graph),
              linearPeak.isFinite, linearPeak > 0 else { throw RoomCorrectionError.invalidSettings }
        let ceiling = 20 * log10(0.25 * linearPeak / 0.025)
        let gain = min(ceiling, min(volumeRangeDB.upperBound, max(volumeRangeDB.lowerBound, requested)))
        guard gain >= -120 else { throw RoomCorrectionError.invalidSettings }
        return gain
    }
    /// A periodic, constant-level tone, independent of measurement markers/sweeps.
    /// Its RMS matches the ordinary sweep. Playback supplies start/stop fades only.
    package static func levelCheckClip(topology: SpeakerTopology, channels: [Int], gainDB: Double) throws -> SpatialCalibrationClip {
        guard gainDB.isFinite, (-120...12).contains(gainDB),
              let endpoint = topology.endpoints.first(where: { channels.contains($0.id.channelIndex) && !$0.isSubwooferLike })
                ?? topology.endpoints.first(where: { channels.contains($0.id.channelIndex) }),
              topology.sampleRate.isFinite, (8000...192000).contains(topology.sampleRate) else { throw RoomCorrectionError.invalidSettings }
        let count = Int(topology.sampleRate)
        let cycles = endpoint.isSubwooferLike ? 60.0 : 1000.0
        let amplitude = 0.025 * pow(10, gainDB / 20)
        let samples = (0..<count).map { Float(amplitude * sin(2 * .pi * cycles * Double($0) / Double(count))) }
        guard let clip = SpatialCalibrationClip(roomMeasurement: samples, physicalOutput: endpoint.id,
            topology: topology, repeatsUntilStopped: true) else { throw RoomCorrectionError.invalidSettings }
        return clip
    }
    package static let sweepStart = 0.6
    package static let sweepDuration = 4.0
    package static let endMarkerStart = 5.2
    package static let duration = 5.8
    package let sampleRate: Double
    package let block: RoomMeasurementBlock
    package let samples: [Float]
    package let sweep: [Float]
    package init(block: RoomMeasurementBlock, sampleRate: Double) throws {
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate) else { throw RoomCorrectionError.invalidSettings }
        let gainDB = block.playbackGainDB ?? 0
        guard gainDB.isFinite, (-120...Self.volumeRangeDB.upperBound).contains(gainDB) else { throw RoomCorrectionError.invalidSettings }
        let gain = pow(10, gainDB / 20)
        self.block = block; self.sampleRate = sampleRate
        sweep = Self.makeSweep(sampleRate: sampleRate, amplitude: (block.isRepeat ? 0.0125 : 0.025) * gain)
        var samples = [Float](repeating: 0, count: Int(Self.duration * sampleRate))
        for (offset, signal) in [(0.1, Self.marker(token: block.token, end: false, rate: sampleRate).map { $0 * Float(gain) }),
                                 (Self.sweepStart, sweep),
                                 (Self.endMarkerStart, Self.marker(token: block.token, end: true, rate: sampleRate).map { $0 * Float(gain) })] {
            let start = Int(offset * sampleRate)
            samples.replaceSubrange(start..<start + signal.count, with: signal)
        }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= Self.maximumSourcePeak }) else { throw RoomCorrectionError.invalidSettings }
        self.samples = samples
    }
    package static func marker(token: UInt32, end: Bool, rate: Double) -> [Float] {
        var state = token ^ (end ? 0xA7139B41 : 0x29C587F3)
        var chips = [Float]()
        for _ in 0..<127 { state = state &* 1664525 &+ 1013904223; chips.append(state & 0x80000000 == 0 ? -1 : 1) }
        return (0..<Int(rate * 0.127)).map { index in
            let t = Double(index) / rate
            let chip = chips[min(126, Int(t * 1000))]
            let fade = min(1, min(t, 0.127 - t) / 0.005)
            return chip * Float(sin(2 * .pi * 2000 * t) * 0.025 * max(0, fade))
        }
    }
    private static func makeSweep(sampleRate: Double, amplitude: Double) -> [Float] {
        let low = 20.0, high = min(20000, sampleRate * 0.44), duration = sweepDuration
        let ratio = log(high / low), count = Int(duration * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            let taper = max(0, min(1, min(t, duration - t) / 0.035))
            return Float(amplitude * taper * sin(2 * .pi * low * duration / ratio * (exp(t * ratio / duration) - 1)))
        }
    }
    package func clip(topology: SpeakerTopology) -> SpatialCalibrationClip? {
        SpatialCalibrationClip(roomMeasurement: samples, physicalOutput: .init(deviceUID: topology.deviceUID, channelIndex: block.channel), topology: topology)
    }
}
