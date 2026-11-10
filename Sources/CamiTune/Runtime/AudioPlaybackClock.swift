import CamiTuneAudio
import Foundation

/// Explicit engine protocol value. Optional UI diagnostics never supply this
/// control input; the engine adapter polls it for the owned delivery session.
struct AudioPlaybackClock: Codable, Sendable {
    let epoch: UInt64
    let sampleTime: Double
    let hostTime: UInt64
    let nominalRate: Double
    let timestampFlags: UInt32
    let demandFrames: UInt64
    let underrunFrames: UInt64
    // Observation only: callback occupancy is not a second rate-control input.
    // Optional so earlier captures retain unknown rather than invented zeroes.
    let callbackFrames: Int?
    let bufferedFrames: Int?
    // Native ring-render entry after platform buffer validation, in Mach ticks.
    // Presentation time can be later; this observation never drives clock control.
    let renderEntryHostTime: UInt64?

    enum CodingKeys: String, CodingKey {
        case epoch
        case sampleTime = "sample_time", hostTime = "host_time", nominalRate = "nominal_rate"
        case timestampFlags = "timestamp_flags", demandFrames = "demand_frames", underrunFrames = "underrun_frames"
        case callbackFrames = "callback_frames", bufferedFrames = "buffered_frames"
        case renderEntryHostTime = "render_entry_host_time"
    }

    func observation(received: PerformanceTick) -> AudioClockObservation {
        .init(epoch: epoch, sampleTime: sampleTime, hostTime: hostTime, nominalRate: nominalRate,
              timestampFlags: timestampFlags, received: received)
    }
}
