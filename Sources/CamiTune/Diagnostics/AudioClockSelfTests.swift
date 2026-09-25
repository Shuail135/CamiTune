import CamiTuneAudio
import CamiTuneDomain
import Foundation

extension DeveloperSelfTests {
    static func audioClockCases() -> [DiagnosticCase] {
        let origin = PerformanceTick(rawValue: 1_000_000_000)
        func sample(_ second: Double, ppm: Double = 0, epoch: UInt64 = 1,
                    flags: UInt32 = 3, received: Double? = nil) -> AudioClockObservation {
            .init(epoch: epoch, sampleTime: second * 48_000 * (1 + ppm / 1_000_000),
                hostTime: 100 + UInt64(second * 24_000_000), nominalRate: 48_000,
                timestampFlags: flags, received: origin.advanced(seconds: received ?? second))
        }
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor () async throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "Audio Clock Drift", name: name, safety: .simulated) {
                try await body(); return .init(summary: name)
            }
        }
        func tracking(_ state: AudioClockDriftState) throws -> Double {
            guard case .tracking(let ppm) = state else { throw DiagnosticFailure(message: "Clock was not tracking: \(state)") }
            return ppm
        }
        func unavailable(_ state: AudioClockDriftState) throws {
            guard case .unavailable = state else { throw DiagnosticFailure(message: "Invalid clock remained usable: \(state)") }
        }
        return [
            check("PD63", "Clock comparison measures both drift directions independent of receipt jitter") {
                for outputPPM in [-200.0, 200.0] {
                    var clocks = AudioClockDrift(started: origin)
                    clocks.observeSource(sample(0)); clocks.observeOutput(sample(0, ppm: outputPPM))
                    clocks.observeSource(sample(1, received: 1.15))
                    clocks.observeOutput(sample(1, ppm: outputPPM, received: 1.3))
                    let ppm = try tracking(clocks.state(at: origin.advanced(seconds: 1.31)))
                    let expected = (1 / (1 + outputPPM / 1_000_000) - 1) * 1_000_000
                    try diagnosticRequire(abs(ppm - expected) < 0.0001, "Wrong ratio direction or receipt time used as sample clock")
                }
            },
            check("PD64", "Repeated snapshots cannot refresh a stale playback clock") {
                var clocks = AudioClockDrift(started: origin)
                clocks.observeSource(sample(0)); clocks.observeOutput(sample(0))
                clocks.observeSource(sample(1)); clocks.observeOutput(sample(1))
                clocks.observeSource(sample(4)); clocks.observeOutput(sample(1, received: 4))
                try unavailable(clocks.state(at: origin.advanced(seconds: 4)))
            },
            check("PD65", "Missing or invalid timestamp evidence expires after bounded warmup") {
                var clocks = AudioClockDrift(started: origin)
                try diagnosticRequire(clocks.state(at: origin) == .warming, "Clock did not warm up")
                clocks.observeSource(sample(0, flags: 1)); clocks.observeOutput(sample(0, flags: 2))
                try unavailable(clocks.state(at: origin.advanced(seconds: 3)))
            },
            check("PD66", "Clock rewind requires an explicit new playback epoch") {
                var clocks = AudioClockDrift(started: origin)
                clocks.observeSource(sample(0)); clocks.observeOutput(sample(0))
                clocks.observeSource(sample(1)); clocks.observeOutput(sample(1))
                clocks.observeOutput(sample(0.5, received: 1.1))
                try unavailable(clocks.state(at: origin.advanced(seconds: 1.1)))
                clocks.observeOutput(sample(1.2, epoch: 2))
                try diagnosticRequire(clocks.state(at: origin.advanced(seconds: 1.2)) == .warming, "New epoch retained the prior rate")
                clocks.observeOutput(sample(1.8, epoch: 2)); clocks.observeSource(sample(1.8))
                let ppm = try tracking(clocks.state(at: origin.advanced(seconds: 1.8)))
                try diagnosticRequire(abs(ppm) < 0.001, "Restart retained a stale estimate")
                clocks.observeOutput(sample(0.1, epoch: 1, received: 1.9))
                _ = try tracking(clocks.state(at: origin.advanced(seconds: 1.9)))
            },
            check("PD67", "Unsupported relative drift is reported rather than silently clamped") {
                var clocks = AudioClockDrift(started: origin)
                clocks.observeSource(sample(0)); clocks.observeOutput(sample(0, ppm: 2000))
                clocks.observeSource(sample(1)); clocks.observeOutput(sample(1, ppm: 2000))
                try unavailable(clocks.state(at: origin.advanced(seconds: 1)))
            },
            check("PD68", "Measured drift keeps an empty writer's real resampler reservoir bounded") {
                for outputPPM in [-200.0, 200.0] {
                    var clocks = AudioClockDrift(started: origin)
                    var controller = AdaptiveRateController(), resampler = AdaptivePCMResampler()
                    clocks.observeSource(sample(0)); clocks.observeOutput(sample(0, ppm: outputPPM))
                    let frames = 480, rate = 48_000.0
                    let input = PCMFrame(interleaved: Array(repeating: 0.125, count: frames * 2), channelCount: 2, sampleRate: rate)
                    var reserve = 1024.0, minimum = reserve, maximum = reserve
                    for block in 1...12_000 {
                        let second = Double(block) / 100
                        clocks.observeSource(sample(second))
                        if block % 100 == 0 { clocks.observeOutput(sample(second, ppm: outputPPM)) }
                        let feedForward: Double
                        switch clocks.state(at: origin.advanced(seconds: second)) {
                        case .tracking(let ppm): feedForward = ppm
                        case .warming: feedForward = 0
                        case .unavailable(let reason): throw DiagnosticFailure(message: reason)
                        }
                        let correction = controller.update(.init(bufferedFrames: frames, targetFrames: frames,
                            sampleRate: rate, elapsedFrames: frames, recoveryGeneration: 1,
                            requiresStandingBacklog: true, clockAdjustmentPPM: feedForward))
                        let output = resampler.process(input, adjustmentPPM: correction)
                        reserve += Double(output.frameCount) - Double(frames) * (1 + outputPPM / 1_000_000)
                        minimum = min(minimum, reserve); maximum = max(maximum, reserve)
                    }
                    try diagnosticRequire(minimum > 990 && maximum < 1058 && abs(reserve - 1024) < 34,
                        "Clock-tracked reservoir drifted: min \(minimum), max \(maximum), final \(reserve)")
                }
            },
            check("PD69", "Clock feed-forward obeys the existing slew and recovery reset") {
                var controller = AdaptiveRateController()
                var previous = 0.0
                for _ in 0..<200 {
                    let ppm = controller.update(.init(bufferedFrames: 480, targetFrames: 512,
                        sampleRate: 48_000, elapsedFrames: 480, recoveryGeneration: 1,
                        requiresStandingBacklog: true, clockAdjustmentPPM: 200))
                    try diagnosticRequire(abs(ppm - previous) <= 2.400001, "Clock update bypassed the slew bound")
                    previous = ppm
                }
                let reset = controller.update(.init(bufferedFrames: 480, targetFrames: 512,
                    sampleRate: 48_000, elapsedFrames: 480, recoveryGeneration: 2,
                    requiresStandingBacklog: true, clockAdjustmentPPM: -200))
                try diagnosticRequire(abs(reset + 2.4) < 0.00001, "Recovery retained the old clock correction")
            },
            check("PD70", "A retired playback-clock consumer cannot feed a replacement writer") {
                let router = PCMRouter()
                let pipe = Pipe()
                defer { router.stop(); try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                let configuration = PCMDeliveryConfiguration(queue: .init(sampleRate: 48_000,
                    operatingTargetFrames: 512, recoveryTargetFrames: 0, hardLimitFrames: 4800,
                    recoveryStrategy: .clearAll, rateTargetMode: .clockTracked), camillaQueueLimit: 4)
                await router.startFixture(camillaSink: pipe.fileHandleForWriting, deliveryConfiguration: configuration)
                let retired = router.playbackClockConsumer()
                await router.stopWithoutBlockingUI()
                await router.startFixture(camillaSink: pipe.fileHandleForWriting, deliveryConfiguration: configuration)
                let now = PerformanceClock.now()
                func observation(_ position: Double, received: PerformanceTick) -> AudioClockObservation {
                    .init(epoch: 1, sampleTime: position * 48_000, hostTime: 100 + UInt64(position * 24_000_000),
                        nominalRate: 48_000, timestampFlags: 3, received: received)
                }
                // Source is current, with an expired warmup. Only the retired
                // branch receives output observations: the new one must fault.
                router.observeSourceClock(observation(0, received: .init(rawValue: now.rawValue - 4_000_000_000)))
                router.observeSourceClock(observation(1, received: now))
                retired(observation(0, received: now)); retired(observation(1, received: now))
                router.route(.init(interleaved: Array(repeating: 0.125, count: 1024), channelCount: 2, sampleRate: 48_000))
                let deadline = now.advanced(seconds: 2)
                while router.statistics.deliveryError == nil && PerformanceClock.now() < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let statistics = router.statistics
                try diagnosticRequire(statistics.deliveryError?.contains("clock observation is missing") == true
                    && statistics.camillaWriteFailures == 0, "Stale consumer crossed sessions or clock loss was misclassified as pipe failure")
                var status = AudioRuntimeStatus()
                status.isActive = true; status.engineIsRunning = true
                status.route = .init(transport: .init(), router: statistics)
                try diagnosticRequire(status.pipelineAssessment().health == .fault
                    && status.telemetryAssessment().health == .inactive,
                    "Required clock control and optional DSP telemetry were conflated")
            },
            check("PD71", "Playback clock protocol preserves raw timestamps and underrun evidence") {
                let bytes = Data(#"{"epoch":7,"sample_time":512.0,"host_time":123456789012345,"nominal_rate":48000,"timestamp_flags":3,"demand_frames":1024,"underrun_frames":12}"#.utf8)
                let clock = try JSONDecoder().decode(CamillaPlaybackClock.self, from: bytes)
                let observed = clock.observation(received: origin)
                try diagnosticRequire(observed.epoch == 7 && observed.hostTime == 123456789012345
                    && observed.timestampFlags == 3 && clock.underrunFrames == 12
                    && clock.callbackFrames == nil && clock.bufferedFrames == nil,
                    "Structured clock lost timestamps, identity, or underrun counts")
                let current = Data(#"{"epoch":7,"sample_time":512.0,"host_time":123456789012345,"nominal_rate":48000,"timestamp_flags":3,"demand_frames":1024,"underrun_frames":12,"callback_frames":512,"buffered_frames":1536}"#.utf8)
                let measured = try JSONDecoder().decode(CamillaPlaybackClock.self, from: current)
                try diagnosticRequire(measured.callbackFrames == 512 && measured.bufferedFrames == 1536,
                    "Callback occupancy was discarded or confused with the extrapolated buffer estimate")
            },
            check("PD72", "Thirty-minute coarse capture retains bounded observations") {
                for seconds in [30.0, 240, 630, 1_830] {
                    let options = PerformanceCaptureOptions(duration: seconds, warmUp: 0, detailedAudioTracing: false)
                    let maximumObservations = Int(ceil(seconds / options.observationInterval)) + 2
                    try diagnosticRequire(maximumObservations < 1_024, "Long capture would overflow its observation bound")
                    if seconds <= 240 {
                        try diagnosticRequire(options.observationInterval == 0.5, "Short reference capture cadence changed")
                    }
                }
            },
            check("PD73", "Different source devices cannot share one delivery clock history") {
                var clocks = AudioClockDrift(started: origin)
                var first = sample(0); first.deviceID = 100
                clocks.observeSource(first); clocks.observeOutput(sample(0))
                var different = sample(1, epoch: 2); different.deviceID = 101
                clocks.observeSource(different)
                try unavailable(clocks.state(at: origin.advanced(seconds: 1)))
            }
        ]
    }
}
