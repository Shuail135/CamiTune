import CamiTuneAudio
import CamiTuneDomain
import Foundation
import AppKit
import SwiftUI

// Explicit developer command; exercises the existing lifecycle without changing it.
@MainActor
enum LiveRuntimeBaseline {
    private static func configureEngine(_ path: String?, state: AppState) throws {
        guard let path else { return }
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw DiagnosticFailure(message: "Diagnostic engine must be an absolute executable path")
        }
        let binary = URL(fileURLWithPath: path)
        state.runtimeServices.startEngine = { [weak state] in
            guard let state else { throw DiagnosticFailure(message: "Diagnostic runtime retired") }
            try await state.dsp.start(binary: binary)
        }
    }

    /// Stage 10: a long complete metadata soak, with a separate bounded steady
    /// timing capture. Every process belongs to this harness and is cleaned up.
    static func policySoak(destination: String, silence: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let tracePath = environment["CAMITUNE_POLICY_TRACE_PATH"] else {
            throw DiagnosticFailure(message: "Policy soak requires CAMITUNE_POLICY_TRACE_PATH")
        }
        let duration = max(60, min(300, Int(environment["CAMITUNE_POLICY_SOAK_SECONDS"] ?? "120") ?? 120))
        let stress = environment["CAMITUNE_POLICY_CPU_STRESS"] == "1"
        let captureTails = environment["CAMITUNE_POLICY_CAPTURE_TAILS"] == "1"
        let original = ProfileStore(), box = try DiagnosticSandbox()
        defer { box.cleanUp() }
        box.profiles.profiles = original.profiles
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp)
        state.runtimeServices.notifyActivation = {}; state.runtimeServices.notifyDeactivation = {}
        for _ in 0..<100 where !state.coreAudio.hasCompletedInitialRefresh { try await Task.sleep(for: .milliseconds(100)) }
        guard let uid = state.coreAudio.defaultOutputUID,
              let profile = original.profiles.first(where: { $0.isEnabled && $0.outputDeviceUID == uid }) else {
            throw DiagnosticFailure(message: "No enabled profile matches the current physical output")
        }
        var processes: [Process] = []
        func launch(_ executable: String, _ arguments: [String]) throws -> Process {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); processes.append(process); return process
        }
        func terminateAll() { for process in processes where process.isRunning { process.terminate() } }
        do {
            await state.activate(profile: profile)
            guard state.isActive else { throw DiagnosticFailure(message: state.errorMessage ?? "Activation failed") }
            var primary = try launch("/usr/bin/afplay", [silence])
            var joining: Process?
            for second in 0..<duration {
                if second == 10 || second == 70 { joining = try launch("/usr/bin/afplay", [silence]) }
                if second == 40 || second == 100 { if joining?.isRunning == true { joining?.terminate() }; joining = nil }
                if let short = environment["CAMITUNE_POLICY_SHORT_SOUND"] {
                    if second == 52 && primary.isRunning { primary.terminate() }
                    if [53, 56, 59].contains(second) { _ = try launch("/usr/bin/afplay", [short]) }
                    if second == 61 { primary = try launch("/usr/bin/afplay", [silence]) }
                }
                if second == 20 && stress { for _ in 0..<2 { _ = try launch("/usr/bin/yes", []) } }
                if second == (captureTails ? 52 : 30) {
                    var options = PerformanceCaptureOptions(); options.duration = captureTails ? 12 : 20; options.warmUp = 0
                    options.scenario.label = "Stage 10 \(captureTails ? "short-sound tail capture near 52s" : "steady capture near 30s"), \(duration)s target speaker soak; mode \(environment["CAMITUNE_REORDER_MODE"] ?? "production"); controlled afplay clients; CPU stress \(stress)"
                    state.performanceRecorder.start(options: options, environment: { state.performanceEnvironment() })
                }
                try await Task.sleep(for: .seconds(1))
                if second % 30 == 29 { print("Policy soak: \(second + 1)/\(duration) seconds") }
            }
            await state.performanceRecorder.stop()
            terminateAll()
            try await Task.sleep(for: .milliseconds(100)) // Let the last real idle tail reach the writer.
            let final = state.perAppAudio.timelineStatisticsSnapshot()
            await state.deactivate()
            try state.perAppAudio.exportTimelinePolicyTrace(to: URL(fileURLWithPath: tracePath))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(final).write(to: URL(fileURLWithPath: destination + ".final-policy.json"), options: .atomic)
            guard let result = state.performanceRecorder.baseline, !result.packets.isEmpty, !result.samples.isEmpty else {
                throw DiagnosticFailure(message: "No usable live PCM session captured")
            }
            try result.json().write(to: URL(fileURLWithPath: destination), options: .atomic)
            try result.report().write(toFile: destination + ".txt", atomically: true, encoding: .utf8)
            print("Policy soak saved: \(result.packets.count) timed packets; \(final?.reorder.packets ?? 0) total packets; \(result.telemetryDrops) detailed trace drops")
        } catch {
            terminateAll(); await state.deactivate(); await state.performanceRecorder.stop(reason: "Policy soak failed")
            try? state.perAppAudio.exportTimelinePolicyTrace(to: URL(fileURLWithPath: tracePath))
            throw error
        }
    }

    static func capture(destination: String, silence: String, deliveryEvidence: Bool = false) async throws {
        let original = ProfileStore()
        let box = try DiagnosticSandbox()
        defer { box.cleanUp() }
        box.profiles.profiles = original.profiles
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp)
        state.runtimeServices.notifyActivation = {}
        state.runtimeServices.notifyDeactivation = {}
        for _ in 0..<100 where !state.coreAudio.hasCompletedInitialRefresh {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let uid = state.coreAudio.defaultOutputUID,
              var profile = original.profiles.first(where: { $0.isEnabled && $0.outputDeviceUID == uid }) else {
            throw DiagnosticFailure(message: "No enabled profile matches the current physical output; live baseline made no routing changes.")
        }
        var options = PerformanceCaptureOptions()
        let environment = ProcessInfo.processInfo.environment
        let workload = deliveryEvidence ? environment["CAMITUNE_DELIVERY_WORKLOAD"] ?? "current" : "current"
        let originalHardwareRate: Double?
        if deliveryEvidence, let text = environment["CAMITUNE_DELIVERY_SAMPLE_RATE"] {
            guard let rate = Int(text), [44_100, 48_000, 88_200, 96_000, 176_400, 192_000].contains(rate),
                  await state.coreAudioService.supportsSampleRateWithoutBlockingUI(uid: uid, rate: Double(rate)),
                  let originalRate = await state.coreAudioService.nominalSampleRateWithoutBlockingUI(uid: uid) else {
                throw DiagnosticFailure(message: "Diagnostic sample rate is invalid or unsupported by the physical output")
            }
            originalHardwareRate = originalRate
            // Use the same candidate normalization as the settings editor so
            // the speaker map and profile format advance together.
            var draft = ProfileSettingsDraft(profile: profile, activation: box.profiles.activationMode(for: profile))
            draft.sampleRate = rate
            profile = try draft.candidate()
        } else { originalHardwareRate = nil }
        func restoreHardwareRate() async throws {
            if let originalHardwareRate {
                try await state.coreAudioService.setSampleRate(uid: uid, rate: originalHardwareRate)
            }
        }
        switch workload {
        case "current": break
        case "eq20":
            profile.setPlaybackMode(.direct)
            let bands = (0..<20).map { index in
                EQBand(kind: .peaking, frequency: 32 * pow(500, Double(index) / 19), gain: -1, q: 1)
            }
            profile.processing.global.stages.append(.init(processor: .equalizer(.init(bands: bands))))
        case "spatial": profile.setPlaybackMode(.spatialRender)
        case "reference": profile.setPlaybackMode(.referencePlayback)
        case "convolution":
            guard let source = environment["CAMITUNE_DELIVERY_IMPULSE"], source.hasPrefix("/") else {
                throw DiagnosticFailure(message: "Convolution qualification requires an absolute impulse WAV path")
            }
            let store = ImpulseResponseStore(directory: box.directory.appendingPathComponent("impulses"))
            let asset = try store.importWAV(at: URL(fileURLWithPath: source), expectedSampleRate: profile.sampleRate)
            profile.setPlaybackMode(.direct)
            profile.processing = .init(global: .init(stages: [.init(processor: .convolution(.init(asset: asset)))]))
            state.runtimeServices.prepareAssets = { profile in
                try await Task.detached(priority: .userInitiated) {
                    try PreparedRuntimeAssets.prepare(profile: profile, directory: store.directory)
                }.value
            }
        default: throw DiagnosticFailure(message: "Invalid diagnostic delivery workload")
        }
        // Explicit diagnostic command only: run an isolated engine without
        // replacing the user's managed dependency or changing install state.
        let enginePath = deliveryEvidence ? environment["CAMITUNE_DELIVERY_ENGINE"] : nil
        if deliveryEvidence, let text = environment["CAMITUNE_DELIVERY_CHUNK"] {
            guard let chunk = Int(text), [128, 256, 512, 1024, 2048].contains(chunk) else {
                throw DiagnosticFailure(message: "Invalid diagnostic chunk size")
            }
            profile.chunkSize = chunk
        }
        let deliveryOverrides = ["CAMITUNE_DELIVERY_TARGET_FRAMES", "CAMITUNE_DELIVERY_QUEUE_LIMIT",
            "CAMITUNE_DELIVERY_RECOVERY_TARGET", "CAMITUNE_DELIVERY_RECOVERY",
            "CAMITUNE_DELIVERY_BACKLOG_GUARD", "CAMITUNE_DELIVERY_CLOCK_TRACKING",
            "CAMITUNE_DELIVERY_LEGACY_POLICY"]
        if deliveryEvidence && deliveryOverrides.contains(where: { environment[$0] != nil }) {
            func integer(_ name: String, default fallback: Int) throws -> Int {
                guard let text = environment[name] else { return fallback }
                guard let value = Int(text), value >= 0 else { throw DiagnosticFailure(message: "Invalid \(name)") }
                return value
            }
            let target = try integer("CAMITUNE_DELIVERY_TARGET_FRAMES", default: 0)
            let legacy = environment["CAMITUNE_DELIVERY_LEGACY_POLICY"] == "1"
            let defaults = legacy
                ? PCMDeliveryConfiguration.legacy(sampleRate: Double(profile.sampleRate), chunkSize: profile.chunkSize)
                : PCMDeliveryConfiguration.standard(sampleRate: Double(profile.sampleRate), chunkSize: profile.chunkSize)
            let limit = try integer("CAMITUNE_DELIVERY_QUEUE_LIMIT", default: defaults.camillaQueueLimit)
            let recoveryTarget = try integer("CAMITUNE_DELIVERY_RECOVERY_TARGET", default: 0)
            let trim = environment["CAMITUNE_DELIVERY_RECOVERY"] == "trimOldestToTarget"
            let guarded = environment["CAMITUNE_DELIVERY_BACKLOG_GUARD"] == "1"
            let clockTracked = environment["CAMITUNE_DELIVERY_CLOCK_TRACKING"] == "1"
            guard (1...64).contains(limit), !trim || target > 0, !guarded || target > 0,
                  !legacy || (!clockTracked && !guarded && target == 0),
                  !clockTracked || target > 0,
                  environment["CAMITUNE_DELIVERY_TARGET_FRAMES"] == nil || target > 0,
                  ["clearAll", "trimOldestToTarget"].contains(environment["CAMITUNE_DELIVERY_RECOVERY"] ?? "clearAll") else {
                throw DiagnosticFailure(message: "Invalid delivery candidate")
            }
            state.runtimeServices.deliveryConfiguration = { profile in
                let baseline = legacy ? PCMQueuePolicy.legacy(sampleRate: Double(profile.sampleRate), chunkSize: profile.chunkSize)
                    : PCMDeliveryConfiguration.standard(sampleRate: Double(profile.sampleRate), chunkSize: profile.chunkSize).queue
                return .init(queue: .init(sampleRate: Double(profile.sampleRate),
                    operatingTargetFrames: target > 0 ? target : baseline.operatingTargetFrames,
                    recoveryTargetFrames: recoveryTarget, hardLimitFrames: baseline.hardLimitFrames,
                    recoveryStrategy: trim ? .trimOldestToTarget : .clearAll,
                    rateTargetMode: clockTracked ? .clockTracked : target > 0 ? (guarded ? .configuredWhenQueued : .configured) : baseline.rateTargetMode), camillaQueueLimit: limit)
            }
        }
        try configureEngine(enginePath, state: state)
        if deliveryEvidence {
            // Settings drafts merge against the repository's current document.
            // Keep that document equal to this isolated candidate; otherwise
            // the save check below can restore the original chunk/mode/DSP.
            profile = try AudioRuntimePlanPreparer.normalize(profile)
            box.profiles.profiles = original.profiles.map { $0.id == profile.id ? profile : $0 }
        }
        let playbackSeconds = deliveryEvidence
            ? max(30, min(1_800, Int(environment["CAMITUNE_DELIVERY_SECONDS"] ?? "30") ?? 30)) : 30
        let stress = deliveryEvidence && environment["CAMITUNE_DELIVERY_STRESS"] == "1"
        guard !stress || playbackSeconds >= 60 else { throw DiagnosticFailure(message: "Stress comparison needs at least 60 seconds") }
        options.duration = Double(playbackSeconds + 30); options.warmUp = 0
        // Long captures use bounded coarse observations. Run a separate short
        // detailed capture; never overflow the recorder and call it a clean soak.
        options.detailedAudioTracing = playbackSeconds <= 30
        let showsUI = deliveryEvidence && environment["CAMITUNE_DELIVERY_UI"] == "1"
        options.scenario.label = "Live lifecycle baseline; \(playbackSeconds) seconds silent PCM through real bridge, CamillaDSP, and physical output; explicit DSP telemetry \(deliveryEvidence); SwiftUI rendering \(showsUI)"
        if deliveryEvidence { options.scenario.label += "; workload: \(workload) (isolated profile)" }
        let window: NSWindow?
        if showsUI {
            let view = ContentDetailView(state: state, profileStore: state.profiles,
                coreAudio: state.coreAudio, selection: .profile(profile.id))
                .environmentObject(MainWindowCommandCoordinator())
            let host = NSHostingController(rootView: view)
            let presented = NSWindow(contentViewController: host)
            presented.isReleasedWhenClosed = false
            presented.title = "CamiTune — audio qualification"
            presented.setContentSize(.init(width: 960, height: 720))
            presented.center(); presented.makeKeyAndOrderFront(nil)
            state.setMainWindowPresentationActive(true)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window = presented
        } else { window = nil }
        defer {
            if showsUI { state.setMainWindowPresentationActive(false) }
            window?.close()
        }
        if let enginePath { options.scenario.label += "; isolated diagnostic engine: \(enginePath)" }
        if deliveryEvidence, let target = environment["CAMITUNE_DELIVERY_TARGET_FRAMES"] {
            options.scenario.label += "; fixed writer target: \(target) frames"
        }
        if stress { options.scenario.label += "; overlapping afplay client at 10–40s, two CPU workers at 20–50s" }
        if deliveryEvidence && environment["CAMITUNE_DELIVERY_BACKLOG_GUARD"] == "1" {
            options.scenario.label += "; experimental standing-backlog guard"
        }
        if deliveryEvidence {
            options.scenario.label += "; UI telemetry hidden at 5–10s"
        }
        state.performanceRecorder.start(options: options, environment: { state.performanceEnvironment() })
        let player = Process()
        var extraPlayers: [Process] = [], cpuWorkers: [Process] = []
        func launch(_ executable: String, arguments: [String]) throws -> Process {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); return process
        }
        func stopExtras() { for p in extraPlayers + cpuWorkers where p.isRunning { p.terminate() } }
        do {
            await state.activate(profile: profile)
            guard state.isActive else { throw DiagnosticFailure(message: state.errorMessage ?? "Live activation failed") }
            if deliveryEvidence { state.meters.setPresentationActive(true, profileID: profile.id) }
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [silence]
            try player.run()
            try await Task.sleep(for: .seconds(2))
            var edited = profile
            edited.processing.global.stages.append(.init(processor: .gain(.init(gainDB: -1))))
            await state.apply(profile: edited)
            try diagnosticRequire(state.isActive, "Live EQ update stopped the runtime")
            await state.apply(profile: profile)
            try await state.saveProfileSettings(.init(profile: profile, activation: box.profiles.activationMode(for: profile)))
            if deliveryEvidence {
                try diagnosticRequire(state.runtimeCoordinator.appliedProfile == profile,
                    "Candidate profile changed during lifecycle setup")
            }
            for elapsed in 0..<playbackSeconds {
                if deliveryEvidence {
                    if elapsed == 5 {
                        window?.orderOut(nil)
                        if showsUI { state.setMainWindowPresentationActive(false) }
                        state.meters.setPresentationActive(false, profileID: profile.id)
                    }
                    if elapsed == 10 {
                        window?.makeKeyAndOrderFront(nil)
                        if showsUI { state.setMainWindowPresentationActive(true) }
                        state.meters.setPresentationActive(true, profileID: profile.id)
                    }
                }
                if let window {
                    state.setMainWindowPresentationActive(window.isVisible && !window.isMiniaturized
                        && window.occlusionState.contains(.visible))
                }
                if stress {
                    if elapsed == 10 { extraPlayers.append(try launch("/usr/bin/afplay", arguments: [silence])) }
                    if elapsed == 20 { for _ in 0..<2 { cpuWorkers.append(try launch("/usr/bin/yes", arguments: [])) } }
                    if elapsed == 40 { for p in extraPlayers where p.isRunning { p.terminate() } }
                    if elapsed == 50 { for p in cpuWorkers where p.isRunning { p.terminate() } }
                }
                try await Task.sleep(for: .seconds(1))
                let deliveryFailure = state.runtimeServices.transportError()
                // This isolated AppState disables background services. Exercise
                // the same coordinator health path explicitly, even with the
                // optional presentation telemetry hidden.
                await state.monitorRouting()
                try diagnosticRequire(deliveryFailure == nil, deliveryFailure ?? "PCM delivery fault")
                try diagnosticRequire(state.isActive, state.errorMessage ?? "Audio session stopped during the capture")
                if deliveryEvidence && elapsed % 30 == 29 {
                    NSLog("PCM delivery baseline: %d/%d seconds", elapsed + 1, playbackSeconds)
                }
                guard player.isRunning else { throw DiagnosticFailure(message: "Baseline source ended before the requested capture duration") }
                if stress && (10..<40).contains(elapsed) {
                    try diagnosticRequire(extraPlayers.allSatisfy(\.isRunning), "Overlapping audio source exited early")
                }
            }
            let priorDrains = state.pcmRouter.statistics.producerDrains.completedDrains
            stopExtras()
            if player.isRunning { player.terminate() }
            if deliveryEvidence && environment["CAMITUNE_DELIVERY_VERIFY_DRAIN"] == "1" {
                let deadline = PerformanceClock.now().advanced(seconds: 3)
                while state.pcmRouter.statistics.producerDrains.completedDrains <= priorDrains,
                      PerformanceClock.now() < deadline {
                    if let error = state.runtimeServices.transportError() { throw DiagnosticFailure(message: error) }
                    try diagnosticRequire(state.pcmRouter.statistics.camillaWriteFailures == 0, "Terminal pipe write failed")
                    try await Task.sleep(for: .milliseconds(10))
                }
                try diagnosticRequire(state.pcmRouter.statistics.producerDrains.completedDrains > priorDrains,
                    "No writer completion followed the stopped source; another producer may still be active")
                // Record the acknowledged writer drain before deactivation
                // resets the route. This is not a physical playback receipt.
                state.performanceRecorder.recordObservation()
            }
            await state.deactivate()
            try await restoreHardwareRate()
            await state.performanceRecorder.stop()
            guard let result = state.performanceRecorder.baseline else { throw DiagnosticFailure(message: "Missing live capture") }
            try result.json().write(to: URL(fileURLWithPath: destination), options: .atomic)
            try result.report().write(toFile: destination + ".txt", atomically: true, encoding: .utf8)
            let observedDelivery = result.observations.contains { $0.environment.queue.latestBlockFrames > 0 }
            guard observedDelivery && (!options.detailedAudioTracing || (!result.packets.isEmpty && !result.samples.isEmpty)) else {
                throw DiagnosticFailure(message: "Capture saved, but no real PCM delivery was observed")
            }
            if deliveryEvidence {
                try diagnosticRequire(result.observations.contains { $0.environment.dspBufferFrames != nil && $0.environment.dspLoad != nil },
                    "Capture saved, but no fresh DSP load/buffer evidence was observed")
            }
            if showsUI {
                try diagnosticRequire(result.observations.contains { $0.environment.windowVisible && $0.environment.profileVisible },
                    "Capture saved, but the editor never registered visible profile demand")
            }
            print("Live baseline saved: \(result.packets.count) packets, \(result.samples.count) writes, \(result.telemetryDrops) tracing observations lost")
        } catch {
            stopExtras()
            if player.isRunning { player.terminate() }
            await state.deactivate()
            await state.performanceRecorder.stop(reason: "Live baseline failed: \(error.localizedDescription)")
            if let result = state.performanceRecorder.baseline {
                try? result.json().write(to: URL(fileURLWithPath: destination), options: .atomic)
                try? result.report().write(toFile: destination + ".txt", atomically: true, encoding: .utf8)
            }
            do { try await restoreHardwareRate() }
            catch let restorationError {
                throw DiagnosticFailure(message: "\(error.localizedDescription); restoring the original sample rate failed: \(restorationError.localizedDescription)")
            }
            throw error
        }
    }
}

