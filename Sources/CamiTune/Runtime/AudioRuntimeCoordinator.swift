import Foundation
import Combine

@MainActor
struct RuntimeCoordinatorCallbacks {
    let profiles: () -> [DeviceProfile]
    let automaticProfile: (String) -> DeviceProfile?
    let applyingDrafts: (DeviceProfile) throws -> DeviceProfile
    let settingsBusy: () -> Bool
    let retireOverlays: () -> Void
    let cancelStartup: () async -> Void
    let reportError: (Error) -> Void
    let reportMessage: (String) -> Void
    let currentError: () -> String?
    let clearError: () -> Void
}

/// Intent can change at any suspension. Only this owner executes transitions.
/// Once a backend change is acknowledged, finish its matching local effects
/// before reconciling the successor against that actual applied configuration.
@MainActor
final class AudioRuntimeCoordinator: ObservableObject {
    private let runtimeServices: AudioRuntimeServices
    private let perAppAudio: PerAppAudioController
    private let performanceRecorder: RuntimePerformanceRecorder
    private let callbacks: RuntimeCoordinatorCallbacks
    private var ownedSession: OwnedRuntimeSession?
    private var provisionalSession: ProvisionalRuntimeSession?
    private var activeTransaction: RuntimeSettingsTransaction?
    private var reconciliationWorker: Task<Void, Never>?
    private var executingGeneration: RuntimeIntentGeneration?
    private var generation: UInt64 = 0
    private var ownershipSequence: UInt64 = 0
    private var transactionSequence: UInt64 = 0
    private var transitionSequence: UInt64 = 0
    private var planGeneration: UInt64 = 0
    private var terminated = false
    private var status: AudioRuntimeStatusKind = .inactive
    private var transition: RuntimeTransitionSnapshot?
    private var suppressedAutoUID: String?
    private var manualStopBarrier: RuntimeIntentGeneration?
    private var automaticActivationRetry: AutomaticActivationRetryState?
    private var routingMonitorInFlight = false
    private var operations: [RuntimeIntentGeneration: PerformanceOperation] = [:]
    private var outcomes: [RuntimeIntentGeneration: RuntimeCommandResult] = [:]
    private struct EndpointRequest {
        let generation: RuntimeIntentGeneration
        let restoreProfile: DeviceProfile?
        let publish: Bool
        let hideBridge: Bool
        let continuation: CheckedContinuation<Void, Error>?
    }
    private var endpointRequests: [EndpointRequest] = []
    private var settledGeneration = RuntimeIntentGeneration(rawValue: 0)
    private var reconciliationOperations: [RuntimeIntentGeneration: PerformanceOperation] = [:]
    private var activeWorkerCount = 0
    private(set) var maximumWorkerCount = 0
    private(set) var desiredRuntime = DesiredRuntimeIntent(generation: .init(rawValue: 0),
        target: .inactive(restoreOutput: true), source: .stop(.manual), preparedPlan: nil,
        reportErrors: false, reason: "initial", parentOperation: nil)
    @Published private(set) var stateSnapshot = AudioRuntimeStateSnapshot.inactive
    @Published private(set) var coordinatorSummary = "Inactive"
    @Published private(set) var candidatePlanRevision: RuntimeIntentRevision?
    @Published private(set) var runtimePlanDiffSummary = "No runtime plan comparison has been made."
    @Published private(set) var actualGraphUpdateSummary = "No backend update observed."
    private(set) var lastRuntimePlanDelta: RuntimePlanDelta?
    var isActive: Bool { ownedSession != nil }
    var activeSession: AudioRuntimeSession? { ownedSession?.publicSession }
    var activeProfileID: UUID? { activeSession?.profileID }
    var activeVolumeMode: SystemVolumeMode? { ownedSession?.volumeMode }
    var transitionInProgress: Bool { transition != nil }
    var hasLiveApplyWork: Bool { reconciliationWorker != nil }
    var liveApplyRequestRevision: UInt64 { desiredRuntime.generation.rawValue }
    var acknowledgedPlanRevision: RuntimeIntentRevision? { ownedSession?.acknowledgedPlan?.revision }
    var runtimePlanSummary: String { ownedSession?.acknowledgedPlan?.summary ?? "No runtime plan has been acknowledged." }
    private var activeRuntimePlan: AudioRuntimePlan? { ownedSession?.appliedPlan }
    var activeSampleRate: Int? { ownedSession?.appliedPlan.sourceFormat.sampleRate }
    var activeRoutingUID: String? { ownedSession?.restoration.routingUID }
    var activePhysicalOutputUID: String? { ownedSession?.restoration.physicalOutputUID }
    var activeAudioRoute: ActiveAudioRoute? { ownedSession?.appliedPlan.route }
    var activatingProfileID: UUID? { provisionalSession?.owner.publicSession.profileID ?? (transition != nil ? desiredRuntime.profileID : nil) }
    var currentOwnershipID: RuntimeOwnershipID? { ownedSession?.ownershipID ?? provisionalSession?.owner.ownershipID }
    private var errorMessage: String? {
        get { callbacks.currentError() }
        set { if let newValue { callbacks.reportMessage(newValue) } }
    }
    init(services: AudioRuntimeServices, perAppAudio: PerAppAudioController,
         performanceRecorder: RuntimePerformanceRecorder, callbacks: RuntimeCoordinatorCallbacks) {
        runtimeServices = services; self.perAppAudio = perAppAudio
        self.performanceRecorder = performanceRecorder; self.callbacks = callbacks
    }
    private func publishSnapshot() {
        stateSnapshot = .init(status: transition == nil ? (isActive ? .active : .inactive) : status,
            session: activeSession, acknowledgedPlanRevision: acknowledgedPlanRevision,
            volumeMode: activeVolumeMode, transition: transition)
        let target: String
        switch desiredRuntime.target {
        case .inactive: target = "Inactive"
        case .active(let profile): target = "Active: " + profile.name
        }
        coordinatorSummary = [
            "Desired: \(target)", "Intent generation: \(desiredRuntime.generation.rawValue)",
            "Source: \(desiredRuntime.source.description)", "Actual: \(stateSnapshot.status.rawValue)",
            "Session: \(activeSession?.id.uuidString ?? "None")",
            "Ownership: \(currentOwnershipID.map { String($0.rawValue) } ?? "None")",
            "Applied plan: \(activeRuntimePlan.map { String($0.revision.generation) } ?? "None")",
            "Acknowledged plan: \(acknowledgedPlanRevision.map { String($0.generation) } ?? "None")",
            "Worker active: \(reconciliationWorker != nil ? "Yes" : "No")",
            "Transition: \(transition.map { "#\($0.id.rawValue) \($0.phase), generation \($0.generation.rawValue)" } ?? "None")",
            "Superseded: \(transition.map { $0.generation != desiredRuntime.generation } == true ? "Yes" : "No")",
            "Transaction: \(activeTransaction.map { String($0.id.rawValue) } ?? "None")",
            "Manual-stop suppression: \(suppressedAutoUID ?? "None")",
            "Manual-stop barrier: \(manualStopBarrier.map { String($0.rawValue) } ?? "None")",
            "Automatic retry: \(automaticActivationRetry.map { "Attempt \($0.failureCount), after \($0.retryAfter)" } ?? "None")"
        ].joined(separator: "\n")
    }
    private func phase(_ name: String, status: AudioRuntimeStatusKind) {
        self.status = status
        if let executingGeneration { reconciliationOperations[executingGeneration]?.mark(name) }
        transition = .init(id: transition?.id ?? .init(rawValue: transitionSequence),
            generation: executingGeneration ?? desiredRuntime.generation, phase: name)
        publishSnapshot()
    }
    private func checkCurrent(_ generation: RuntimeIntentGeneration) throws {
        guard !terminated, desiredRuntime.generation == generation else { throw CancellationError() }
    }
    func owns(_ id: RuntimeOwnershipID) -> Bool {
        !terminated && (ownedSession?.ownershipID == id || provisionalSession?.owner.ownershipID == id)
    }
    func reportVolumeMirrorFailure(ownershipID: RuntimeOwnershipID) {
        guard owns(ownershipID) else { return }
        callbacks.reportMessage("The output volume could not be synchronized. Playback is muted until a volume change succeeds. Check the output connection.")
    }
    func reportRuntimeFault(_ message: String, ownershipID: RuntimeOwnershipID) {
        guard owns(ownershipID) else { return }
        callbacks.reportMessage(message)
        submitStop(manual: false, restoreOutput: true, reason: .transportFailure)
    }
    func resetAutomaticPolicy(outputUID: String? = nil) {
        automaticActivationRetry = nil
        if let outputUID, suppressedAutoUID == outputUID { suppressedAutoUID = nil }
        publishSnapshot()
    }
    func preferPhysicalOutputRestoration(_ fallback: String) {
        ownedSession?.restoration.previousDefaultUID = activePhysicalOutputUID ?? fallback
    }
    func restoreRenderConfiguration() { if let plan = activeRuntimePlan { applyRenderer(plan) } }
    func handleDefaultOutputChange(_ uid: String?) {
        if let suppressedAutoUID, let uid, uid != suppressedAutoUID,
           !ProfileRoutingDescriptor.isProfileRoutingUID(uid) { self.suppressedAutoUID = nil }
        guard isActive, !transitionInProgress else { publishSnapshot(); return }
        if uid == activeRoutingUID { runtimeServices.resumeVolume() }
        else { runtimeServices.silenceVolume(); callbacks.retireOverlays() }
    }
    private func submit(target: DesiredRuntimeIntent.Target, source: RuntimeIntentSource,
                        preparedPlan: AudioRuntimePlan? = nil, reportErrors: Bool = true,
                        reason: String, parent: PerformanceOperationID? = nil,
                        operation: PerformanceOperation? = nil) -> RuntimeIntentGeneration {
        if let transaction = activeTransaction, transaction.receipt != nil {
            transaction.rollbackContinuation?.resume(returning: .superseded)
            transaction.rollbackContinuation = nil
            activeTransaction = nil
        }
        let old = desiredRuntime.generation
        if executingGeneration != old {
            operations.removeValue(forKey: old)?.finish("coalesced")
            reconciliationOperations.removeValue(forKey: old)?.finish("coalesced")
        }
        generation &+= 1
        let next = RuntimeIntentGeneration(rawValue: generation)
        desiredRuntime = .init(generation: next, target: target, source: source, preparedPlan: preparedPlan,
            reportErrors: reportErrors, reason: reason, parentOperation: parent)
        if let operation { operations[next] = operation; operation.mark("intent received") }
        reconciliationOperations[next] = performanceRecorder.begin("Runtime reconciliation", reason: reason,
            revision: next.rawValue, parent: operation?.id ?? parent)
        reconciliationOperations[next]?.mark("intent received")
        publishSnapshot()
        ensureWorker()
        return next
    }
    private func ensureWorker() {
        guard !terminated, reconciliationWorker == nil else { return }
        reconciliationWorker = Task { @MainActor [weak self] in await self?.reconcileLoop() }
    }
    func activate(plan: AudioRuntimePlan, reportErrors: Bool = true,
                  performanceReason: String? = nil, parentOperation: PerformanceOperationID? = nil) async {
        await activate(profile: plan.intent, reportErrors: reportErrors,
            performanceReason: performanceReason, parentOperation: parentOperation, preparedPlan: plan)
    }
    func activate(profile: DeviceProfile, reportErrors: Bool = true, automatic: Bool = false,
                  performanceReason: String? = nil,
                  parentOperation: PerformanceOperationID? = nil, preparedPlan: AudioRuntimePlan? = nil) async {
        guard !terminated else { return }
        if automatic {
            guard activeTransaction == nil, !callbacks.settingsBusy(), let current = runtimeServices.defaultOutput() else { return }
            if suppressedAutoUID == current || suppressedAutoUID == profile.outputDeviceUID { return }
            if automaticActivationRetry?.defersActivation(for: current) == true { return }
        } else { suppressedAutoUID = nil; automaticActivationRetry = nil }
        _ = submit(target: .active(profile), source: automatic ? .automaticRouting : .manualActivation,
            preparedPlan: preparedPlan, reportErrors: reportErrors,
            reason: performanceReason ?? (automatic ? "automaticRouting" : "user"), parent: parentOperation)
        await reconciliationWorker?.value
    }
    func apply(profile: DeviceProfile, performanceOperation: PerformanceOperation? = nil) async {
        guard !terminated, isActive, activeProfileID == profile.id else { performanceOperation?.finish("inactive"); return }
        // AppState defers editor drafts during Save. Direct callers cannot
        // replace the durable transaction with a slider intent either.
        guard activeTransaction == nil else { performanceOperation?.finish("deferred by Save"); return }
        guard case .active(let desiredProfile) = desiredRuntime.target, desiredProfile.id == profile.id else {
            performanceOperation?.finish("superseded by lifecycle intent"); return
        }
        _ = submit(target: .active(profile), source: .liveEdit, reason: "liveApply",
            operation: performanceOperation ?? performanceRecorder.begin("Live EQ apply"))
        await reconciliationWorker?.value
    }
    @discardableResult
    private func submitStop(manual: Bool, restoreOutput: Bool, reason: RuntimeStopReason,
                            parent: PerformanceOperationID? = nil, operation: PerformanceOperation? = nil,
                            performanceReason: String? = nil) -> RuntimeIntentGeneration {
        if manual {
            if case .active(let profile) = desiredRuntime.target {
                suppressedAutoUID = activePhysicalOutputUID ?? provisionalSession?.owner.restoration.physicalOutputUID ?? profile.outputDeviceUID
            } else { suppressedAutoUID = activePhysicalOutputUID ?? runtimeServices.defaultOutput() }
            automaticActivationRetry = nil
        }
        let submitted = submit(target: .inactive(restoreOutput: restoreOutput), source: .stop(reason),
            reason: performanceReason ?? reason.rawValue, parent: parent, operation: operation)
        if manual { manualStopBarrier = submitted }
        publishSnapshot()
        return submitted
    }
    func deactivate(manual: Bool = true, restoreOutput: Bool = true,
                    performanceReason: String = "user", parentOperation: PerformanceOperationID? = nil,
                    performanceOperation: PerformanceOperation? = nil) async {
        guard !terminated else { return }
        let alreadyWorking = reconciliationWorker != nil
        let reason: RuntimeStopReason
        switch performanceReason {
        case "transportFailure": reason = .transportFailure
        case "sampleRateChanged": reason = .sampleRateMismatch
        case "deviceDisappeared": reason = .physicalOutputMissing
        case "dependencyRepair": reason = .dependencyRepair
        default: reason = manual ? .manual : (restoreOutput ? .profileDisabled : .externalRouteChange)
        }
        _ = submitStop(manual: manual, restoreOutput: restoreOutput, reason: reason,
            parent: parentOperation, operation: performanceOperation, performanceReason: performanceReason)
        // A Stop submitted while an exchange is suspended takes effect as intent
        // immediately. The owner completes/cleans that exchange, then retires.
        if !alreadyWorking { await reconciliationWorker?.value }
    }
    func waitUntilSettled() async { await reconciliationWorker?.value }
    func requestStartupPresentation(publishProfiles: Bool) {
        guard !terminated, ownedSession == nil, provisionalSession == nil, reconciliationWorker == nil else { return }
        endpointRequests.append(.init(generation: desiredRuntime.generation, restoreProfile: nil,
            publish: publishProfiles, hideBridge: true, continuation: nil))
        ensureWorker()
    }
    func synchronizeProfileEndpoints(restoringDisabledProfile profile: DeviceProfile? = nil) async throws {
        guard !terminated, activeTransaction == nil, endpointRequests.count < 64 else { throw ProfileSettingsError.busy }
        try await withCheckedThrowingContinuation { continuation in
            endpointRequests.append(.init(generation: desiredRuntime.generation, restoreProfile: profile,
                publish: true, hideBridge: false, continuation: continuation))
            ensureWorker()
        }
    }
    private func executeEndpointRequest(_ request: EndpointRequest) async {
        do {
            try checkCurrent(request.generation)
            executingGeneration = request.generation
            transitionSequence &+= 1
            transition = .init(id: .init(rawValue: transitionSequence), generation: request.generation, phase: "Endpoint presentation")
            phase("Updating endpoint presentation", status: .applying)
            if let profile = request.restoreProfile,
               runtimeServices.defaultOutput() == ProfileRoutingDescriptor.uid(for: profile.id) {
                guard ownedSession == nil, provisionalSession == nil else { throw ProfileSettingsError.busy }
                try await runtimeServices.setDefaultOutput(profile.outputDeviceUID)
                try checkCurrent(request.generation)
            }
            if request.hideBridge { try await runtimeServices.hideBridge(); try checkCurrent(request.generation) }
            if request.publish { try await runtimeServices.synchronizeRouting(callbacks.profiles(), activeProfileID, [], [:]) }
            request.continuation?.resume()
        } catch { request.continuation?.resume(throwing: error) }
        transition = nil; publishSnapshot()
    }

