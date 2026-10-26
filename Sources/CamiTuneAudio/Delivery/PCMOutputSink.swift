import Foundation

package protocol PCMOutputSink: AnyObject, Sendable {
    /// Process and deliver incrementally when the hardware has a small runway.
    var processingBlockFrames: Int? { get }
    /// A hardware sink can clock idle instruments from actual consumption.
    var pacesContinuousRendering: Bool { get }
    func waitForInstrumentCapacity(frames: Int) throws
    func write(_ bytes: Data) throws
    func cancel()
    func finish()
}
package extension PCMOutputSink {
    var processingBlockFrames: Int? { nil }
    var pacesContinuousRendering: Bool { false }
    func waitForInstrumentCapacity(frames: Int) throws {}
    func cancel() {}
}

