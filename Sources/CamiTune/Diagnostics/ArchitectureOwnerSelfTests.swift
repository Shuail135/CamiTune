import CamiTuneAudio
import CamiTuneDomain
import Foundation

extension DeveloperSelfTests {
    static func architectureOwnerCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String, _ body: @escaping @MainActor (URL) throws -> Void) -> DiagnosticCase {
            DiagnosticCase(id: id, suite: "Architecture owners", name: name, safety: .simulated) {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                try body(box.directory)
                return .init(summary: name)
            }
        }
        return [
            check("AS01", "Delayed per-app saves cannot overwrite newer intent") { directory in
                let url = directory.appendingPathComponent("ordered-per-app.json")
                let store = PerAppSettingsStore(url: url)
                store.update(for: "test.app", invalidatesProcessing: false) { $0.volume = 0.25 }
                let older = store.snapshot
                store.update(for: "test.app", invalidatesProcessing: false) { $0.volume = 0.75 }
                let newer = store.snapshot
                // Deliberately reverse submission order; flush must retire the debounce.
                store.scheduleSave(newer) { _ in }
                store.scheduleSave(older) { _ in }
                let first = store.flush(older)
                let second = store.flush(older)
                let saved = try PerAppAudioDocument.decode(Data(contentsOf: url))
                try diagnosticRequire(saved["test.app"]?.volume == 0.75 && first.revision == newer.revision,
                    "An older captured document replaced newer intent")
                try diagnosticRequire(first.error == nil && second.error == nil && second.sequence > first.sequence,
                    "Persistence completions cannot be ordered for presentation")
            },
            check("AS02", "Per-app persistence preserves future and unreadable documents") { directory in
                for (index, text) in ["{\"schemaVersion\":99,\"settings\":{}}", "invalid JSON"].enumerated() {
                    let url = directory.appendingPathComponent("protected-\(index).json")
                    let bytes = Data(text.utf8)
                    try bytes.write(to: url)
                    let store = PerAppSettingsStore(url: url)
                    store.update(for: "test.app", invalidatesProcessing: true) { $0.isMuted = true }
                    let result = store.flush(store.snapshot)
                    try diagnosticRequire(store.loadError != nil && result.error != nil,
                        "Incompatible data was silently accepted")
                    let unchanged = try Data(contentsOf: url)
                    try diagnosticRequire(unchanged == bytes, "Original settings were overwritten")
                }
            },
            check("AS03", "Identity migration preserves stable settings and processing revisions") { directory in
                let url = directory.appendingPathComponent("migration.json")
                let store = PerAppSettingsStore(url: url)
                store.update(for: "test.app", invalidatesProcessing: true) { $0.volume = 0.8 }
                for _ in 0..<3 {
                    store.update(for: "pid:123", invalidatesProcessing: true) { $0.volume = 0.2 }
                }
                let before = store.snapshot.revision
                try diagnosticRequire(store.migrate(from: "pid:123", to: "test.app"), "Migration was ignored")
                try diagnosticRequire(store.settings(for: "test.app").volume == 0.8 && store.revision(for: "test.app") == 3,
                    "Temporary controls replaced stable intent or lost processing revision")
                store.update(for: "client:1:2", invalidatesProcessing: false) { $0.isMuted = true }
                try diagnosticRequire(store.snapshot.revision > before && store.flush(store.snapshot).error == nil,
                    "Migration did not create durable intent")
                let saved = try PerAppAudioDocument.decode(Data(contentsOf: url))
                try diagnosticRequire(Set(saved.keys) == ["test.app"], "Ephemeral identity escaped into persisted controls")
            },
            check("AS04", "Client registry rejects stale identity resolution") { _ in
                let lock = NSLock()
                let registry = PerAppClientRegistry(stateLock: lock, monitorsRunningApplications: false)
                lock.lock(); defer { lock.unlock() }
                let old = PerAppDriverClient(deviceObjectID: 1, clientID: 7, processID: 42,
                    bundleID: "test.old", isActive: true, generation: 1)
                let first = registry.replaceClients(.init([old]))!
                var current = old; current.processID = 43; current.bundleID = "test.new"; current.generation = 2
                let second = registry.replaceClients(.init([current]))!
                let identity = PerAppPresentationIdentity(id: "test.old", bundleID: "test.old", bundleURL: nil,
                    processID: 42, displayName: "Old", isDockApplication: true, isAccessoryApplication: false)
                try diagnosticRequire(registry.acceptResolution([old.transportKey: identity],
                    unresolvedActiveKeys: [], revision: first, attempt: 0) == nil, "Stale identity was accepted")
                let packet = PerAppAudioPacket(deviceObjectID: 1, clientID: 7, processID: 43, cycleCounter: 1,
                    sampleTime: 0, interleaved: [0, 0], channelCount: 2, sampleRate: 48_000)
                let resolved = registry.resolveStream(packet)
                try diagnosticRequire(second > first && resolved.application == nil && resolved.generation == 2
                    && resolved.fallbackApplicationID == "test.new", "Recycled stream acquired stale application controls")
            },
            check("AS05", "Ambiguous registry fallback never merges transport streams") { _ in
                let lock = NSLock()
                let registry = PerAppClientRegistry(stateLock: lock, monitorsRunningApplications: false)
                lock.lock(); defer { lock.unlock() }
                let a = PerAppDriverClient(deviceObjectID: 1, clientID: 7, processID: 42,
                    bundleID: "test.app", isActive: true, generation: 5)
                var b = a; b.deviceObjectID = 2; b.generation = 9
                _ = registry.replaceClients(.init([a, b]))
                func packet(_ device: UInt32) -> PerAppAudioPacket {
                    .init(deviceObjectID: device, clientID: 7, processID: 42, cycleCounter: 1,
                        sampleTime: 0, interleaved: [0, 0], channelCount: 2, sampleRate: 48_000)
                }
                try diagnosticRequire(registry.resolveStream(packet(1)).generation == 5
                    && registry.resolveStream(packet(2)).generation == 9
                    && registry.resolveStream(packet(3)).generation == 0,
                    "An ambiguous fallback borrowed another stream's generation")
            },
            check("AS06", "Cross-session resource reuse remains conservative for every compatibility dimension") { _ in
                let plan = try diffPlan(diffProfile())
                let base = RuntimePlanDiffer().delta(from: plan, to: plan)
                func replacing(endpoint: EndpointDelta? = nil, transport: TransportDelta? = nil,
                               physical: PhysicalRouteDelta? = nil, engine: EngineConfigurationDelta? = nil,
                               delivery: Bool = false) -> RuntimePlanDelta {
                    .init(fromRevision: base.fromRevision, toRevision: base.toRevision,
                        endpoint: endpoint ?? base.endpoint, transport: transport ?? base.transport,
                        physicalRoute: physical ?? base.physicalRoute, graph: base.graph,
                        renderer: base.renderer, metadata: base.metadata, engine: engine ?? base.engine,
                        pcmDeliveryChanged: delivery)
                }
                let cases: [(RuntimePlanDelta, RuntimeResourceReuseDecision.RestartReason)] = [
                    (base, .reuseNotQualified),
                    (replacing(endpoint: .init(uidChanged: true, displayNameChanged: false, routingDescriptorChanged: false)), .endpointChanged),
                    (replacing(endpoint: .init(uidChanged: false, displayNameChanged: false, routingDescriptorChanged: true)), .endpointChanged),
                    (replacing(physical: .init(outputDeviceUIDChanged: true, physicalEndpointFormatChanged: false,
                        hardwareOutputFormatChanged: false, hardwareFingerprintChanged: false)), .physicalRouteChanged),
                    (replacing(physical: .init(outputDeviceUIDChanged: false, physicalEndpointFormatChanged: false,
                        hardwareOutputFormatChanged: false, hardwareFingerprintChanged: true)), .physicalRouteChanged),
                    (replacing(transport: .init(sourceFormatChanged: false, dspInputFormatChanged: false, sampleRateChanged: true,
                        sourceChannelLayoutChanged: false, routingSemanticsChanged: false)), .transportChanged),
                    (replacing(transport: .init(sourceFormatChanged: false, dspInputFormatChanged: false, sampleRateChanged: false,
                        sourceChannelLayoutChanged: true, routingSemanticsChanged: false)), .transportChanged),
                    (replacing(transport: .init(sourceFormatChanged: false, dspInputFormatChanged: true, sampleRateChanged: false,
                        sourceChannelLayoutChanged: false, routingSemanticsChanged: false)), .transportChanged),
                    (replacing(engine: .init(chunkSizeChanged: true, captureChanged: false, exclusiveModeChanged: false, queueLimitChanged: false)), .backendChanged),
                    (replacing(engine: .init(chunkSizeChanged: false, captureChanged: false, exclusiveModeChanged: false, queueLimitChanged: true)), .backendChanged),
                    (replacing(delivery: true), .deliveryChanged)
                ]
                for (delta, reason) in cases {
                    let decision = RuntimeResourceReuseDecision.evaluate(delta)
                    try diagnosticRequire(decision == .cleanRestart(reason)
                        && decision == RuntimeResourceReuseDecision.evaluate(delta), "Reuse admitted an unqualified or incompatible transfer")
                }
            }
        ]
    }
}
