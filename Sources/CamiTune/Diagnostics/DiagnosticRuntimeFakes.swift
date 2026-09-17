import Foundation

/// One-shot, cancellation-aware suspension. No wall-clock delay selects the race.
@MainActor
final class DiagnosticManualGate {
    private var entered = false
    private var released = false
    private var blocked: CheckedContinuation<Void, Error>?
    private var observers: [UUID: CheckedContinuation<Void, Error>] = [:]

    func enter() async throws {
        entered = true
        let waiting = observers.values
        observers.removeAll()
        for observer in waiting { observer.resume() }
        guard !released else { try Task.checkCancellation(); return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { blocked = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func waitUntilEntered() async throws {
        try Task.checkCancellation()
        guard !entered else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { registerObserver(id, continuation) }
            }
        } onCancel: {
            Task { @MainActor in self.observers.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    private func registerObserver(_ id: UUID, _ continuation: CheckedContinuation<Void, Error>) {
        observers[id] = continuation
    }

    func release() {
        released = true
        blocked?.resume(); blocked = nil
    }

    func cancel() {
        released = true
        blocked?.resume(throwing: CancellationError()); blocked = nil
        let waiting = observers.values
        observers.removeAll()
        for observer in waiting { observer.resume(throwing: CancellationError()) }
    }
}

struct DiagnosticHardware: AudioHardwareTopologyProvider {
    var channels = 2
    func topology(for deviceUID: String, sampleRate: Double) throws -> DetectedHardwareTopology {
        let endpoints = (0..<channels).map { index in
            SpeakerEndpoint(id: PhysicalOutputID(deviceUID: deviceUID, channelIndex: index),
                            role: index == 0 ? .left : index == 1 ? .right : .unknown,
                            displayName: "Output \(index + 1)", connectionState: .confirmedByUser)
        }
        return try DetectedHardwareTopology(speakerTopology: SpeakerTopology(deviceUID: deviceUID,
            sampleRate: sampleRate, declaredChannelCount: channels, endpoints: endpoints))
    }
}

@MainActor
final class DiagnosticSandbox {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let profiles: ProfileStore
    let perApp: PerAppAudioController

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CamiTune-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        suite = "CamiTune.Diagnostics.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw DiagnosticFailure(message: "Cannot create isolated preferences") }
        self.defaults = defaults
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        profiles = ProfileStore(storageURL: directory.appendingPathComponent("profiles.json"), userDefaults: defaults)
        perApp = PerAppAudioController(settingsURL: directory.appendingPathComponent("per-app.json"),
            audioHistoryURL: directory.appendingPathComponent("history.json"), monitorsRunningApplications: false)
    }

    func cleanUp() {
        profiles.flushPendingSaveSynchronously()
        perApp.resetRuntime()
        perApp.flushPendingSaveSynchronously()
        perApp.presentationStore.flushPendingSaveSynchronously()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    static func profile() -> DeviceProfile {
        DeviceProfile(name: "Diagnostic fixture", outputDeviceUID: "diagnostic.output", outputDeviceName: "Simulated output")
    }
}

/// Scripted external environment. No implementation here performs activation or teardown.
@MainActor
final class DiagnosticRuntimeFakes {
    struct Scenario {
        var outputPresent = true
        var engineFails = false
        var graphFails = false
        var restoreFails = false
        var transportResults = [true]
        var routingGate: DiagnosticManualGate?
        var engineGate: DiagnosticManualGate?
        var graphGate: DiagnosticManualGate?
        var transportGate: DiagnosticManualGate?
    }
    var scenario: Scenario
    private(set) var events: [String] = []
    var renderConfigurations: [RenderConfiguration] = []
    var graphs: [ProcessingGraph] = []
    private var backendGraph: ProcessingGraph?
    private var graphUpdate: String?
    private(set) var resources: Set<String> = []
    private(set) var transportAttempts = 0
    var defaultUID: String? = "diagnostic.output"
    let stopped = DiagnosticManualGate()
    let output = AudioDeviceInfo(id: "diagnostic.output", objectID: 100, name: "Simulated output")
    let bridge = AudioDeviceInfo(id: AudioDeviceInfo.systemAudioBridgeUID, objectID: 101, name: "Simulated bridge")

    init(_ scenario: Scenario = Scenario()) { self.scenario = scenario }
    func record(_ event: String) { events.append(event) }
    func start(_ resource: String) { record("start \(resource)"); resources.insert(resource) }
    func stop(_ resource: String) { record("stop \(resource)"); resources.remove(resource) }
    func fail(_ message: String) -> DiagnosticFailure { DiagnosticFailure(message: message) }

    func services() -> AudioRuntimeServices {
        AudioRuntimeServices(
            synchronous: .init(stopTransport: { self.stop("transport") }, stopPCM: { self.stop("PCM") },
                closeEngineInput: { self.record("close engine input") }, stopSpectrum: { self.stop("spectrum") },
                stopEngine: { self.stop("engine") }, stopVolume: { self.stop("volume") },
                setDefaultOutput: { self.defaultUID = $0; self.record("restore output") },
                hideBridge: { self.record("hide bridge") }),
            refreshDependencies: { self.record("refresh dependencies") },
            engineAvailable: { true },
            resolveBridge: { self.record("resolve bridge"); return self.bridge },
            freshBridge: { self.bridge },
            presentationSupported: { true },
            bridgeLayout: { .stereo },
            resolveOutput: { _ in self.record("resolve output"); return self.scenario.outputPresent ? self.output : nil },
            probeTopology: { output in try DiagnosticHardware().topology(for: output.id, sampleRate: 48_000).speakerTopology },
            outputChannelCount: { _ in 2 },
            supportsRate: { _, _ in true },
            defaultOutput: { self.defaultUID },
            cachedDevice: { uid in self.scenario.outputPresent && uid == self.output.id ? self.output : nil },
            hasSnapshot: { true },
            nominalRate: { _ in 48_000 },
            synchronizeRouting: { _, _, _, _ in self.record("synchronize routing") },
            waitForRouting: { id in
                self.record("wait for routing")
                do { try await self.scenario.routingGate?.enter() } catch { return nil }
                return AudioDeviceInfo(id: ProfileRoutingDescriptor.uid(for: id), objectID: 102, name: "Simulated routing")
            },
            hideBridge: { self.record("hide bridge") },
            setRate: { uid, _ in self.record("set rate \(uid == self.output.id ? "physical" : "bridge")") },
            setDefaultOutput: { uid in
                self.record(uid == self.output.id ? "restore output" : "select routing")
                if uid == self.output.id && self.scenario.restoreFails { throw self.fail("Simulated restoration failure") }
                self.defaultUID = uid
            },
            startEngine: {
                try await self.scenario.engineGate?.enter()
                if self.scenario.engineFails { throw self.fail("Simulated engine failure") }
                self.start("engine")
            },
            resetEngine: { self.backendGraph = nil; self.graphUpdate = nil; self.record("reset engine") },
            playbackDevices: { [self.output.id] },
            graphUpdateDescription: { self.graphUpdate },
            applyGraph: { graph in
                self.graphs.append(graph)
                self.record("apply graph")
                try await self.scenario.graphGate?.enter()
                if self.scenario.graphFails { throw self.fail("Simulated graph failure") }
                self.graphUpdate = self.backendGraph.map { ProcessingGraphDiffer().update(from: $0, to: graph).kind }
                    ?? "fullConfiguration"
                self.backendGraph = graph
            },
            startObservations: { _ in self.start("observations") },
            startVolume: { _, _, _ in self.start("volume"); return { _, _ in } },
            volumeMode: { nil },
            startPCM: { plan, _ in self.renderConfigurations.append(plan.renderConfiguration); self.start("PCM") },
            applyRenderConfiguration: { self.renderConfigurations.append($0); self.record("apply renderer") },
            startTransport: { _, _, _, _ in
                try await self.scenario.transportGate?.enter()
                let attempt = self.transportAttempts
                self.transportAttempts += 1
                self.record("attempt transport")
                guard attempt < self.scenario.transportResults.count, self.scenario.transportResults[attempt] else {
                    throw self.fail("Simulated transport failure")
                }
                self.start("transport")
            },
            prepareVolume: { self.record("prepare volume") },
            startSpectrum: { _ in self.start("spectrum") },
            beginHandoff: { self.record("begin handoff") },
            stopObservations: { self.stop("observations") },
            stopTransport: { self.stop("transport") },
            stopPCM: { self.stop("PCM") },
            closeEngineInput: { self.record("close engine input") },
            stopSpectrum: { self.stop("spectrum") },
            stopEngine: { self.stop("engine") },
            stopVolume: { self.stop("volume") },
            transportError: { nil },
            notifyActivation: { self.record("notify activation") },
            notifyDeactivation: { self.record("notify deactivation") },
            sleep: { _ in try Task.checkCancellation(); self.record("sleep") },
            transitionFinished: { active in
                self.record(active ? "transition active" : "transition inactive")
                if !active { self.stopped.release() }
            }
        )
    }

    func assertStopped(_ state: AppState) throws {
        try diagnosticRequire(!state.isActive && state.activeSession == nil && !state.transitionInProgress, "Expected an inactive, settled runtime")
        try diagnosticRequire(resources.isEmpty, "Resources still owned: \(resources.sorted())")
        let order = ["stop transport", "stop PCM", "close engine input", "stop engine", "stop volume"]
        let indices = order.compactMap { events.lastIndex(of: $0) }
        try diagnosticRequire(indices == indices.sorted(), "Unexpected teardown ordering: \(events)")
    }

    var evidence: [DiagnosticEvidence] {
        [.init(name: "Transport attempts", value: "\(transportAttempts)"),
         .init(name: "Remaining resources", value: resources.sorted().joined(separator: ", ")),
         .init(name: "Events", value: events.joined(separator: " → "))]
    }
}