    private func reconcileLoop() async {
        activeWorkerCount += 1; maximumWorkerCount = max(maximumWorkerCount, activeWorkerCount)
        defer {
            activeWorkerCount -= 1; reconciliationWorker = nil; executingGeneration = nil
            if activeTransaction?.receipt == nil { transition = nil }
            publishSnapshot()
        }
        while !terminated {
            if !endpointRequests.isEmpty {
                let request = endpointRequests.removeFirst()
                await executeEndpointRequest(request)
                continue
            }
            if desiredRuntime.generation == settledGeneration, activeTransaction?.rollbackRequested != true { break }
            let intent = desiredRuntime
            defer {
                let result: String
                if desiredRuntime.generation != intent.generation { result = "superseded" }
                else if case .failed = outcomes[intent.generation] { result = "failed" }
                else { result = "success" }
                reconciliationOperations.removeValue(forKey: intent.generation)?.finish(result)
            }
            executingGeneration = intent.generation
            transitionSequence &+= 1
            transition = .init(id: .init(rawValue: transitionSequence), generation: intent.generation, phase: "Worker pickup")
            operations[intent.generation]?.mark("reconciliation started")
            reconciliationOperations[intent.generation]?.mark("worker pickup")
            if let transaction = activeTransaction, transaction.generation == intent.generation {
                if transaction.rollbackRequested { await executeTransactionRollback(transaction) }
                else if transaction.receipt == nil { await executeSettings(transaction) }
                // Runtime effects wait for the facade's durable commit/rollback.
                settledGeneration = intent.generation
                if desiredRuntime.generation == intent.generation && endpointRequests.isEmpty { break }
                continue
            }
            do {
                if case .active = intent.target, let barrier = manualStopBarrier {
                    // A newer activation may replace desired inactive, but must
                    // still cross the explicit Stop's resource-retirement barrier.
                    if ownedSession != nil {
                        await executeDeactivation(restoreOutput: true, reason: "manualStopBarrier", parent: intent.parentOperation)
                    }
                    if manualStopBarrier == barrier { manualStopBarrier = nil }
                    try checkCurrent(intent.generation)
                }
                switch intent.target {
                case .inactive(let restore):
                    await executeDeactivation(restoreOutput: restore, reason: intent.reason, parent: intent.parentOperation)
                    if let barrier = manualStopBarrier, barrier <= intent.generation { manualStopBarrier = nil }
                case .active(let profile):
                    guard profile.isEnabled else { throw AppState.AppError.profileDisabled(profile.name) }
                    if let owner = ownedSession, owner.publicSession.profileID == profile.id {
                        try await executeRuntimeUpdate(profile: profile, intent: intent)
                    } else {
                        try await executeActivation(profile: profile, intent: intent)
                    }
                }
                outcomes[intent.generation] = desiredRuntime.generation == intent.generation ? .satisfied : .superseded
            } catch {
                outcomes[intent.generation] = error is CancellationError ? .superseded : .failed(error.localizedDescription)
                if desiredRuntime.generation == intent.generation, !(error is CancellationError) {
                    if intent.reportErrors || shouldAlwaysReport(error) { callbacks.reportError(error) }
                    if case .automaticRouting = intent.source, case .active(let profile) = intent.target,
                       suppressedAutoUID == nil {
                        automaticActivationRetry = .recordingFailure(for: profile.outputDeviceUID, previous: automaticActivationRetry)
                    }
                }
            }
            operations.removeValue(forKey: intent.generation)?.finish(outcomes[intent.generation] == .satisfied ? "success" : "superseded or failed")
            // Bound diagnostic results; desired state is not an operation log.
            if outcomes.count > 16 { outcomes = outcomes.filter { $0.key.rawValue + 16 >= generation } }
            transition = nil; publishSnapshot(); runtimeServices.transitionFinished(isActive)
            settledGeneration = intent.generation
            if desiredRuntime.generation == intent.generation && endpointRequests.isEmpty { break }
        }
    }
    func prepareRuntimePlan(profile: DeviceProfile, reason: String = "validation", parentOperation: PerformanceOperationID? = nil) async throws -> AudioRuntimePlan {
        planGeneration &+= 1
        let revision = RuntimeIntentRevision(profileID: profile.id, generation: planGeneration)
        let operation = performanceRecorder.begin("Plan preparation", reason: reason, revision: revision.generation, parent: parentOperation)
        operation?.mark("intent snapshot")
        do {
            let plan = try await AudioRuntimePlanPreparer().prepare(profile: profile, revision: revision,
                services: runtimeServices, phase: { operation?.mark($0) })
            operation?.mark("validation complete")
            if let executingGeneration { reconciliationOperations[executingGeneration]?.mark("candidate prepared") }
            if revision.generation >= (candidatePlanRevision?.generation ?? 0) { candidatePlanRevision = revision }
            operation?.finish("success")
            return plan
        } catch { operation?.finish("failed"); throw error }
    }

