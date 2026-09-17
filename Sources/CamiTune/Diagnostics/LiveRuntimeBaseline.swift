import Foundation

// Explicit developer command; exercises the existing lifecycle without changing it.
@MainActor
enum LiveRuntimeBaseline {
    static func capture(destination: String, silence: String) async throws {
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
              let profile = original.profiles.first(where: { $0.isEnabled && $0.outputDeviceUID == uid }) else {
            throw DiagnosticFailure(message: "No enabled profile matches the current physical output; live baseline made no routing changes.")
        }
        var options = PerformanceCaptureOptions()
        options.duration = 90; options.warmUp = 0
        options.scenario.label = "Live lifecycle baseline; 30 seconds silent PCM through real bridge, CamillaDSP, and physical output"
        state.performanceRecorder.start(options: options, environment: { state.performanceEnvironment() })
        let player = Process()
        do {
            await state.activate(profile: profile)
            guard state.isActive else { throw DiagnosticFailure(message: state.errorMessage ?? "Live activation failed") }
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
            try await Task.sleep(for: .seconds(30))
            if player.isRunning { player.terminate() }
            await state.deactivate()
            await state.performanceRecorder.stop()
            guard let result = state.performanceRecorder.baseline else { throw DiagnosticFailure(message: "Missing live capture") }
            try result.json().write(to: URL(fileURLWithPath: destination), options: .atomic)
            try result.report().write(toFile: destination + ".txt", atomically: true, encoding: .utf8)
            guard !result.packets.isEmpty, !result.samples.isEmpty else {
                throw DiagnosticFailure(message: "Capture saved, but no real PCM delivery was observed")
            }
            print("Live baseline saved: \(result.packets.count) packets, \(result.samples.count) writes, \(result.telemetryDrops) tracing observations lost")
        } catch {
            if player.isRunning { player.terminate() }
            await state.deactivate()
            await state.performanceRecorder.stop(reason: "Live baseline failed")
            throw error
        }
    }
}