extension LiveRuntimeBaseline {
    /// Explicit developer command. Silent signal, isolated profiles, and restoration
    /// of the physical scalar/mute/rate even if any assertion fails.
    static func routeHandoff(destination: String, silence: String) async throws {
        let original = ProfileStore(), box = try DiagnosticSandbox()
        defer { box.cleanUp() }
        box.profiles.profiles = original.profiles
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp)
        try configureEngine(ProcessInfo.processInfo.environment["CAMITUNE_DELIVERY_ENGINE"], state: state)
        state.runtimeServices.notifyActivation = {}; state.runtimeServices.notifyDeactivation = {}
        let audio = state.coreAudioService
        await audio.refreshWithoutBlockingUI()
        guard let uid = state.coreAudio.defaultOutputUID,
              let profile = original.profiles.first(where: { $0.isEnabled && $0.outputDeviceUID == uid }),
              let physical = await audio.resolveDeviceWithoutBlockingUI(uid: uid), !physical.isRoutingDevice,
              let scalar = await audio.volumeWithoutBlockingUI(uid: uid),
              let muted = await audio.isMutedWithoutBlockingUI(uid: uid) else {
            throw DiagnosticFailure(message: "Live handoff test requires a connected, volume-controlled physical default with an enabled profile")
        }
        let rate = await audio.nominalSampleRateWithoutBlockingUI(uid: uid)
        let measuresSwitching = ProcessInfo.processInfo.environment["CAMITUNE_PROFILE_SWITCH_BENCHMARK"] == "1"
        var alternate = profile
        alternate.id = UUID()
        alternate.name = "Diagnostic profile switch"
        if measuresSwitching {
            // Only the sandbox document receives this temporary endpoint.
            box.profiles.profiles.append(alternate)
            var options = PerformanceCaptureOptions()
            options.duration = 120; options.warmUp = 0; options.detailedAudioTracing = false
            options.scenario.label = "Conservative profile switch and speaker handoff; isolated profiles; silent PCM"
            state.performanceRecorder.start(options: options, environment: { state.performanceEnvironment() })
        }
        var report = ["Stage 7 live route handoff", ProcessInfo.processInfo.operatingSystemVersionString, "Physical output: \(physical.name)", "Signal: silent PCM; no physical signal-envelope measurement"]
        let player = Process()
        func selectDefault(_ target: String) async throws {
            try await audio.setDefaultOutputAndWait(uid: target)
            // Production dispatches this event from the published snapshot.
            // This harness disables those subscriptions, so do not deliver a
            // synthetic event while a newer HAL observation is still pending.
            let deadline = PerformanceClock.now().advanced(seconds: 1)
            while audio.defaultOutputUID != target, PerformanceClock.now() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try diagnosticRequire(audio.defaultOutputUID == target,
                "Default-output observation did not publish the acknowledged route")
        }
        func restore() async {
            if player.isRunning { player.terminate() }
            // Deactivation republishes this document, removing the temporary
            // endpoint on both success and failure without writing user intent.
            box.profiles.profiles = original.profiles
            await state.deactivate(); await state.runtimeCoordinator.waitUntilSettled()
            try? await audio.setDefaultOutputAndWait(uid: uid)
            await audio.setMutedWithoutBlockingUI(uid: uid, muted: true)
            try? await audio.setVolumeWithoutBlockingUI(uid: uid, scalar: scalar)
            await audio.setMutedWithoutBlockingUI(uid: uid, muted: muted)
            if let rate { try? await audio.setSampleRate(uid: uid, rate: rate) }
        }
        do {
            await audio.setMutedWithoutBlockingUI(uid: uid, muted: true)
            try await audio.setVolumeWithoutBlockingUI(uid: uid, scalar: 0.08)
            await state.activate(profile: profile)
            try diagnosticRequire(state.isActive && state.acousticVolumeSnapshot?.muted == true, "Muted activation lost user mute")
            report.append("L7.2 muted activation: passed\n" + state.volumeHandoffSummary)
            await state.deactivate(); await state.runtimeCoordinator.waitUntilSettled()
            await audio.setMutedWithoutBlockingUI(uid: uid, muted: false)
            await state.activate(profile: profile)
            try diagnosticRequire(state.isActive && (state.acousticVolumeSnapshot?.scalar ?? 1) <= 0.1, "Low-volume activation lost attenuation")
            report.append("L7.1/L7.3 low-volume activation: passed\n" + state.volumeHandoffSummary)
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); player.arguments = [silence]; try player.run()
            let routingUID = ProfileRoutingDescriptor.uid(for: profile.id)
            for _ in 0..<3 {
                try await selectDefault(uid)
                state.runtimeCoordinator.handleDefaultOutputChange(uid)
                try diagnosticRequire(state.acousticVolumeSnapshot?.audibility == .held, "External departure did not hold audio")
                try await selectDefault(routingUID)
                state.runtimeCoordinator.handleDefaultOutputChange(routingUID)
                await state.runtimeCoordinator.waitUntilSettled()
                try diagnosticRequire(state.acousticVolumeSnapshot?.audibility == .permitted, "Ready route return stayed muted")
            }
            report.append("L7.6 rapid virtual/physical switching: passed (three cycles)")
            try await selectDefault(uid)
            state.runtimeCoordinator.handleDefaultOutputChange(uid)
            try await audio.setVolumeWithoutBlockingUI(uid: routingUID, scalar: 0.06)
            // Flush the actual serial volume listener/mirror queue before assertions.
            try await state.runtimeServices.prepareIncoming()
            try diagnosticRequire(state.acousticVolumeSnapshot?.audibility == .held && abs((state.acousticVolumeSnapshot?.scalar ?? 1) - 0.06) < 0.01, "Volume change reopened held route or lost the target")
            try await selectDefault(routingUID)
            state.runtimeCoordinator.handleDefaultOutputChange(routingUID)
            await state.runtimeCoordinator.waitUntilSettled()
            report.append("L7.4/L7.10 physical mirror and volume change while held: passed\n" + state.volumeHandoffSummary)
            var renamed = profile; renamed.name += " Stage7"
            await state.apply(profile: renamed)
            try diagnosticRequire(state.isActive, "Active metadata rename retired the runtime")
            let renamedDevice = await audio.resolveDeviceWithoutBlockingUI(uid: routingUID)
            try diagnosticRequire(renamedDevice?.name.contains("Stage7") == true, "Endpoint rename was not published")
            try await audio.setVolumeWithoutBlockingUI(uid: routingUID, scalar: 0.07)
            try await state.runtimeServices.prepareIncoming()
            try diagnosticRequire(abs((state.acousticVolumeSnapshot?.scalar ?? 1) - 0.07) < 0.01, "Volume control stopped after rename")
            await state.apply(profile: profile)
            report.append("L7.11 active endpoint rename and subsequent volume control: passed\n" + state.runtimeCoordinator.bindingSummary)
            if measuresSwitching {
                let firstSession = state.activeSession?.id
                await state.activate(profile: alternate)
                try diagnosticRequire(state.isActive && state.activeProfileID == alternate.id
                    && state.activeSession?.id != firstSession, "Profile switch did not acquire a fresh session")
                let secondSession = state.activeSession?.id
                await state.activate(profile: profile)
                try diagnosticRequire(state.isActive && state.activeProfileID == profile.id
                    && state.activeSession?.id != secondSession, "Return switch did not acquire a fresh session")
                report.append("Conservative profile switch and return: passed; fresh session identities; reuse disabled")
                box.profiles.profiles = original.profiles
            }
            try await Task.sleep(for: .seconds(2))
            await state.deactivate(); await state.runtimeCoordinator.waitUntilSettled()
            await audio.refreshDefaultOutput()
            try diagnosticRequire(state.coreAudio.defaultOutputUID == uid, "Stop failed to restore physical output")
            report.append("L7.1 Stop and physical restoration: passed\n" + state.coreAudioSummary)
            await restore()
            await audio.refreshDefaultOutput()
            let restoredScalar = await audio.volumeWithoutBlockingUI(uid: uid)
            let restoredMute = await audio.isMutedWithoutBlockingUI(uid: uid)
            try diagnosticRequire(state.coreAudio.defaultOutputUID == uid && restoredMute == muted && abs((restoredScalar ?? -1) - scalar) < 0.01, "Original physical state could not be verified after restoration")
            report.append("Original physical volume, mute, sample rate and default output restored")
            if measuresSwitching {
                await state.performanceRecorder.stop()
                guard let baseline = state.performanceRecorder.baseline else { throw DiagnosticFailure(message: "Missing switch capture") }
                try diagnosticRequire(baseline.operations.filter { $0.kind == "Profile switch" && $0.result == "success" }.count == 2,
                    "Both conservative switches must have measured successful phases")
                try baseline.json().write(to: URL(fileURLWithPath: destination + ".performance.json"), options: .atomic)
                try baseline.report().write(toFile: destination + ".performance.txt", atomically: true, encoding: .utf8)
            }
            report.append("Unavailable: fixed-volume output; second physical output; physical unplug/replug; external signal-envelope capture. Driver restart not performed.")
            try report.joined(separator: "\n\n").write(toFile: destination, atomically: true, encoding: .utf8)
            print("Live handoff checks saved to \(destination)")
        } catch {
            await restore()
            if measuresSwitching { await state.performanceRecorder.stop(reason: "Profile switch qualification failed") }
            report.append("FAILED: \(error.localizedDescription)")
            try? report.joined(separator: "\n\n").write(toFile: destination, atomically: true, encoding: .utf8)
            throw error
        }
    }
}