    /// Configuration/control path only; never called by a PCM or transport worker.
    @discardableResult
    func compareRuntimePlans(from old: AudioRuntimePlan, to candidate: AudioRuntimePlan,
                             reason: String, parentOperation: PerformanceOperationID? = nil) -> RuntimePlanDelta {
        let operation = performanceRecorder.begin("Plan diff", reason: reason,
            revision: candidate.revision.generation, parent: parentOperation)
        let delta = RuntimePlanDiffer().delta(from: old, to: candidate)
        operation?.mark("classification: " + delta.disruptionLevel.description + "; graph: " + delta.graph.description)
        operation?.finish("success")
        if let executingGeneration { reconciliationOperations[executingGeneration]?.mark("candidate diffed") }
        lastRuntimePlanDelta = delta
        runtimePlanDiffSummary = delta.summary
        actualGraphUpdateSummary = "No backend update for this comparison."
        return delta
    }

    func inspectRuntimePlanDiff() async {
        guard !transitionInProgress, !callbacks.settingsBusy(), reconciliationWorker == nil, let old = activeRuntimePlan,
              let profile = callbacks.profiles().first(where: { $0.id == old.revision.profileID }) else { return }
        do {
            let candidate = try await prepareRuntimePlan(profile: callbacks.applyingDrafts(profile), reason: "diffInspection")
            guard activeRuntimePlan?.revision == old.revision else { return }
            compareRuntimePlans(from: old, to: candidate, reason: "diagnostics")
        } catch { runtimePlanDiffSummary = "Candidate preparation failed: \(error.localizedDescription)" }
    }

