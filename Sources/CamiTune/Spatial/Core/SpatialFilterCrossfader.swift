import Foundation

/// Prepared filter handoff. The new convolver first consumes enough live input
/// to populate its history; then a 50 ms linear fade avoids a correlated +3 dB
/// gain bump. Instances and scratch buffers are created off the render thread.
/// All methods must be serialized by the owner; this class is not thread-safe.
final class SpatialFilterCrossfader {
    private var active: BinauralConvolver
    private var incoming: BinauralConvolver?
    private var retired: BinauralConvolver?
    private let maximumFrameCount: Int
    private let fadeFrames: Int
    private var warmFrames = 0
    private var fadePosition = 0
    private var oldLeft: [Float], oldRight: [Float]
    private var newLeft: [Float], newRight: [Float]

    init(initial: BinauralConvolver, maximumFrameCount: Int) throws {
        guard maximumFrameCount > 0, maximumFrameCount <= 65536 else {
            throw BinauralConvolutionError.invalidConfiguration
        }
        active = initial; self.maximumFrameCount = maximumFrameCount
        fadeFrames = max(1, Int(initial.sampleRate * 0.05))
        oldLeft = .init(repeating: 0, count: maximumFrameCount)
        oldRight = .init(repeating: 0, count: maximumFrameCount)
        newLeft = .init(repeating: 0, count: maximumFrameCount)
        newRight = .init(repeating: 0, count: maximumFrameCount)
    }

    /// Call at a serialized control boundary with a freshly prepared convolver.
    /// Reap the retired instance off the audio thread before the next replacement.
    func replace(with convolver: BinauralConvolver) -> Bool {
        guard incoming == nil, retired == nil, convolver !== active,
              convolver.sampleRate == active.sampleRate, convolver.blockSize == active.blockSize else { return false }
        convolver.reset()
        incoming = convolver
        warmFrames = convolver.historyFrameCount + convolver.blockSize
        fadePosition = 0
        return true
    }
    func takeRetired() -> BinauralConvolver? {
        let result = retired; retired = nil; return result
    }

    @discardableResult
    func process(source: UnsafeBufferPointer<Float>, left: UnsafeMutableBufferPointer<Float>,
                 right: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard source.count <= maximumFrameCount, left.count >= source.count, right.count >= source.count else { return false }
        guard let incoming else { return active.process(source: source, left: left, right: right) }
        oldLeft.withUnsafeMutableBufferPointer { l in
            oldRight.withUnsafeMutableBufferPointer { r in _ = active.process(source: source, left: l, right: r) }
        }
        newLeft.withUnsafeMutableBufferPointer { l in
            newRight.withUnsafeMutableBufferPointer { r in _ = incoming.process(source: source, left: l, right: r) }
        }
        for i in source.indices {
            let mix: Float
            if warmFrames > 0 { warmFrames -= 1; mix = 0 }
            else { fadePosition = min(fadeFrames, fadePosition + 1); mix = Float(fadePosition) / Float(fadeFrames) }
            left[i] = oldLeft[i] + mix * (newLeft[i] - oldLeft[i])
            right[i] = oldRight[i] + mix * (newRight[i] - oldRight[i])
        }
        if fadePosition == fadeFrames {
            retired = active // Retain ownership so destruction never occurs here.
            active = incoming
            self.incoming = nil
        }
        return true
    }
}
