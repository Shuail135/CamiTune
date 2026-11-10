import Foundation

package enum PCMOutputTailState: Equatable, Sendable {
    case complete
    case pending
}

package protocol PCMOutputSink: AnyObject, Sendable {
    /// Process and deliver incrementally when the hardware has a small runway.
    var processingBlockFrames: Int? { get }
    /// A hardware sink can clock idle instruments from actual consumption.
    var pacesContinuousRendering: Bool { get }
    /// Register the current writer's event-driven control wakeup. A sink with
    /// already-published work must signal on registration. Invoke outside its
    /// control lock; unregistering may race a previously copied callback.
    func setControlWakeup(_ wakeup: (@Sendable () -> Void)?)
    /// Runs on the sole delivery writer, between complete render/write calls.
    /// Service published backend work without inventing source PCM or END, and
    /// return the resulting local tail state. Ordinary sinks publish no work.
    func processPendingControl() throws -> PCMOutputTailState
    func waitForInstrumentCapacity(frames: Int) throws
    func write(_ bytes: Data) throws
    /// Borrows complete interleaved Float32 frames until return. Hardware sinks
    /// consume prepared DSP storage directly; byte-stream sinks retain their I/O.
    func write(_ samples: UnsafeBufferPointer<Float>) throws
    /// Called by the sole delivery writer after an authoritative producer end
    /// and all upstream PCM/tails. It does not close the runtime or its output.
    /// An explicit discontinuity may discard local history instead of draining;
    /// this also runs before the first replacement source/calibration block.
    /// Byte-stream sinks have no local DSP tail; ordinary writes remain valid.
    func finishProducer(discard: Bool) throws -> PCMOutputTailState
    /// Deliver at most maximumFrames of local tail on that same writer. A later
    /// source write resumes processing at the actual position already rendered.
    /// Cancellation must unblock any downstream capacity wait.
    func drainProducerTail(maximumFrames: Int) throws -> PCMOutputTailState
    func cancel()
    func finish()
}
package extension PCMOutputSink {
    var processingBlockFrames: Int? { nil }
    var pacesContinuousRendering: Bool { false }
    func setControlWakeup(_ wakeup: (@Sendable () -> Void)?) {}
    func processPendingControl() throws -> PCMOutputTailState { .complete }
    func waitForInstrumentCapacity(frames: Int) throws {}
    func write(_ samples: UnsafeBufferPointer<Float>) throws {
        try write(Data(buffer: samples))
    }
    func finishProducer(discard: Bool) throws -> PCMOutputTailState { .complete }
    func drainProducerTail(maximumFrames: Int) throws -> PCMOutputTailState { .complete }
    func cancel() {}
}