    private func applyPlanGraph(_ plan: AudioRuntimePlan, operation: PerformanceOperation? = nil) async throws {
        try await runtimeServices.applyGraph(plan.processingGraph)
        operation?.mark("backend acknowledged")
        let kind = runtimeServices.graphUpdateDescription() ?? "Acknowledged (backend kind not reported)"
        actualGraphUpdateSummary = "\(kind), applied revision \(plan.revision.generation)"
        operation?.mark("backend update: " + actualGraphUpdateSummary)
    }

    private func publishPlanEndpoint(_ plan: AudioRuntimePlan) async throws {
        try await runtimeServices.synchronizeRouting(
            callbacks.profiles().map { $0.id == plan.revision.profileID ? plan.intent : $0 }, activeProfileID, [],
            [plan.revision.profileID: plan.profileRoutingDescriptor])
    }

    private func acknowledge(_ plan: AudioRuntimePlan) {
        ownedSession?.appliedPlan = plan
        ownedSession?.acknowledgedPlan = plan
        publishSnapshot()
    }

    private func applyRenderer(_ plan: AudioRuntimePlan) {
        runtimeServices.applyRenderConfiguration(plan.renderConfiguration)
        perAppAudio.setPlaybackContext(plan.playbackContext)
    }


    private func executeActivation(profile: DeviceProfile, intent: DesiredRuntimeIntent,
                                   plan supplied: AudioRuntimePlan? = nil, acknowledgeOnSuccess: Bool = true) async throws {
        let switching = isActive && activeProfileID != profile.id
        let switchOperation = switching ? performanceRecorder.begin("Profile switch", reason: "profileSwitch", parent: intent.parentOperation) : nil
        let operation = performanceRecorder.begin("Activation", reason: intent.reason, parent: switchOperation?.id ?? intent.parentOperation)
        var result = "failed"
        defer { operation?.finish(result); switchOperation?.finish(result) }
        phase("Preparing", status: .preparing)
        await callbacks.cancelStartup(); try checkCurrent(intent.generation)
        guard profile.isEnabled else { throw AppState.AppError.profileDisabled(profile.name) }
        await runtimeServices.refreshDependencies(); try checkCurrent(intent.generation)
        operation?.mark("dependencies checked")
        guard runtimeServices.engineAvailable() else { throw AppState.AppError.missingCamillaDSP }
        let supported = await runtimeServices.presentationSupported(); try checkCurrent(intent.generation)
        guard supported else { throw AppState.AppError.outdatedRoutingDriver }
        guard runtimeServices.bridgeLayout() != nil else { throw AppState.AppError.unsupportedRoutingLayout }
        let plan: AudioRuntimePlan
        if let supplied = supplied ?? intent.preparedPlan { plan = supplied }
        else { plan = try await prepareRuntimePlan(profile: profile, reason: "activation", parentOperation: operation?.id) }
        try checkCurrent(intent.generation)
        try await AudioRuntimePlanPreparer().validateCurrent(plan, services: runtimeServices); try checkCurrent(intent.generation)
        guard let output = await runtimeServices.resolveOutput(plan.hardwareEvidence.output.uid) else {
            throw AppState.AppError.outputMissing(plan.hardwareEvidence.output.name)
        }
        try checkCurrent(intent.generation); operation?.mark("hardware/profile evidence")
        if let old = ownedSession {
            let delta = compareRuntimePlans(from: old.appliedPlan, to: plan, reason: "activation", parentOperation: operation?.id)
            if old.publicSession.profileID == profile.id && delta.isNoOp { result = "success"; return }
            await executeDeactivation(restoreOutput: true, reason: switching ? "profileSwitch" : "runtimeRestart", parent: operation?.id)
            try checkCurrent(intent.generation)
        }
        ownershipSequence &+= 1
        let currentDefault = runtimeServices.defaultOutput()
        let previous = currentDefault.flatMap { ProfileRoutingDescriptor.isProfileRoutingUID($0) || $0 == AudioDeviceInfo.systemAudioBridgeUID ? nil : $0 }
        let owner = OwnedRuntimeSession(id: .init(rawValue: ownershipSequence), plan: plan, previousDefaultUID: previous)
        provisionalSession = .init(generation: intent.generation, owner: owner)
        let routingProfiles = callbacks.profiles().map { $0.id == profile.id ? plan.intent : $0 }
        func current() throws { try checkCurrent(intent.generation); guard owns(owner.ownershipID) else { throw CancellationError() } }
        do {
            phase("Acquiring route", status: .activating)
            try await runtimeServices.synchronizeRouting(routingProfiles, nil, [profile.id], [profile.id: plan.profileRoutingDescriptor]); try current()
            operation?.mark("routing endpoints synchronized")
            let routingValue = await runtimeServices.waitForRouting(profile.id); try current()
            guard let routing = routingValue else { throw AppState.AppError.profileRoutingDeviceMissing(profile.name) }
            let bridgeValue = await runtimeServices.freshBridge(); try current()
            guard let bridge = bridgeValue else { throw AppState.AppError.missingRoutingDriver }
            try await AudioRuntimePlanPreparer().validateCurrent(plan, services: runtimeServices); try current()
            try await runtimeServices.hideBridge(); try current()
            operation?.mark("routing endpoint available")
            let sampleRate = Double(plan.sourceFormat.sampleRate)
            try await runtimeServices.setRate(output.id, sampleRate); try current()
            try await runtimeServices.setRate(bridge.id, sampleRate); try current()
            operation?.mark("sample rates configured")
            phase("Starting engine", status: .activating)
            try await acquire(.engine, owner: owner) { try await runtimeServices.startEngine() }; try current()
            operation?.mark("Camilla process ready")
            runtimeServices.resetEngine()
            let outputs = try await runtimeServices.playbackDevices(); try current()
            guard outputs.contains(plan.hardwareEvidence.output.uid) else { throw AppState.AppError.camillaDSPCoreAudioUIDUnsupported }
            operation?.mark("playback UID verified")
            phase("Applying backend", status: .activating)
            try await applyPlanGraph(plan, operation: operation); try current()
            operation?.mark("graph acknowledged")
            owner.resources.insert(.observations); runtimeServices.startObservations(owner.publicSession)
            try await acquire(.volume, owner: owner) {
                owner.masterControl = try await runtimeServices.startVolume(routing, output, profile.id)
                owner.volumeSession = runtimeServices.currentVolumeSession()
                owner.volumeMode = runtimeServices.volumeMode()
            }; try current()
            operation?.mark("volume session ready")
            phase("Starting PCM", status: .activating)
            try await acquire(.pcm, owner: owner) { try await runtimeServices.startPCM(plan, owner.publicSession) }; try current()
            operation?.mark("PCM writer ready")
            perAppAudio.setPlaybackContext(plan.playbackContext)
            phase("Starting transport", status: .activating)
            var transportError: Error?
            var connected = false
            for attempt in 0..<3 {
                let fresh = await runtimeServices.freshBridge(); try current()
                guard let fresh, let master = owner.masterControl else { throw AppState.AppError.missingRoutingDriver }
                do {
                    try await acquire(.transport, owner: owner) { try await runtimeServices.startTransport(fresh, routing, sampleRate, master) }
                    try current(); connected = true; break
                } catch {
                    try current(); transportError = error
                    if attempt < 2 { try await runtimeServices.sleep(.milliseconds(100)); try current() }
                }
            }
            guard connected else { throw transportError ?? AppState.AppError.missingRoutingDriver }
            operation?.mark("transport connected")
            try await runtimeServices.prepareVolume(); try current()
            operation?.mark("volume handoff ready")
            phase("Switching output", status: .activating)
            if runtimeServices.defaultOutput() != routing.id {
                owner.restoration.defaultOutputWasRedirected = true
                try await runtimeServices.setDefaultOutput(routing.id); try current()
            }
            operation?.mark("default output switched")
            try await acquire(.spectrum, owner: owner) { await runtimeServices.startSpectrum(owner.publicSession) }; try current()
            try? await runtimeServices.synchronizeRouting(routingProfiles, profile.id, [], [profile.id: plan.profileRoutingDescriptor]); try current()
            operation?.mark("post-activation routing sync")
            try await AudioRuntimePlanPreparer().validateCurrent(plan, services: runtimeServices); try current()
            let nominal = await runtimeServices.nominalRate(output.id); try current()
            if let nominal, abs(nominal - sampleRate) >= 0.5 {
                throw AppState.AppError.runtimeSampleRateMismatch(expected: plan.sourceFormat.sampleRate, actual: nominal, device: output.name)
            }
            guard runtimeServices.defaultOutput() == routing.id else { throw CancellationError() }
            if let failure = runtimeServices.transportError() { throw ProfileSettingsError.runtime(failure) }
            // Promotion is synchronous: no suspended provisional attempt can
            // publish an active session after a newer Stop or activation intent.
            owner.acknowledgedPlan = acknowledgeOnSuccess ? plan : nil
            ownedSession = owner; provisionalSession = nil
            phase("Session acknowledged", status: .active)
            operation?.mark(acknowledgeOnSuccess ? "active runtime acknowledged" : "runtime ready for settings commit")
            automaticActivationRetry = nil; suppressedAutoUID = nil
            callbacks.clearError(); runtimeServices.notifyActivation(); result = "success"
        } catch {
            operation?.mark("cleanup started")
            let restore: Bool
            if case .inactive(let requestedRestore) = desiredRuntime.target { restore = requestedRestore }
            else { restore = !owner.restoration.defaultOutputWasRedirected || runtimeServices.defaultOutput() == owner.restoration.routingUID }
            await retire(owner, restoreOutput: restore, operation: operation)
            operation?.mark("cleanup complete")
            if provisionalSession?.owner.ownershipID == owner.ownershipID { provisionalSession = nil }
            if !terminated {
                try? await runtimeServices.hideBridge()
                try? await runtimeServices.synchronizeRouting(callbacks.profiles(), nil, [], [:])
            }
            publishSnapshot()
            if error is CancellationError { result = "superseded"; operation?.mark("superseded detected") }
            throw error
        }
    }
    private func acquire(_ resource: RuntimeResourceOwnership, owner: OwnedRuntimeSession,
                         _ action: () async throws -> Void) async throws {
        owner.resources.insert(resource)
        // Synchronous shutdown can retire the in-flight lease. Reassert it on
        // return so late acquisition is cleaned even by a cancellation-ignorant service.
        defer { owner.resources.insert(resource) }
        try await action()
    }
    private func executeRuntimeUpdate(profile: DeviceProfile, intent: DesiredRuntimeIntent) async throws {
        let operation = operations[intent.generation]
        operation?.mark("worker begins request")
        UIRenderPerformance.beginEQApply(); defer { UIRenderPerformance.endEQApply() }
        phase("Preparing live update", status: .preparing)
        let reason: String
        if case .liveEdit = intent.source { reason = "liveApply" } else { reason = "runtimeUpdate" }
        let candidate: AudioRuntimePlan
        if let prepared = intent.preparedPlan {
            candidate = prepared
            try await AudioRuntimePlanPreparer().validateCurrent(prepared, services: runtimeServices)
        } else { candidate = try await prepareRuntimePlan(profile: profile, reason: reason, parentOperation: operation?.id) }
        operation?.mark("graph prepared"); try checkCurrent(intent.generation)
        guard let owner = ownedSession else { throw CancellationError() }
        let old = owner.appliedPlan
        let delta = compareRuntimePlans(from: old, to: candidate, reason: reason, parentOperation: operation?.id)
        if delta.isNoOp { return }
        if delta.requirements.requiresFullRuntimeRestart || delta.requirements.requiresTransportRestart || delta.requirements.requiresPCMRestart {
            try await replacePipeline(candidate, intent: intent, reason: "liveApplyRestart"); return
        }
        if delta.requirements.requiresEngineQuiescence {
            try await applyWithEngineQuiescence(candidate, intent: intent); return
        }
        try await AudioRuntimePlanPreparer().validateCurrent(candidate, services: runtimeServices); try checkCurrent(intent.generation)
        phase("Applying in place", status: .applying)
        var graphApplied = false, rendererApplied = false, endpointAttempted = false
        do {
            if delta.requirements.requiresGraphUpdate { try await applyPlanGraph(candidate, operation: operation); graphApplied = true }
            guard owns(owner.ownershipID) else { throw CancellationError() }
            // Supersession after RPC submission cannot split graph and renderer.
            if delta.requirements.requiresRenderConfigurationUpdate { applyRenderer(candidate); rendererApplied = true }
            if delta.requirements.requiresEndpointMetadataUpdate { endpointAttempted = true; try await publishPlanEndpoint(candidate) }
            guard owns(owner.ownershipID) else { throw CancellationError() }
            acknowledge(candidate); callbacks.clearError(); operation?.mark("local runtime committed")
        } catch {
            guard owns(owner.ownershipID) else { throw error }
            do {
                if graphApplied { try await applyPlanGraph(old, operation: operation) }
                guard owns(owner.ownershipID) else { throw CancellationError() }
                if rendererApplied { applyRenderer(old) }
                if endpointAttempted { try await publishPlanEndpoint(old) }
                guard owns(owner.ownershipID) else { throw CancellationError() }
                acknowledge(old)
            } catch {
                await executeDeactivation(restoreOutput: true, reason: "liveApplyRollbackFailure", parent: operation?.id)
                throw error
            }
            throw error
        }
    }
    private func replacePipeline(_ plan: AudioRuntimePlan, intent: DesiredRuntimeIntent, reason: String,
                                 acknowledgeOnSuccess: Bool = true) async throws {
        await executeDeactivation(restoreOutput: true, reason: reason, parent: intent.parentOperation)
        try checkCurrent(intent.generation)
        try await executeActivation(profile: plan.intent, intent: intent, plan: plan, acknowledgeOnSuccess: acknowledgeOnSuccess)
    }
    private func applyWithEngineQuiescence(_ plan: AudioRuntimePlan, intent: DesiredRuntimeIntent,
                                          acknowledgeOnSuccess: Bool = true) async throws {
        phase("Engine quiescence (conservative stop/start)", status: .applying)
        try await replacePipeline(plan, intent: intent, reason: "engineQuiescence", acknowledgeOnSuccess: acknowledgeOnSuccess)
    }
    private func executeDeactivation(restoreOutput: Bool, reason: String, parent: PerformanceOperationID?) async {
        let operation = performanceRecorder.begin("Deactivation", reason: reason, parent: parent)
        phase("Retiring", status: .stopping)
        if let owner = ownedSession {
            await retire(owner, restoreOutput: restoreOutput, operation: operation)
        }
        guard !terminated else { operation?.finish("terminated"); return }
        operation?.mark("physical output restoration complete")
        try? await runtimeServices.sleep(.milliseconds(150))
        guard !terminated else { operation?.finish("terminated"); return }
        operation?.mark("intentional post-stop delay")
        try? await runtimeServices.hideBridge()
        var cleanupError: Error?
        for attempt in 0..<10 where !terminated {
            do { try await runtimeServices.synchronizeRouting(callbacks.profiles(), nil, [], [:]); cleanupError = nil; break }
            catch { cleanupError = error; if attempt < 9 { try? await runtimeServices.sleep(.milliseconds(75)) } }
        }
        if let cleanupError { callbacks.reportMessage("EQ stopped, but its macOS audio device could not be updated: \(cleanupError.localizedDescription)") }
        ownedSession = nil
        operation?.mark("routing cleanup complete"); operation?.mark("inactive acknowledged")
        operation?.finish(cleanupError == nil ? "success" : "stopped with cleanup error")
        if !terminated { runtimeServices.notifyDeactivation() }
        publishSnapshot()
    }
    private func retire(_ owner: OwnedRuntimeSession, restoreOutput: Bool, operation: PerformanceOperation?) async {
        guard currentOwnershipID == owner.ownershipID else { return }
        if terminated { retireSynchronously(owner); return }
        if owner.resources.contains(.volume) { await runtimeServices.beginHandoff() }
        guard owns(owner.ownershipID) else { return }
        operation?.mark("volume handoff prepared")
        callbacks.retireOverlays(); perAppAudio.setPlaybackContext(nil)
        if owner.resources.remove(.observations) != nil { runtimeServices.stopObservations() }
        if owner.resources.contains(.transport) { await runtimeServices.stopTransport(); owner.resources.remove(.transport) }
        guard owns(owner.ownershipID) else { return }
        operation?.mark("transport stopped")
        await perAppAudio.resetRuntimeWithoutBlockingUI()
        guard owns(owner.ownershipID) else { return }
        operation?.mark("per-app runtime reset")
        if owner.resources.contains(.pcm) { await runtimeServices.stopPCM(); owner.resources.remove(.pcm) }
        guard owns(owner.ownershipID) else { return }
        operation?.mark("PCM writer stopped")
        if owner.resources.contains(.engine) { await runtimeServices.closeEngineInput() }
        guard owns(owner.ownershipID) else { return }
        operation?.mark("Camilla input closed")
        if owner.resources.contains(.spectrum) { await runtimeServices.stopSpectrum(); owner.resources.remove(.spectrum) }
        guard owns(owner.ownershipID) else { return }
        if owner.resources.contains(.engine) { await runtimeServices.stopEngine(); owner.resources.remove(.engine); runtimeServices.resetEngine() }
        guard owns(owner.ownershipID) else { return }
        operation?.mark("engine stopped")
        if owner.resources.contains(.volume) { await runtimeServices.stopVolume(); owner.resources.remove(.volume) }
        guard owns(owner.ownershipID) else { return }
        owner.volumeSession = nil; owner.masterControl = nil
        operation?.mark("volume bridge stopped")
        if restoreOutput {
            let restore = owner.restoration.previousDefaultUID.flatMap { runtimeServices.cachedDevice($0) != nil ? $0 : nil }
                ?? owner.restoration.physicalOutputUID
            do { try await runtimeServices.setDefaultOutput(restore) }
            catch { callbacks.reportMessage("EQ stopped, but macOS could not switch back to the physical output: \(error.localizedDescription)") }
        }
    }

