import CamiTuneDomain
import Foundation
import Combine

/// A real repository worker can enter here and block without involving MainActor.
/// Test scheduling is selected by handshakes, never sleeps or disk timing.
final class DiagnosticProfileIO: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false
    private var entered = false
    private var fail = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var documents: [ProfileDocument] = []
    private var active = 0
    private var peak = 0
    var writes: [ProfileDocument] { condition.lock(); defer { condition.unlock() }; return documents }
    var maximumWriters: Int { condition.lock(); defer { condition.unlock() }; return peak }
    func arm() { condition.lock(); held = true; entered = false; fail = false; condition.unlock() }
    func release(failing: Bool = false) { condition.lock(); fail = failing; held = false; condition.broadcast(); condition.unlock() }
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if entered { condition.unlock(); continuation.resume() }
            else { observers.append(continuation); condition.unlock() }
        }
    }
    var adapter: ProfileRepositoryFileIO {
        .init(load: ProfileRepositoryFileIO.live.load, persist: { [self] document, url in
            condition.lock(); active += 1; peak = max(peak, active)
            entered = true; let waiting = observers; observers = []; condition.unlock()
            waiting.forEach { $0.resume() }
            condition.lock()
            while held { condition.wait() }
            let shouldFail = fail; fail = false
            condition.unlock()
            defer { condition.lock(); active -= 1; condition.unlock() }
            if shouldFail { throw DiagnosticFailure(message: "Injected profile write failure") }
            let timing = try ProfileRepositoryFileIO.live.persist(document, url)
            condition.lock(); documents.append(document); condition.unlock()
            return timing
        })
    }
}

@MainActor
final class ProfileRepositoryFixture {
    let box: DiagnosticSandbox
    let io = DiagnosticProfileIO()
    let repository: ProfileRepository
    let store: ProfileStore
    let profile = DiagnosticSandbox.profile()
    lazy var other = DeviceProfile(name: "Other profile", outputDeviceUID: profile.outputDeviceUID, outputDeviceName: profile.outputDeviceName)
    let fake = DiagnosticRuntimeFakes(.init(transportResults: Array(repeating: true, count: 30)))
    lazy var state = AppState(profiles: store, perAppAudio: box.perApp, runtimeServices: fake.services())
    init() throws {
        box = try DiagnosticSandbox()
        repository = ProfileRepository(url: box.directory.appendingPathComponent("repository.json"), io: io.adapter)
        store = ProfileStore(storageURL: box.directory.appendingPathComponent("transaction.json"), userDefaults: box.defaults, fileIO: io.adapter)
    }
    func document(_ name: String) -> ProfileDocument {
        var profile = DiagnosticSandbox.profile(); profile.name = name
        return .init(profiles: [profile], physicalDeviceDefaults: [], folders: [], rootOrder: [], layoutDefaults: [:], showProfileEnabledExplanation: true)
    }
    func submit(_ name: String, _ revision: UInt64, _ kind: ProfilePersistenceKind = .autosave) -> ProfilePersistenceTicket {
        repository.submit(document(name), source: .init(rawValue: revision), kind: kind)
    }
    func prepareStore() async throws {
        store.profiles = [profile, other]
        try await store.flushPendingSave()
    }
    func draft() -> ProfileSettingsDraft {
        var draft = ProfileSettingsDraft(profile: profile, activation: store.activationMode(for: profile))
        draft.name = "Saved B"; return draft
    }
    func save() async throws -> ProfilePersistenceReceipt {
        var candidate = profile; candidate.name = "Saved B"
        let activation = store.activationMode(for: profile)
        return try await store.commitSettings(candidate, expected: profile, originalActivation: activation, activation: activation)
    }
    func readStore() throws -> ProfileDocument {
        try JSONDecoder().decode(ProfileDocument.self, from: Data(contentsOf: box.directory.appendingPathComponent("transaction.json")))
    }
    func waitForDurableCommit() async {
        for await value in store.$hasDurableCommit.values { if value { return } }
    }
    func cleanUp() { io.release(); repository.drainSynchronously(); state.shutdownSynchronously(); box.cleanUp() }
}

