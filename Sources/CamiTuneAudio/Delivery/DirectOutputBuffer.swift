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