    func applySettingsCandidate(original: DeviceProfile, newRuntime: DeviceProfile,
                                operation: PerformanceOperation?,
                                validatePersistence: @escaping () throws -> Void) async throws -> RuntimeApplyReceipt {
        guard !terminated, activeTransaction == nil, reconciliationWorker == nil else { throw ProfileSettingsError.busy }
        transactionSequence &+= 1
        let id = RuntimeTransactionID(rawValue: transactionSequence)
        let target: DesiredRuntimeIntent.Target = activeProfileID == original.id ? .active(newRuntime) : desiredRuntime.target
        let next = submit(target: target, source: .settingsTransaction(id), reason: "settingsTransaction", parent: operation?.id)
        let transaction = RuntimeSettingsTransaction(id: id, generation: next, original: original, intent: newRuntime,
            owner: ownedSession, operation: operation, validatePersistence: validatePersistence)
        activeTransaction = transaction
        return try await withCheckedThrowingContinuation { transaction.applyContinuation = $0 }
    }
    func validate(_ receipt: RuntimeApplyReceipt) throws {
        guard let transaction = activeTransaction, receiptIsCurrent(receipt, transaction: transaction) else {
            throw ProfileSettingsError.cancelled
        }
    }
    func commit(_ receipt: RuntimeApplyReceipt) throws {
        guard let transaction = activeTransaction, receiptIsCurrent(receipt, transaction: transaction) else {
            throw ProfileSettingsError.cancelled
        }
        if transaction.wasActive, transaction.delta?.isNoOp == false, let candidate = transaction.candidate { acknowledge(candidate) }
        activeTransaction = nil; transition = nil; publishSnapshot()
    }
    @discardableResult
    func rollback(_ receipt: RuntimeApplyReceipt) async throws -> RuntimeCommandResult {
        guard let transaction = activeTransaction, receiptIsCurrent(receipt, transaction: transaction) else { return .superseded }
        transaction.rollbackRequested = true
        return try await withCheckedThrowingContinuation {
            transaction.rollbackContinuation = $0; ensureWorker()
        }
    }
    private func receiptIsCurrent(_ receipt: RuntimeApplyReceipt, transaction: RuntimeSettingsTransaction) -> Bool {
        !terminated && transaction.id == receipt.transactionID && transaction.receipt == receipt
            && desiredRuntime.generation == receipt.intentGeneration
            && currentOwnershipID == receipt.ownershipID && activeSession?.id == receipt.sessionID
    }
    private func transactionIsCurrent(_ transaction: RuntimeSettingsTransaction) throws {
        try checkCurrent(transaction.generation)
        guard activeTransaction?.id == transaction.id else { throw CancellationError() }
        try transaction.validatePersistence()
    }
    private func executeSettings(_ transaction: RuntimeSettingsTransaction) async {
        let operation = transaction.operation
        phase("Preparing settings transaction", status: .preparing)
        do {
            try transactionIsCurrent(transaction)
            let candidate: AudioRuntimePlan
            if transaction.wasActive {
                candidate = try await prepareRuntimePlan(profile: transaction.intent, reason: "settingsTransaction", parentOperation: operation?.id)
                guard let old = transaction.oldPlan else { throw ProfileSettingsError.runtime("Previous runtime plan unavailable") }
                transaction.delta = compareRuntimePlans(from: old, to: candidate, reason: "settingsTransaction", parentOperation: operation?.id)
            } else {
                planGeneration &+= 1
                let revision = RuntimeIntentRevision(profileID: transaction.intent.id, generation: planGeneration)
                let profile = transaction.intent
                candidate = try await Task.detached(priority: .userInitiated) {
                    try AudioRuntimePlanPreparer.prepareForStorage(profile: profile, revision: revision)
                }.value
            }
            transaction.candidate = candidate
            try transactionIsCurrent(transaction); operation?.mark("runtime preparation complete")
            phase("Applying settings transaction", status: .applying)
            if let delta = transaction.delta, !delta.isNoOp {
                let effects = delta.requirements
                if effects.requiresFullRuntimeRestart || effects.requiresTransportRestart || effects.requiresPCMRestart {
                    transaction.restarted = true
                    try await replacePipeline(candidate, intent: desiredRuntime, reason: "settingsTransaction", acknowledgeOnSuccess: false)
                } else if effects.requiresEngineQuiescence {
                    transaction.restarted = true
                    try await applyWithEngineQuiescence(candidate, intent: desiredRuntime, acknowledgeOnSuccess: false)
                } else {
                    try await AudioRuntimePlanPreparer().validateCurrent(candidate, services: runtimeServices)
                    try transactionIsCurrent(transaction)
                    if effects.requiresGraphUpdate {
                        transaction.graphAttempted = true
                        try await applyPlanGraph(candidate, operation: operation)
                    }
                    guard !terminated, ownedSession?.ownershipID == transaction.baseOwnershipID else { throw CancellationError() }
                    if effects.requiresRenderConfigurationUpdate { applyRenderer(candidate); transaction.rendererApplied = true }
                }
            }
            let publish = transaction.delta?.requirements.requiresEndpointMetadataUpdate
                ?? (ProfileRoutingDescriptor.descriptors(for: [transaction.original])[transaction.original.id] != candidate.profileRoutingDescriptor)
            if publish { transaction.endpointAttempted = true; try await publishPlanEndpoint(candidate) }
            if transaction.wasActive, transaction.delta?.isNoOp == false, let owner = ownedSession, !terminated {
                owner.appliedPlan = candidate // Tentative actual state; public acknowledgement waits for persistence.
            }
            try transactionIsCurrent(transaction)
            operation?.mark("runtime update complete")
            let receipt = RuntimeApplyReceipt(transactionID: transaction.id, intentGeneration: transaction.generation,
                sessionID: activeSession?.id, ownershipID: currentOwnershipID,
                oldPlanRevision: transaction.oldPlan?.revision, candidatePlanRevision: candidate.revision)
            transaction.receipt = receipt
            phase("Awaiting settings persistence", status: .applying)
            transaction.applyContinuation?.resume(returning: receipt); transaction.applyContinuation = nil
        } catch {
            var failure: Error = error
            if !terminated, desiredRuntime.generation == transaction.generation {
                do { try await restoreTransaction(transaction) }
                catch { failure = ProfileSettingsError.rollback(failure.localizedDescription, error.localizedDescription) }
            }
            if activeTransaction?.id == transaction.id { activeTransaction = nil }
            transaction.applyContinuation?.resume(throwing: failure); transaction.applyContinuation = nil
        }
    }
    private func executeTransactionRollback(_ transaction: RuntimeSettingsTransaction) async {
        do {
            try checkCurrent(transaction.generation)
            try await restoreTransaction(transaction)
            transaction.rollbackContinuation?.resume(returning: .satisfied)
        } catch {
            if error is CancellationError { transaction.rollbackContinuation?.resume(returning: .superseded) }
            else { transaction.rollbackContinuation?.resume(throwing: error) }
        }
        transaction.rollbackContinuation = nil
        if activeTransaction?.id == transaction.id { activeTransaction = nil }
    }
    private func restoreTransaction(_ transaction: RuntimeSettingsTransaction) async throws {
        try checkCurrent(transaction.generation)
        phase("Rolling back settings", status: .recovering)
        transaction.operation?.mark("rollback begins")
        do {
            if let old = transaction.oldPlan {
                if transaction.restarted {
                    await executeDeactivation(restoreOutput: true, reason: "settingsRollback", parent: transaction.operation?.id)
                    try checkCurrent(transaction.generation)
                    try await executeActivation(profile: old.intent, intent: desiredRuntime, plan: old)
                    ownedSession?.restoration.previousDefaultUID = transaction.previousDefaultUID
                } else if transaction.graphAttempted || transaction.rendererApplied {
                    guard ownedSession?.ownershipID == transaction.baseOwnershipID else { throw CancellationError() }
                    try await AudioRuntimePlanPreparer().validateCurrent(old, services: runtimeServices)
                    try checkCurrent(transaction.generation)
                    if transaction.graphAttempted { try await applyPlanGraph(old, operation: transaction.operation) }
                    // A rollback RPC also has a coherence obligation before a
                    // newer desired intent can retire/switch this owned runtime.
                    guard !terminated, ownedSession?.ownershipID == transaction.baseOwnershipID else { throw CancellationError() }
                    if transaction.rendererApplied { applyRenderer(old) }
                    ownedSession?.appliedPlan = old
                }
            }
            if transaction.endpointAttempted {
                try await runtimeServices.synchronizeRouting(callbacks.profiles(), activeProfileID, [],
                    transaction.oldPlan.map { [$0.revision.profileID: $0.profileRoutingDescriptor] } ?? [:])
            }
            try checkCurrent(transaction.generation)
            if let old = transaction.oldPlan { acknowledge(old) }
            let target: DesiredRuntimeIntent.Target = transaction.wasActive
                ? transaction.oldPlan.map { .active($0.intent) } ?? .inactive(restoreOutput: true) : desiredRuntime.target
            desiredRuntime = .init(generation: transaction.generation, target: target, source: .recovery,
                preparedPlan: nil, reportErrors: true, reason: "settingsRollback", parentOperation: nil)
        } catch {
            if desiredRuntime.generation == transaction.generation, !terminated, transaction.wasActive {
                await executeDeactivation(restoreOutput: true, reason: "settingsRollbackFailure", parent: transaction.operation?.id)
            }
            throw error
        }
    }

