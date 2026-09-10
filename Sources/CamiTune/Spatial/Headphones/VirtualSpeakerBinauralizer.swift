import Foundation

/// One filter bank per supported rate, prepared before the render worker starts.
/// Semantic sources each share one FFT between the two ear filters.
final class VirtualSpeakerBinauralizer {
    let latencyFrames: Int
    let expectedPeakGain: Float
    private let convolvers: [BinauralConvolver]
    private let roles = VirtualSpeakerLayout.cinema.speakers.map(\.role)
    private var indices = [Int?](repeating: nil, count: 7)
    private var bass = BassManager()
    private var directLeft: [Float], directRight: [Float], bassDelay: [Float]
    private var directCursor = 0, bassCursor = 0

    init(database: BundledHRTFDatabase, sampleRate: Double) throws {
        convolvers = try VirtualSpeakerLayout.cinema.speakers.map {
            try BinauralConvolver(hrir: database.hrir(for: $0.direction, sampleRate: sampleRate), sampleRate: sampleRate)
        }
        latencyFrames = 128 + database.referenceDelayFrames(sampleRate: sampleRate)
        expectedPeakGain = convolvers.reduce(0) { $0 + $1.expectedPeakGain } + 0.25
        directLeft = .init(repeating: 0, count: latencyFrames)
        directRight = .init(repeating: 0, count: latencyFrames)
        bassDelay = .init(repeating: 0, count: latencyFrames)
        bass.prepare(sampleRate: sampleRate)
    }
    func configure(layout: LPCMChannelLayout) {
        for i in roles.indices { indices[i] = layout.roles.firstIndex(of: roles[i]) }
        reset()
    }
    func reset() {
        for convolver in convolvers { convolver.reset() }
        for i in directLeft.indices { directLeft[i] = 0; directRight[i] = 0; bassDelay[i] = 0 }
        bass.reset(); directCursor = 0; bassCursor = 0
    }
    func process(source: UnsafeBufferPointer<Float>, offset: Int, lfeIndex: Int?, dialogue: Float) -> (Float, Float) {
        var left: Float = 0, right: Float = 0
        for i in convolvers.indices {
            guard let channel = indices[i] else { continue }
            var sample = SpatialSafety.sample(source[offset + channel])
            if roles[i] == .center { sample *= 1 + 0.12 * dialogue }
            let ears = convolvers[i].processSample(sample)
            left += ears.0; right += ears.1
        }
        let delayedBass = bassDelay[bassCursor]
        bassDelay[bassCursor] = bass.process(lfeIndex.map { SpatialSafety.sample(source[offset + $0]) } ?? 0)
        bassCursor = (bassCursor + 1) % bassDelay.count
        return (left + delayedBass, right + delayedBass)
    }
    func alignDirect(_ left: Float, _ right: Float) -> (Float, Float) {
        let result = (directLeft[directCursor], directRight[directCursor])
        directLeft[directCursor] = left; directRight[directCursor] = right
        directCursor = (directCursor + 1) % directLeft.count
        return result
    }
}
