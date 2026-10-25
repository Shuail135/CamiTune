import CamiTuneAtomics
import Foundation

/// Hardware-independent storage shared by the delivery writer and one output
/// callback. Platform lifecycle and device configuration belong to the app.
package final class DirectOutputBuffer: @unchecked Sendable {
    package struct Snapshot: Sendable {
        package var bufferedFrames: UInt64
        package var underrunFrames: UInt64
        package var clippedSamples: UInt64
        package var renderedFrames: UInt64
        package var hostTime: UInt64
        package var sampleTime: Double
        package var timestampFlags: UInt32
        package var callbackFrames: UInt32
        package var lastSignalHostTime: UInt64
    }
    private let ring: CMTOutputRingRef
    package var context: UnsafeMutableRawPointer { UnsafeMutableRawPointer(ring) }
    package init?(channels: Int, capacityFrames: Int, prerollFrames: Int) {
        guard (1...32).contains(channels), (1...1048576).contains(capacityFrames),
              (1...capacityFrames).contains(prerollFrames),
              let ring = cmt_output_ring_create(UInt32(channels), UInt32(capacityFrames), UInt32(prerollFrames)) else { return nil }
        self.ring = ring
    }
    deinit { cmt_output_ring_destroy(ring) }
    package var accepting: Bool { cmt_output_ring_accepting(ring) != 0 }
    package func cancel() { cmt_output_ring_cancel(ring) }
    package func waitForCallback(after renderedFrames: UInt64, timeoutNanoseconds: UInt64) {
        cmt_output_ring_wait(ring, renderedFrames, timeoutNanoseconds)
    }
    /// Sole writer. Keep the existing two-callback preroll while following the
    /// device clock, including when another client changes the callback size.
    /// Never render MIDI ahead merely to fill the ring's storage capacity.
    package func waitForInstrumentCapacity(frames: Int, initialCallbackFrames: Int) throws {
        var previous = snapshot().renderedFrames
        var progress = PerformanceClock.now()
        while true {
            guard accepting else { throw CancellationError() }
            let value = snapshot()
            let callback = value.callbackFrames > 0 ? Int(value.callbackFrames) : initialCallbackFrames
            if Int(value.bufferedFrames) + frames <= max(frames, callback * 2) { return }
            let now = PerformanceClock.now()
            if value.renderedFrames != previous { previous = value.renderedFrames; progress = now }
            let remaining = 0.25 - PerformanceClock.milliseconds(progress, now) / 1000
            guard remaining > 0 else { throw OutputFailure.stalled }
            waitForCallback(after: value.renderedFrames, timeoutNanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    private enum OutputFailure: LocalizedError {
        case stalled
        var errorDescription: String? { "The output device stopped consuming audio." }
    }
    package func push(_ samples: UnsafePointer<Float>, frames: Int) -> Int {
        guard frames > 0, frames <= Int(UInt32.max) else { return 0 }
        return Int(cmt_output_ring_push(ring, samples, UInt32(frames)))
    }
    package func snapshot() -> Snapshot {
        let value = cmt_output_ring_snapshot(ring)
        return .init(bufferedFrames: value.buffered_frames, underrunFrames: value.underrun_frames,
            clippedSamples: value.clipped_samples, renderedFrames: value.rendered_frames,
            hostTime: value.host_time, sampleTime: value.sample_time, timestampFlags: value.timestamp_flags,
            callbackFrames: value.callback_frames, lastSignalHostTime: value.last_signal_host_time)
    }
    package func takePeak(channel: Int) -> Float { cmt_output_ring_peak(ring, UInt32(channel)) }
    package func rms(channel: Int) -> Float { cmt_output_ring_rms(ring, UInt32(channel)) }
    package static func channelCount(context: UnsafeMutableRawPointer) -> UInt32 { cmt_output_ring_channels(OpaquePointer(context)) }
    package static func render(context: UnsafeMutableRawPointer, output: UnsafeMutablePointer<Float>, frames: UInt32,
                               sampleTime: Double, hostTime: UInt64, flags: UInt32) {
        cmt_output_ring_render(OpaquePointer(context), output, frames, sampleTime, hostTime, flags)
    }
}
