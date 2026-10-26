import Foundation

/// A sample/host pair from the actual source or playback callback. Host ticks
/// share the machine's monotonic clock; receipt time is used only for freshness.
package struct AudioClockObservation: Sendable, Equatable {
    package init(epoch: UInt64, sampleTime: Double, hostTime: UInt64, nominalRate: Double, timestampFlags: UInt32, received: PerformanceTick, deviceID: UInt32 = 0) {
        self.epoch = epoch
        self.sampleTime = sampleTime
        self.hostTime = hostTime
        self.nominalRate = nominalRate
        self.timestampFlags = timestampFlags
        self.received = received
        self.deviceID = deviceID
    }

    package let epoch: UInt64
    package let sampleTime: Double
    package let hostTime: UInt64
    package let nominalRate: Double
    package let timestampFlags: UInt32
    package let received: PerformanceTick
    package var deviceID: UInt32 = 0
}

package enum AudioClockDriftState: Sendable, Equatable {
    case warming
    case tracking(adjustmentPPM: Double)
    case unavailable(String)
}

/// Writer-owned clock comparison. This supplies feed-forward evidence to the
/// existing rate controller; it neither resamples nor introduces a second loop.
/// Its owner serializes observations from the transport and engine adapters.
package struct AudioClockDrift {
    private struct Track {
        var anchor: AudioClockObservation?
        var latest: AudioClockObservation?
        var framesPerHostTick: Double?
        var fault: String?

        /// Returns true only when a new stream epoch starts.
        mutating func observe(_ value: AudioClockObservation) -> Bool {
            guard value.epoch > 0, value.hostTime > 0, value.sampleTime.isFinite,
                  value.nominalRate.isFinite, (8_000...768_000).contains(value.nominalRate),
                  value.timestampFlags & 3 == 3 else { return false }
            if let latest {
                guard value.deviceID == latest.deviceID else {
                    fault = "source device changed inside the delivery session"
                    return false
                }
                if value.epoch < latest.epoch { return false }
                if value.epoch == latest.epoch {
                    if value.sampleTime == latest.sampleTime && value.hostTime == latest.hostTime {
                        return false // Polling the same snapshot cannot make it fresh.
                    }
                    guard value.hostTime > latest.hostTime, value.sampleTime > latest.sampleTime,
                          value.nominalRate == latest.nominalRate else {
                        fault = "clock changed or rewound without a new stream epoch"
                        return false
                    }
                }
            }
            let newEpoch = latest?.epoch != value.epoch
            if newEpoch {
                anchor = value; framesPerHostTick = nil; fault = nil
            }
            latest = value
            if let anchor {
                let frames = value.sampleTime - anchor.sampleTime
                // Average callback timestamps over at least half a second.
                // Packet arrival jitter is deliberately absent from this ratio.
                if frames >= value.nominalRate * 0.5 {
                    let ticks = value.hostTime - anchor.hostTime
                    framesPerHostTick = frames / Double(ticks)
                    if frames >= value.nominalRate * 5 { self.anchor = value }
                }
            }
            return newEpoch
        }
    }

    private var source = Track()
    private var output = Track()
    private var warmingSince: PerformanceTick?
    package static let freshnessSeconds = 2.5
    package static let warmUpSeconds = 3.0

    package init(started: PerformanceTick) { warmingSince = started }

    package mutating func observeSource(_ value: AudioClockObservation) {
        if source.observe(value) { warmingSince = value.received }
    }

    package mutating func observeOutput(_ value: AudioClockObservation) {
        if output.observe(value) { warmingSince = value.received }
    }

    package func state(at now: PerformanceTick) -> AudioClockDriftState {
        if let fault = source.fault ?? output.fault { return .unavailable(fault) }
        let warming = warmingSince.map { now >= $0 && now < $0.advanced(seconds: Self.warmUpSeconds) } ?? true
        guard let sourceSample = source.latest, let outputSample = output.latest else {
            return warming ? .warming : .unavailable("source or playback clock observation is missing")
        }
        guard now >= sourceSample.received, now >= outputSample.received,
              now < sourceSample.received.advanced(seconds: Self.freshnessSeconds),
              now < outputSample.received.advanced(seconds: Self.freshnessSeconds) else {
            return .unavailable("source or playback clock observation is stale")
        }
        guard sourceSample.nominalRate == outputSample.nominalRate else {
            return .unavailable("source and playback nominal sample rates differ")
        }
        guard let sourceRate = source.framesPerHostTick, let outputRate = output.framesPerHostTick else {
            return warming ? .warming : .unavailable("clock observation has not advanced far enough")
        }
        // Positive correction consumes more source frames per output frame.
        // Compare frame/tick rates directly; do not invert mRateScalar by guess.
        let ppm = (sourceRate / outputRate - 1) * 1_000_000
        guard ppm.isFinite, abs(ppm) <= AdaptiveRateController.maximumAdjustmentPPM else {
            return .unavailable("relative clock drift exceeds the rate controller's correction range")
        }
        return .tracking(adjustmentPPM: ppm)
    }
}