    func shutdownSynchronously() {
        guard !terminated else { return }
        generation &+= 1
        desiredRuntime = .init(generation: .init(rawValue: generation), target: .inactive(restoreOutput: true),
            source: .stop(.applicationTermination), preparedPlan: nil, reportErrors: false,
            reason: "applicationTermination", parentOperation: nil)
        terminated = true; reconciliationWorker?.cancel()
        for request in endpointRequests { request.continuation?.resume(throwing: CancellationError()) }
        endpointRequests.removeAll()
        callbacks.retireOverlays()
        if let owner = ownedSession ?? provisionalSession?.owner { retireSynchronously(owner) }
        ownedSession = nil
        // Retain the provisional identity until an outstanding acquisition
        // returns; its late resources are retired under that same identity.
        activeTransaction?.applyContinuation?.resume(throwing: CancellationError())
        activeTransaction?.applyContinuation = nil
        activeTransaction?.rollbackContinuation?.resume(returning: .superseded)
        activeTransaction?.rollbackContinuation = nil; activeTransaction = nil
        transition = nil; publishSnapshot()
    }
    private func retireSynchronously(_ owner: OwnedRuntimeSession) {
        guard currentOwnershipID == owner.ownershipID else { return }
        let sync = runtimeServices.synchronous
        callbacks.retireOverlays(); perAppAudio.setPlaybackContext(nil)
        if owner.resources.remove(.observations) != nil { runtimeServices.stopObservations() }
        if owner.resources.remove(.transport) != nil { sync.stopTransport() }
        perAppAudio.resetRuntime()
        if owner.resources.remove(.pcm) != nil { sync.stopPCM() }
        if owner.resources.contains(.engine) { sync.closeEngineInput() }
        if owner.resources.remove(.spectrum) != nil { sync.stopSpectrum() }
        if owner.resources.remove(.engine) != nil { sync.stopEngine(); runtimeServices.resetEngine() }
        if owner.resources.remove(.volume) != nil { sync.stopVolume() }
        owner.masterControl = nil; owner.volumeSession = nil
        if runtimeServices.defaultOutput() == owner.restoration.routingUID {
            try? sync.setDefaultOutput(owner.restoration.previousDefaultUID ?? owner.restoration.physicalOutputUID)
        }
        try? sync.hideBridge()
    }
    func monitorRouting() async {
        guard !callbacks.settingsBusy(), !transitionInProgress, !routingMonitorInFlight else { return }
        routingMonitorInFlight = true
        defer { routingMonitorInFlight = false }
        let observationGeneration = desiredRuntime.generation
        let observationOwner = currentOwnershipID
        if isActive {
            if let runtimeError = runtimeServices.transportError() {
                errorMessage = runtimeError
                await deactivate(manual: false, performanceReason: "transportFailure")
                return
            }
            guard let activeProfileID,
                  let activeProfile = callbacks.profiles().first(where: { $0.id == activeProfileID }) else {
                await deactivate(manual: false, restoreOutput: false)
                return
            }
            if let activePhysicalOutputUID,
               activeProfile.outputDeviceUID != activePhysicalOutputUID {
                do {
                    let updated = try callbacks.applyingDrafts(activeProfile)
                    await activate(profile: updated, automatic: true)
                } catch {
                    callbacks.reportError(error)
                    await deactivate(manual: false, performanceReason: "automaticRouting")
                }
                return
            }
            if let activeSampleRate,
               let outputUID = activePhysicalOutputUID,
               let actualRate = await runtimeServices.nominalRate(outputUID),
               abs(actualRate - Double(activeSampleRate)) >= 0.5 {
                guard desiredRuntime.generation == observationGeneration, currentOwnershipID == observationOwner else { return }
                errorMessage = AppState.AppError.runtimeSampleRateMismatch(
                    expected: activeSampleRate,
                    actual: actualRate,
                    device: activeProfile.outputDeviceName
                ).localizedDescription
                await deactivate(manual: false, performanceReason: "sampleRateChanged")
                return
            }
            guard desiredRuntime.generation == observationGeneration, currentOwnershipID == observationOwner else { return }
            if !activeProfile.isEnabled {
                await deactivate(manual: false, performanceReason: "automaticRouting")
                return
            }
            if let outputUID = activePhysicalOutputUID,
               runtimeServices.hasSnapshot(),
               runtimeServices.cachedDevice(outputUID) == nil {
                await deactivate(manual: false, restoreOutput: false, performanceReason: "deviceDisappeared")
                return
            }
            guard let activeRoutingUID else {
                await deactivate(manual: false, restoreOutput: false)
                return
            }

            // If the user picks another macOS output while EQ is active, respect it.
            if runtimeServices.defaultOutput() != activeRoutingUID {
                await deactivate(manual: false, restoreOutput: false)
                return
            }

            return
        }

        guard let current = runtimeServices.defaultOutput() else { return }
        if let suppressedAutoUID {
            if current == suppressedAutoUID { return }
            self.suppressedAutoUID = nil
        }
        if let automaticActivationRetry {
            if automaticActivationRetry.outputUID != current {
                self.automaticActivationRetry = nil
            } else if automaticActivationRetry.defersActivation(for: current) {
                return
            }
        }

        // CoreAudio can temporarily keep a removed device's UID as the default
        // after it is unplugged. Never auto-activate from that stale UID: doing
        // so retries a missing route every monitor tick.
        if let currentDevice = runtimeServices.cachedDevice(current),
           !currentDevice.isRoutingDevice,
           let profile = callbacks.automaticProfile(current) {
            await activate(profile: profile, reportErrors: false, automatic: true)
            return
        }

        if let selectedProfileID = ProfileRoutingDescriptor.profileID(from: current),
           let selectedProfile = callbacks.profiles().first(where: {
                   $0.id == selectedProfileID
                   && $0.isEnabled
                   && $0.autoActivateWhenProfileDeviceSelected
                   && runtimeServices.cachedDevice($0.outputDeviceUID) != nil
           }) {
            await activate(profile: selectedProfile, reportErrors: false, automatic: true)
        }
    }

    private func shouldAlwaysReport(_ error: Error) -> Bool {
        if let appError = error as? AppState.AppError {
            switch appError {
            case .profileRoutingDeviceMissing, .unsupportedSampleRate,
                    .camillaDSPCoreAudioUIDUnsupported:
                return true
            default:
                break
            }
        }
        if let audioError = error as? CoreAudioManager.AudioError {
            switch audioError {
            case .sampleRateNotSettable, .sampleRateDidNotApply,
                    .defaultOutputDidNotApply:
                return true
            default:
                break
            }
        }
        return false
    }

}