extension DeveloperSelfTests {
    static func profileRepositoryCases() -> [DiagnosticCase] {
        func test(_ id: String, _ name: String, _ body: @escaping @MainActor (ProfileRepositoryFixture) async throws -> Void) -> DiagnosticCase {
            DiagnosticCase(id: id, suite: "Profile Repository & Persistence", name: name, safety: .simulated) {
                let f = try ProfileRepositoryFixture(); defer { f.cleanUp() }
                try await body(f); return .init(summary: name)
            }
        }
        return [
            test("PR01", "Revisioned document survives round trip") { f in
                let document = f.document("Round trip")
                let result = try await f.repository.submit(document, source: .init(rawValue: 1), kind: .settingsTransaction).value().get()
                guard case .committed(let receipt) = result else { throw DiagnosticFailure(message: "Durable write superseded") }
                let loaded = ProfileRepository(url: f.box.directory.appendingPathComponent("repository.json"))
                try diagnosticRequire(loaded.loadedDocument?.profiles == document.profiles && loaded.status.lastCommittedRevision == receipt.documentRevision && loaded.loadedDocument?.schemaVersion == 7, "Revision or profile changed on reload")
            },
            test("PR02", "Legacy array and schema 6 migrate to revisioned schema") { f in
                for legacy in [true, false] {
                    let url = f.box.directory.appendingPathComponent("migration-\(legacy).json")
                    var document = f.document("Legacy"); document.schemaVersion = 6
                    let bytes = try legacy ? JSONEncoder().encode(document.profiles) : JSONEncoder().encode(document)
                    try bytes.write(to: url)
                    let repository = ProfileRepository(url: url)
                    guard let loaded = repository.loadedDocument else { throw DiagnosticFailure(message: "Migration failed") }
                    _ = try await repository.submit(loaded, source: .init(rawValue: 1), kind: .settingsTransaction).value().get()
                    let saved = try JSONDecoder().decode(ProfileDocument.self, from: Data(contentsOf: url))
                    try diagnosticRequire(saved.schemaVersion == 7 && saved.documentRevision.rawValue == 1 && saved.profiles == document.profiles, "Migration lost content/revision")
                }
            },
            test("PR03", "Future storage rejects every write kind") { f in
                let url = f.box.directory.appendingPathComponent("future.json"), bytes = Data(#"{"schemaVersion":999,"profiles":[]}"#.utf8)
                try bytes.write(to: url); let repository = ProfileRepository(url: url)
                for kind: ProfilePersistenceKind in [.autosave, .settingsTransaction, .shutdownFlush] {
                    let result = await repository.submit(f.document("Forbidden"), source: .init(rawValue: 1), kind: kind).value()
                    if case .success = result { throw DiagnosticFailure(message: "Protected write accepted") }
                }
                let after = try Data(contentsOf: url)
                try diagnosticRequire(after == bytes, "Future bytes changed")
            },
            test("PR04", "Autosave burst retains only newest pending document") { f in
                f.io.arm(); let first = f.submit("1", 1); await f.io.waitUntilEntered()
                var tickets: [ProfilePersistenceTicket] = []
                for revision in 2...100 { tickets.append(f.submit(String(revision), UInt64(revision))) }
                f.io.release(); _ = try await first.value().get()
                for ticket in tickets { _ = try await ticket.value().get() }
                try diagnosticRequire(f.io.writes.count == 2 && f.io.writes.last?.profiles.first?.name == "100", "Autosave burst was not coalesced")
            },
            test("PR05", "Started old autosave completes before durable Save") { f in
                f.io.arm(); let old = f.submit("A", 1); await f.io.waitUntilEntered()
                let durable = f.submit("B", 2, .settingsTransaction)
                f.io.release(); _ = try await old.value().get(); _ = try await durable.value().get()
                try diagnosticRequire(f.io.writes.map { $0.profiles[0].name } == ["A", "B"], "Old write overtook durable Save")
            },
            test("PR06", "Late older autosave is rejected at repository") { f in
                _ = try await f.submit("20", 20).value().get(); _ = try await f.submit("21", 21).value().get()
                let result = try await f.submit("stale", 20).value().get()
                guard case .superseded = result else { throw DiagnosticFailure(message: "Stale autosave committed") }
                try diagnosticRequire(f.io.writes.count == 2 && f.repository.status.lastError == nil, "Supersession became a write/error")
            },
            test("PR07", "Durable Save replaces an unstarted autosave") { f in
                f.io.arm(); let first = f.submit("first", 1, .settingsTransaction); await f.io.waitUntilEntered()
                let pending = f.submit("old", 2), durable = f.submit("new", 3, .settingsTransaction)
                guard case .superseded = try await pending.value().get() else { throw DiagnosticFailure(message: "Pending autosave not superseded") }
                f.io.release(); _ = try await first.value().get(); _ = try await durable.value().get()
                try diagnosticRequire(f.io.writes.map { $0.profiles[0].name } == ["first", "new"], "Obsolete autosave was written")
            },
            test("PR08", "Accepted durable transactions are never coalesced") { f in
                f.io.arm(); let first = f.submit("50", 50, .settingsTransaction); await f.io.waitUntilEntered()
                let second = f.submit("51", 51, .settingsTransaction)
                f.io.release(); _ = try await first.value().get(); _ = try await second.value().get()
                try diagnosticRequire(f.io.writes.map { $0.profiles[0].name } == ["50", "51"], "Durable transaction disappeared")
            },
            test("PR09", "Repository permits exactly one filesystem writer") { f in
                f.io.arm(); let first = f.submit("first", 1, .settingsTransaction); await f.io.waitUntilEntered()
                let others = (2...15).map { f.submit(String($0), UInt64($0), .settingsTransaction) }
                f.io.release(); _ = try await first.value().get()
                for ticket in others { _ = try await ticket.value().get() }
                try diagnosticRequire(f.io.maximumWriters == 1 && f.io.writes.count == 15, "Concurrent file writers or lost durable requests")
            }
        ]
    }
}

extension DeveloperSelfTests {
    static func profilePersistenceCases() -> [DiagnosticCase] {
        func test(_ id: String, _ name: String, _ body: @escaping @MainActor (ProfileRepositoryFixture) async throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "Profile Repository & Persistence", name: name, safety: .simulated) {
                let f = try ProfileRepositoryFixture(); defer { f.cleanUp() }
                try await f.prepareStore()
                try await body(f); return .init(summary: name)
            }
        }
        func volume(_ id: String, fail: Bool) -> DiagnosticCase {
            test(id, fail ? "Failed Save preserves live volume and successor autosave" : "Successful Save preserves live volume and successor autosave") { f in
                f.store.setOutputVolumeScalar(profileID: f.profile.id, scalar: 0.4)
                try await f.store.flushPendingSave(); f.io.arm()
                let task = Task { try await f.save() }; await f.io.waitUntilEntered()
                f.store.setOutputVolumeScalar(profileID: f.profile.id, scalar: 0.55)
                f.io.release(failing: fail)
                let result = await task.result
                if fail { if case .success = result { throw DiagnosticFailure(message: "Failure not reported") } }
                else { _ = try result.get() }
                try await f.store.flushPendingSave()
                let profile = f.store.profiles.first { $0.id == f.profile.id }!
                let disk = try f.readStore().profiles.first { $0.id == f.profile.id }!
                try diagnosticRequire(profile.outputVolumeScalar == 0.55 && disk == profile && profile.name == (fail ? f.profile.name : "Saved B"), "Save lost latest volume or persisted failed settings")
            }
        }
        func unrelated(_ id: String, fail: Bool) -> DiagnosticCase {
            test(id, fail ? "Failed Save retains unrelated organization edit" : "Successful Save merges unrelated organization edit") { f in
                f.io.arm(); let task = Task { try await f.save() }; await f.io.waitUntilEntered()
                let folder = f.store.addFolder(name: "Concurrent folder")
                f.io.release(failing: fail); let result = await task.result
                if !fail { _ = try result.get() }
                try await f.store.flushPendingSave()
                let disk = try f.readStore()
                try diagnosticRequire(disk.folders.contains { $0.id == folder } && f.store.folders == disk.folders && disk.profiles[0].name == (fail ? f.profile.name : "Saved B"), "Whole-document publication lost an unrelated edit")
            }
        }
        func supersession(_ id: String, stop: Bool, fail: Bool) -> DiagnosticCase {
            test(id, "Persistence \(fail ? "failure" : "success") after \(stop ? "Stop" : "profile switch") preserves newer runtime") { f in
                await f.state.activate(profile: f.profile)
                f.io.arm(); let task = Task { try await f.state.saveProfileSettings(f.draft()) }; await f.io.waitUntilEntered()
                try diagnosticRequire(f.state.runtimeCoordinator.pendingPersistenceCount == 1 && !f.state.transitionInProgress, "Disk wait locked runtime reconciliation")
                if stop { await f.state.deactivate(manual: true) }
                else { await f.state.activate(profile: f.other) }
                let ownership = f.state.runtimeCoordinator.currentOwnershipID
                let starts = f.fake.events.filter { $0 == "start engine" }.count
                f.io.release(failing: fail); let result = await task.result
                if fail { if case .success = result { throw DiagnosticFailure(message: "Failed Save succeeded") } }
                else { _ = try result.get() }
                try diagnosticRequire(f.state.activeProfileID == (stop ? nil : f.other.id) && f.state.runtimeCoordinator.currentOwnershipID == ownership && f.state.runtimeCoordinator.pendingPersistenceCount == 0 && f.fake.events.filter { $0 == "start engine" }.count == starts, "Old persistence altered newer runtime")
                try diagnosticRequire(f.store.profiles[0].name == (fail ? f.profile.name : "Saved B"), "Wrong document published after runtime supersession")
            }
        }
        return [
            test("PR10", "Autosave failure preserves edited memory") { f in
                f.store.profiles[0].name = "Ordinary edit"; f.io.arm()
                let task = Task { try await f.store.flushPendingSave() }; await f.io.waitUntilEntered(); f.io.release(failing: true)
                if case .success = await task.result { throw DiagnosticFailure(message: "Failed autosave succeeded") }
                try diagnosticRequire(f.store.profiles[0].name == "Ordinary edit" && f.store.persistenceError != nil, "Autosave failure rolled back memory or hid error")
            },
            test("PR11", "New autosave success clears the current failure") { f in
                f.io.arm(); let failed = Task { try await f.store.flushPendingSave() }; await f.io.waitUntilEntered(); f.io.release(failing: true)
                _ = await failed.result
                f.store.profiles[0].name = "Retry"; try await f.store.flushPendingSave()
                try diagnosticRequire(f.store.persistenceError == nil && f.store.repository.status.lastError == nil, "New success did not clear error")
            },
            test("PR12", "Older failed autosave completion cannot replace durable success") { f in
                let delivery = DiagnosticManualGate()
                f.store.beforeAutosaveResult = { try? await delivery.enter() }
                defer { delivery.release(); f.store.beforeAutosaveResult = nil }
                f.io.arm(); let old = Task { try await f.store.flushPendingSave() }; await f.io.waitUntilEntered()
                f.io.release(failing: true)
                try await delivery.waitUntilEntered()
                _ = try await f.save()
                try diagnosticRequire(f.store.persistenceError == nil, "Durable success was not healthy")
                delivery.release(); _ = await old.result
                try diagnosticRequire(f.store.persistenceError == nil && f.store.repository.status.lastError == nil, "Delayed autosave error replaced durable result")
            },
            test("PR13", "Settings candidate remains unpublished until durability") { f in
                f.io.arm(); let task = Task { try await f.save() }; await f.io.waitUntilEntered()
                try diagnosticRequire(f.store.profiles[0].name == f.profile.name, "Candidate published before write")
                f.io.release(); _ = try await task.value
                try diagnosticRequire(f.store.profiles[0].name == "Saved B", "Durable mutation not published")
            },
            test("PR14", "MainActor heartbeat and selection progress while disk is held") { f in
                f.io.arm(); let task = Task { try await f.save() }; await f.io.waitUntilEntered()
                var heartbeats = 0
                for _ in 0..<20 { await Task { @MainActor in heartbeats += 1 }.value }
                f.store.selectedProfileID = f.other.id
                try diagnosticRequire(heartbeats == 20 && f.store.selectedProfileID == f.other.id && f.store.hasDurableCommit, "MainActor blocked by persistence")
                f.io.release(); _ = try await task.value
            },
            test("PR15", "Failed current Save leaves settings unchanged and rolls back owned runtime") { f in
                await f.state.activate(profile: f.profile); let old = f.state.acknowledgedPlanRevision
                f.io.arm(); let task = Task { try await f.state.saveProfileSettings(f.draft()) }; await f.io.waitUntilEntered()
                f.io.release(failing: true)
                if case .success = await task.result { throw DiagnosticFailure(message: "Failed durable transaction succeeded") }
                try diagnosticRequire(f.store.profiles[0].name == f.profile.name && f.state.isActive && f.state.acknowledgedPlanRevision == old, "Owned rollback or persist-before-publish failed")
            },
            test("PR16", "Settings captures latest volume rather than draft volume") { f in
                f.store.setOutputVolumeScalar(profileID: f.profile.id, scalar: 0.4)
                _ = try await f.save()
                let disk = try f.readStore()
                try diagnosticRequire(disk.profiles[0].outputVolumeScalar == 0.4, "Save restored stale draft volume")
            },
            volume("PR17", fail: false), volume("PR18", fail: true),
            unrelated("PR19", fail: false), unrelated("PR20", fail: true),
            test("PR21", "Competing settings and persisted same-profile edits are rejected") { f in
                f.io.arm(); let task = Task { try await f.save() }; await f.io.waitUntilEntered()
                var conflicting = f.profile; conflicting.name = "Conflicting"
                f.store.update(conflicting)
                do { _ = try await f.save(); throw DiagnosticFailure(message: "Competing Save was accepted") }
                catch ProfileSettingsError.busy { }
                try diagnosticRequire(f.store.profiles[0].name == f.profile.name, "Conflicting settings mutation leaked")
                f.io.release(); _ = try await task.value
            },
            supersession("PR22", stop: true, fail: false), supersession("PR23", stop: true, fail: true),
            supersession("PR24", stop: false, fail: false), supersession("PR25", stop: false, fail: true),
            test("PR26", "Configured creation publishes once after durable success") { f in
                f.store.profiles = []; try await f.store.flushPendingSave(); f.io.arm()
                let task = Task { try await f.store.insertConfiguredProfile(f.profile) }; await f.io.waitUntilEntered()
                try diagnosticRequire(f.store.profiles.isEmpty && f.store.physicalDeviceDefaults.isEmpty, "Creation published before durability")
                f.io.release(); let id = try await task.value
                try diagnosticRequire(f.store.profiles.count == 1 && f.store.selectedProfileID == id && f.store.automaticProfileID(forPhysicalDeviceUID: f.profile.outputDeviceUID) == id, "Creation publication/mapping incorrect")
            },
            test("PR27", "Failed creation publishes neither profile nor activation mapping") { f in
                f.store.profiles = []; f.store.selectedProfileID = nil; try await f.store.flushPendingSave(); f.io.arm()
                let task = Task { try await f.store.insertConfiguredProfile(f.profile) }; await f.io.waitUntilEntered(); f.io.release(failing: true)
                if case .success = await task.result { throw DiagnosticFailure(message: "Failed creation succeeded") }
                try diagnosticRequire(f.store.profiles.isEmpty && f.store.physicalDeviceDefaults.isEmpty && f.store.selectedProfileID == nil, "Failed creation appeared in library")
            },
            test("PR28", "Menu policy commits asynchronously before Stop and failure aborts it") { f in
                for fail in [true, false] {
                    f.store.setAutomaticProfile(physicalDevice: f.profile.outputDevice, profileID: f.profile.id)
                    try await f.store.flushPendingSave()
                    let active = f.store.profiles[0]
                    await f.state.activate(profile: active)
                    f.io.arm(); let task = Task { await f.state.deactivateProfileFromMenu(profileID: f.profile.id, physicalOutputConfirmed: true) }
                    await f.io.waitUntilEntered()
                    try diagnosticRequire(f.state.isActive && f.store.activationMode(for: f.store.profiles[0]) == .physicalOutput, "Policy/Stop published before durability")
                    f.io.release(failing: fail); await task.value
                    try diagnosticRequire(f.state.isActive == fail && f.store.activationMode(for: f.store.profiles[0]) == (fail ? .physicalOutput : .profileAudioDevice), "Policy failure or Stop ordering changed")
                }
            },
            test("PR29", "Terminal drain keeps accepted durable candidate and latest volume") { f in
                f.io.arm(); let task = Task { try await f.save() }; await f.io.waitUntilEntered()
                f.store.setOutputVolumeScalar(profileID: f.profile.id, scalar: 0.62)
                // Release from a non-MainActor executor: terminal drain must not
                // depend on the awaiting Save's MainActor continuation.
                let io = f.io
                DispatchQueue.global().async { io.release() }
                f.store.shutdownSynchronously()
                _ = try await task.value
                let writes = f.io.writes.count
                f.store.shutdownSynchronously()
                let disk = try f.readStore()
                try diagnosticRequire(f.io.writes.count == writes && disk.profiles[0].name == "Saved B" && disk.profiles[0].outputVolumeScalar == 0.62 && f.store.repository.status.lastCommittedRevision == disk.documentRevision, "Termination overwrote accepted candidate with old library")
            },
            test("PR30", "Future schema survives synchronous termination unchanged") { f in
                let url = f.box.directory.appendingPathComponent("protected.json"), bytes = Data(#"{"schemaVersion":999,"profiles":[]}"#.utf8)
                try bytes.write(to: url)
                let store = ProfileStore(storageURL: url, userDefaults: f.box.defaults)
                store.profiles = [f.profile]; store.shutdownSynchronously()
                let after = try Data(contentsOf: url)
                try diagnosticRequire(after == bytes && store.repository.status.protectedStorage, "Terminal flush bypassed protected storage")
            }
        ]
    }
}
