import CamiTuneAudio
import CamiTuneDomain
import Combine
import Foundation

@MainActor
final class RoomCorrectionEditorState: ObservableObject {
    enum Tab: String, CaseIterable { case measure, analysis, correction }
    private static var defaultSource: RoomMeasurementSource {
        var source = RoomMeasurementSource()
        source.kind = .recorder
        return source
    }
    @Published var tab: Tab = .measure
    @Published var source = RoomCorrectionEditorState.defaultSource {
        didSet {
            if let session, source.kind == session.source.kind, source != session.source {
                calculatedResult = nil
            }
        }
    }
    @Published var settings = RoomCorrectionSettings() {
        didSet {
            if settings.lowHz != oldValue.lowHz || settings.highHz != oldValue.highHz { refreshSimpleRecordingQuality() }
        }
    }
    @Published var microphones: [MeasurementMicrophone] = []
    @Published var positionIndex = 0
    @Published var recorderPositionCount: RoomRecorderPositionCount = .five
    @Published var microphonePositionCount: RoomRecorderPositionCount = .nine
    @Published private(set) var microphoneLevel: MicrophoneInputLevel?
    private enum Activity { case idle, working, levelCheck, measurement, recordingImport, correction }
    @Published private var activity: Activity = .idle
    var busy: Bool { activity != .idle }
    var testingSound: Bool { activity == .levelCheck }
    var measuring: Bool { activity == .measurement }
    var importingRecording: Bool { activity == .recordingImport }
    var correctionInProgress: Bool { activity == .correction }
    @Published private(set) var playingOutput: PhysicalOutputID?
    @Published private(set) var profileIsActive = false
    @Published private(set) var measurementOpen = false
    private var runtimeObservation: AnyCancellable?
    private var levelCheckCeilingDB: Double?
    @Published private(set) var testVolumeDB = RoomMeasurementSignal.defaultVolumeDB
    @Published private(set) var testVolumeMaximumDB = RoomMeasurementSignal.volumeRangeDB.upperBound
    var testVolumeRangeDB: ClosedRange<Double> { min(RoomMeasurementSignal.volumeRangeDB.lowerBound, testVolumeMaximumDB)...testVolumeMaximumDB }
    func setTestVolumeDB(_ value: Double) {
        guard (!busy || testingSound), value.isFinite else { return }
        testVolumeDB = min(testVolumeMaximumDB, max(testVolumeRangeDB.lowerBound, value))
        if testingSound, let context, let ceiling = levelCheckCeilingDB {
            app?.setLevelCheckGain(context: context, gain: Float(pow(10, (testVolumeDB - ceiling) / 20)))
        }
    }
    @Published var status = ""
    @Published var error: String?
    var comparing: Bool { comparisonPlayback != nil }
    @Published private(set) var revision = 0
    @Published private(set) var calculatedResult: RoomCorrectionResult?
    @Published private(set) var isVerifying = false
    @Published private(set) var verificationMessage = ""
    private var verificationBaseline: RoomMeasurementSession?
    private var verificationCorrection: RoomCorrectionResult?
    @Published private(set) var calculationRevision = 0
    @Published private(set) var importRevision = 0
    private var importedContext: RoomMeasurementContext?
    private var importedMeasurementContext: RoomMeasurementContext?
    var session: RoomMeasurementSession? { didSet { refreshSimpleRecordingQuality() } }
    @Published private(set) var simpleRecordingQuality: RoomSimpleRecordingQuality?
    var comparison: RoomMeasurementSession?
    private var task: Task<Void, Never>?
    private var savingSessionSetup = false
    private var capture: SpatialMicrophoneCapture?
    private var context: SpatialCalibrationContext?
    private var loadedProfile: UUID?
    private var loadedSeatID: UUID?
    private weak var app: AppState?
    private var profileID: UUID?
    private var drafts: [RoomMeasurementSource.Kind: RoomMeasurementSession] = [:]
    private var measurementChannels: [Int] = []
    private var issuedTokens: Set<UInt32> = []
    private let playbackClockID = UUID()
    private let measurementStore: RoomMeasurementStore
    init(measurementStore: RoomMeasurementStore = .init()) { self.measurementStore = measurementStore }
    var hasMicrophoneCaptures: Bool {
        session?.source.kind == .microphone && (session?.blocks.isEmpty == false || session?.recordings.isEmpty == false)
    }
    var microphoneIsConfigured: Bool {
        source.deviceID != nil && source.calibration.map { (try? $0.validateForRoomMeasurement()) != nil } == true
    }
    var canCalculate: Bool {
        hasMeasurements && !busy && !isVerifying && simpleRecordingQuality?.canCalculate != false
            && (source.kind != .microphone || session?.microphoneMeasurementsComplete == true)
    }
    private func refreshSimpleRecordingQuality() {
        let updated = session.flatMap { RoomSimpleRecordingQuality.assess($0, settings: settings) }
        if updated != simpleRecordingQuality { simpleRecordingQuality = updated }
    }
    var microphoneActionTitle: String {
        if measuring { return "Cancel" }
        guard let session, let position else { return "Measure Position" }
        return session.microphonePositionIsComplete(position) ? "Measure Again" : "Measure Position"
    }
    func setMicrophone(_ id: String?) {
        guard !busy, !isVerifying, !hasMicrophoneCaptures, source.deviceID != id else { return }
        source.deviceID = id; source.deviceName = microphones.first { $0.id == id }?.name ?? "Unknown / not listed"
        source.calibration = nil; calculatedResult = nil
    }
    func setCalibration(_ calibration: MicrophoneCalibrationCurve) {
        guard !busy, !isVerifying, source.kind == .microphone else { return }
        source.calibration = calibration
        if session != nil { reanalyze() }
    }
    func refreshMicrophones() {
        run { [self] in microphones = try await worker { SpatialMicrophoneCapture.microphones } }
    }
    func setMicrophonePositionCount(_ count: RoomRecorderPositionCount, profile: DeviceProfile) {
        guard !busy, !isVerifying, !hasMicrophoneCaptures, microphonePositionCount != count else { return }
        microphonePositionCount = count
        if session?.source.kind == .microphone { beginSession(profile: profile) }
    }
    var recorderPlaybackComplete: Bool {
        guard let session, session.source.kind == .recorder, !session.positions.isEmpty else { return false }
        return session.positions.allSatisfy { hasPlayed($0, in: session) }
    }
    var recorderActionTitle: String {
        if measuring || importingRecording { return "Cancel" }
        if recorderPlaybackComplete { return "Import Recording…" }
        if let position, let session, hasPlayed(position, in: session) { return "Play Again" }
        return session?.blocks.isEmpty == false ? "Next" : "Play Sound"
    }
    func hasPlayed(_ position: RoomMeasurementPosition, in session: RoomMeasurementSession) -> Bool {
        !measurementChannels.isEmpty && measurementChannels.allSatisfy { channel in
            let blocks = session.blocks.filter { $0.positionID == position.id && $0.channel == channel }
            return blocks.contains { !$0.isRepeat } && (!(position.isMain || session.requiresRepeatedPositions == true) || blocks.contains { $0.isRepeat })
        }
    }
    func selectPosition(_ index: Int) {
        guard !busy, session?.positions.indices.contains(index) == true else { return }
        positionIndex = index; status = restoredMeasurementStatus; error = nil
    }
    func setSourceKind(_ kind: RoomMeasurementSource.Kind, profile: DeviceProfile) {
        guard !busy, !isVerifying, source.kind != kind else { return }
        calculatedResult = nil
        let started = session != nil
        if let session {
            drafts[session.source.kind] = session
        }
        source = drafts[kind]?.source ?? .init()
        source.kind = kind
        if kind == .microphone, source.deviceID == nil { source.deviceID = microphones.first?.id }
        guard started else { return }
        if let draft = drafts[kind], draft.context == (try? profile.roomMeasurementContext()) {
            session = draft
            positionIndex = kind == .recorder ? (draft.positions.indices.first { !hasPlayed(draft.positions[$0], in: draft) } ?? 0) : 0
            status = restoredMeasurementStatus; error = nil
            if kind == .recorder { recorderPositionCount = RoomRecorderPositionCount(rawValue: draft.positions.count) ?? .five }
            else { microphonePositionCount = RoomRecorderPositionCount(rawValue: draft.positions.count) ?? .nine }
            revision += 1
            persistSession()
        } else { beginSession(profile: profile) }
    }
    func setRecorderPositionCount(_ count: RoomRecorderPositionCount, profile: DeviceProfile) {
        guard !busy, session?.recordings.isEmpty != false, recorderPositionCount != count else { return }
        recorderPositionCount = count
        guard var session, session.source.kind == .recorder else { return }
        calculatedResult = nil
        let wasRecorded = !session.blocks.isEmpty || !session.recordings.isEmpty
        let selectedID = position?.id
        let points = RoomMeasurementGeometry.recorderPositions(center: session.context.listener,
            radius: RoomMeasurementGeometry.radius(for: profile.effectiveSpatialSettings.seating), count: count)
        session.positions = points.enumerated().map { index, point in
            session.positions.first { $0.coordinate == point } ?? .init(coordinate: point, isMain: index == 0)
        }
        let ids = Set(session.positions.map(\.id))
        session.blocks.removeAll { !ids.contains($0.positionID) }
        self.session = session
        positionIndex = session.positions.firstIndex { $0.id == selectedID } ?? 0
        if hasPlayed(session.positions[positionIndex], in: session),
           let next = session.positions.indices.first(where: { !hasPlayed(session.positions[$0], in: session) }) { positionIndex = next }
        status = restoredMeasurementStatus; error = nil; revision += 1
        if wasRecorded { persistSession() }
    }
    /// Each attempt gets fresh acoustic IDs, including attempts cancelled before completion.
    func plannedBlocks(selectedChannel: Int?) -> [RoomMeasurementBlock] {
        guard let session, let position else { return [] }
        issuedTokens.formUnion(session.blocks.map(\.token))
        return measurementChannels.filter { session.source.kind == .recorder || selectedChannel == nil || $0 == selectedChannel }
            .flatMap { channel in
                (0..<((position.isMain || session.requiresRepeatedPositions == true) ? 2 : 1)).map { repeatIndex in
                    var token: UInt32
                    repeat { token = UInt32.random(in: 1...UInt32.max) } while issuedTokens.contains(token)
                    issuedTokens.insert(token)
                    var block = RoomMeasurementBlock(token: token, positionID: position.id, channel: channel, isRepeat: repeatIndex == 1)
                    if session.context.topology.endpoints.first(where: { $0.id.channelIndex == channel })?.isSubwooferLike == true {
                        block.markerChannel = session.context.topology.endpoints.filter {
                            !$0.isSubwooferLike && $0.connectionState != .disabledByUser
                        }.map { $0.id.channelIndex }.min()
                    }
                    block.playbackGainDB = RoomMeasurementSignal.playbackGainDB(forVolumeDB: testVolumeDB)
                    return block
                }
            }
    }
    /// Publish only a complete phone position. Cancelled/older takes are absent from import's marker list.
    func completedRecorderPosition(_ blocks: [RoomMeasurementBlock], in initial: RoomMeasurementSession) throws -> RoomMeasurementSession {
        guard let id = blocks.first?.positionID, blocks.allSatisfy({ $0.positionID == id }),
              let index = initial.positions.firstIndex(where: { $0.id == id }) else { throw RoomCorrectionError.invalidSession }
        var result = initial
        result.blocks.removeAll { $0.positionID == id }
        result.blocks.append(contentsOf: blocks)
        guard hasPlayed(result.positions[index], in: result) else { throw RoomCorrectionError.missingBlocks }
        result.positions[index].observations = []
        result.positions[index].skipped = false
        return result
    }
    func advanceAfterPlayback() {
        guard let session else { return }
        if session.source.kind == .recorder {
            positionIndex = session.positions.indices.first { $0 > positionIndex && !hasPlayed(session.positions[$0], in: session) }
                ?? session.positions.indices.first { !hasPlayed(session.positions[$0], in: session) } ?? positionIndex
            status = recorderPlaybackComplete ? "Stop the phone recording, then import that one audio file."
                : "Keep recording. Move the phone to the blue marker, then press Next."
        } else {
            // A one-speaker retry must not advance while another speaker (or
            // the main position's quieter repeat) is still missing.
            if let position, session.microphonePositionIsComplete(position) {
                positionIndex = session.positions.indices.first {
                    $0 > positionIndex && !session.positions[$0].skipped && !session.microphonePositionIsComplete(session.positions[$0])
                } ?? session.positions.indices.first {
                    !session.positions[$0].skipped && !session.microphonePositionIsComplete(session.positions[$0])
                } ?? positionIndex
            }
            status = validationMessage
        }
    }
    var position: RoomMeasurementPosition? { session?.positions.indices.contains(positionIndex) == true ? session?.positions[positionIndex] : nil }
    var hasMeasurements: Bool { (session?.usablePositionCount ?? 0) > 0 }
    private var restoredMeasurementStatus: String {
        guard let session else { return "" }
        if !session.recordings.isEmpty || hasMeasurements { return validationMessage }
        guard session.source.kind == .recorder, !session.blocks.isEmpty else { return "" }
        return recorderPlaybackComplete ? "Stop the phone recording, then import that one audio file."
            : "Keep recording. Move the phone to the blue marker, then press Next."
    }
    var validationMessage: String {
        guard let session else { return "" }
        if session.source.kind == .microphone {
            if session.microphoneMeasurementsComplete { return "Measurements ready" }
            return "\(session.completeMicrophonePositionCount) of \(session.positions.filter { !$0.skipped }.count) positions complete. Measure every speaker at each position; at least 3 positions including the main position are needed."
        }
        for (i, position) in session.positions.enumerated() where !position.skipped {
            let expected = Set(session.blocks.filter { $0.positionID == position.id }.map(\.channel))
            if !expected.isEmpty && !expected.isSubset(of: Set(position.observations.filter(\.hasUsableMagnitude).map(\.channel))) {
                let missing = expected.subtracting(position.observations.filter(\.hasUsableMagnitude).map(\.channel)).sorted()
                let names = missing.map { channel in
                    session.context.topology.endpoints.first { $0.id.channelIndex == channel }?.displayName ?? "Channel \(channel + 1)"
                }.joined(separator: ", ")
                let missingSweep = session.analysisIssues?.contains { $0.positionID == position.id && missing.contains($0.channel) && $0.missingSweep } == true
                return "Position \(i + 1) · \(names): \(missingSweep ? "no complete sweep was found in this recording" : "too little repeatable signal above the noise")."
            }
        }
        return hasMeasurements ? "Measurements ready" : ""
    }
    private func run(_ activity: Activity = .working, _ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        self.activity = activity; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.activity = .idle
                self.playingOutput = nil
                self.savingSessionSetup = false
                self.levelCheckCeilingDB = nil; self.task = nil; self.revision += 1
                self.measurementOpen = self.profileIsActive && self.session != nil
            }
            do { try Task.checkCancellation(); try await action() } catch is CancellationError { self.status = "" }
            catch { self.status = ""; if !Task.isCancelled { self.error = error.localizedDescription } }
            if Task.isCancelled {
                self.status = ""
                await self.restartCancelledRecorderMeasurement()
            }
        }
    }
    private func restartCancelledRecorderMeasurement() async {
        guard measuring, var session, session.source.kind == .recorder else { return }
        let hadProgress = !session.blocks.isEmpty || !session.recordings.isEmpty || hasMeasurements
        session.blocks = []; session.recordings = []; session.analysisIssues = nil
        for index in session.positions.indices {
            session.positions[index].observations = []
            session.positions[index].skipped = false
        }
        self.session = session
        positionIndex = 0; calculatedResult = nil
        let restarted = session, store = measurementStore
        do {
            // Finish after any in-flight save. Cleanup must survive cancellation,
            // so reopening cannot reuse markers from the abandoned phone recording.
            try await Task.detached {
                let manifest = store.folder(restarted.id).appendingPathComponent("session.plist")
                guard hadProgress || FileManager.default.fileExists(atPath: manifest.path) else { return }
                try store.save(restarted)
            }.value
        } catch { self.error = error.localizedDescription }
    }
    private func worker<T: Sendable>(committing: Bool = false, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        // Once a manifest is committed, publish that exact result to the editor
        // even if Cancel arrived during the atomic write. The worker checks
        // cancellation before committing; discarding its return would split UI
        // and saved state until the next launch.
        if !committing { try Task.checkCancellation() }
        return value
    }
    func selectSeat(profile: DeviceProfile, app: AppState) {
        guard loadedSeatID != profile.effectiveSpatialSettings.seating?.id else { return }
        let previous = task
        previous?.cancel()
        Task { [weak self] in
            await previous?.value
            guard let self, let latest = app.profiles.profiles.first(where: { $0.id == profile.id }),
                  latest.effectiveSpatialSettings.seating?.id == profile.effectiveSpatialSettings.seating?.id else { return }
            self.loadedProfile = nil; self.session = nil; self.comparison = nil
            self.source = Self.defaultSource; self.drafts = [:]; self.positionIndex = 0; self.status = ""
            self.load(profile: latest, app: app)
        }
    }
    private func validateCommit(_ candidate: DeviceProfile, app: AppState) async throws {
        let latest = app.profiles.profiles.first(where: { $0.id == candidate.id })
        guard !Task.isCancelled, latest?.effectiveSpatialSettings.seating?.id == candidate.effectiveSpatialSettings.seating?.id else {
            if let latest, app.activeProfileID == latest.id { await app.apply(profile: latest) }
            throw CancellationError()
        }
    }
    private func publishRoomProfile(_ profile: DeviceProfile, app: AppState) {
        var updated = profile
        if let latest = app.profiles.profiles.first(where: { $0.id == profile.id }) {
            updated.outputVolumeScalar = latest.outputVolumeScalar
        }
        app.profiles.update(updated)
    }
    func load(profile: DeviceProfile, app: AppState) {
        guard loadedProfile != profile.id else { return }
        isVerifying = false; verificationBaseline = nil; verificationCorrection = nil; verificationMessage = ""
        self.app = app; profileID = profile.id; loadedProfile = profile.id
        measurementOpen = false
        runtimeObservation = app.runtimeSnapshots.sink { [weak self] snapshot in
                guard let self else { return }
                self.clearComparisonForRuntimeChange()
                let active = snapshot.session?.profileID == profile.id
                guard self.profileIsActive != active else { return }
                self.profileIsActive = active
                // Applying the measurement baseline may briefly restart the
                // route. The operation validates its owner after that apply.
                if active { self.measurementOpen = self.session != nil }
                else if !self.busy { self.pauseMeasurement() }
            }
        measurementChannels = profile.configuredProcessingChannels.map(\.index)
        let seat = profile.effectiveSpatialSettings.seating
        loadedSeatID = seat?.id
        tab = seat?.roomCorrectionResult != nil || seat?.roomCorrectionBands.isEmpty == false ? .correction : .measure
        settings = profile.effectiveSpatialSettings.seating?.roomCorrectionSettings ?? .init()
        if settings.method == .hybrid { settings.method = .iir }
        calculatedResult = seat?.roomCorrectionResult
        importedContext = nil; importedMeasurementContext = nil
        if let result = calculatedResult, seat?.roomCorrectionEnabled == false,
           let plan = try? RoomCorrectionImportPlan(result: result, profile: profile),
           plan.matches(profile: profile) {
            importedContext = try? profile.roomMeasurementContext()
            importedMeasurementContext = result.context
        }
        let id = profile.effectiveSpatialSettings.seating?.roomCorrectionSessionID
        run { [self] in
            let store = measurementStore
            let loaded = try await worker { () -> (RoomMeasurementSession?, [MeasurementMicrophone]) in
                (try id.map { try store.load($0) }, SpatialMicrophoneCapture.microphones)
            }
            microphones = loaded.1; session = loaded.0
            if let session {
                source = session.source
                if source.kind == .recorder {
                    positionIndex = session.positions.indices.first { !hasPlayed(session.positions[$0], in: session) } ?? 0
                } else {
                    positionIndex = session.positions.indices.first {
                        !session.positions[$0].skipped && !session.microphonePositionIsComplete(session.positions[$0])
                    } ?? 0
                }
                recorderPositionCount = RoomRecorderPositionCount(rawValue: session.positions.count) ?? .five
                microphonePositionCount = RoomRecorderPositionCount(rawValue: session.positions.count) ?? .nine
                status = restoredMeasurementStatus
            }
            else { source = Self.defaultSource; source.deviceID = microphones.first?.id }
            if let previous = session, !previous.recordings.isEmpty,
               previous.measurementAnalysisVersion < RoomRecordingAnalyzer.currentAnalysisVersion {
                status = "Updating recording analysis…"
                session = try await worker(committing: true) { try store.updatingSource(previous.source, in: previous) }
                calculatedResult = nil
                status = validationMessage
            }
        }
    }
    var measurementActionTitle: String { session == nil ? "Start Measurement" : "Continue Measurement" }
    func openMeasurement(profile: DeviceProfile) {
        guard !busy, let app, app.isActive, app.activeProfileID == profile.id else { return }
        error = nil
        if session == nil {
            beginSession(profile: profile)
            guard session != nil else { return }
            // Retain a newly started setup even before its first recording, so
            // navigating to another profile can resume the same session.
            persistSession(preservingSetupOnClose: true)
        }
        measurementOpen = true
    }
    func pauseMeasurement() {
        let wasOpen = measurementOpen
        // Navigation stops playback, but only deactivation closes the setup.
        // Loading a saved session also restores it while its profile is active.
        measurementOpen = profileIsActive && session != nil
        if measuring || testingSound { cancel() }
        else if wasOpen && !busy { persistSession(preservingSetupOnClose: true) }
    }
    func beginSession(profile: DeviceProfile) {
        guard !busy, !isVerifying else { return }
        do {
            if source.kind == .microphone, let microphone = microphones.first(where: { $0.id == source.deviceID }) { source.deviceName = microphone.name }
            let context = try profile.roomMeasurementContext()
            if session != nil { comparison = session }
            let center = context.listener, radius = RoomMeasurementGeometry.radius(for: profile.effectiveSpatialSettings.seating)
            var positions: [RoomMeasurementPosition]
            if source.kind == .recorder {
                positions = RoomMeasurementGeometry.recorderPositions(center: center, radius: radius, count: recorderPositionCount)
                    .enumerated().map { .init(coordinate: $0.element, isMain: $0.offset == 0) }
            } else {
                positions = [.init(coordinate: center, isMain: true)]
                for _ in 1..<microphonePositionCount.rawValue { positions.append(.init(coordinate: RoomMeasurementGeometry.suggestion(center: center, radius: radius, existing: positions.map(\.coordinate)))) }
            }
            measurementChannels = profile.configuredProcessingChannels.map(\.index)
            error = nil
            if source.kind == .recorder { source.calibration = nil }
            session = .init(context: context, source: source, positions: positions)
            session?.requiresRepeatedPositions = true
            calculatedResult = nil; importedContext = nil; importedMeasurementContext = nil
            positionIndex = 0; tab = .measure; status = ""; revision += 1
        } catch { self.error = error.localizedDescription }
    }
    func movePosition(_ coordinate: SpatialVector3, profile: DeviceProfile) {
        guard !busy, !isVerifying, var session, session.source.kind == .microphone,
              session.positions.indices.contains(positionIndex), !session.positions[positionIndex].isMain else { return }
        guard [coordinate.x, coordinate.y, coordinate.z].allSatisfy({ $0.isFinite && abs($0) < 20 }),
              session.positions[positionIndex].coordinate != coordinate else { return }
        guard !session.positions.contains(where: { $0.id != session.positions[positionIndex].id
            && pow($0.coordinate.x - coordinate.x, 2) + pow($0.coordinate.y - coordinate.y, 2) + pow($0.coordinate.z - coordinate.z, 2) < 0.01 }) else {
            error = "Keep measurement positions at least 10 cm apart. Spread them over the listening area."; return
        }
        calculatedResult = nil
        let movedID = session.positions[positionIndex].id
        session.retireMicrophoneTakes(positionID: movedID, channels: Set(measurementChannels))
        session.positions[positionIndex].coordinate = coordinate
        session.positions[positionIndex].observations = []
        self.session = session; status = restoredMeasurementStatus; error = nil; revision += 1
    }
    func addPosition(profile: DeviceProfile) {
        guard !busy, !isVerifying, var session, session.source.kind == .microphone, session.positions.count < 32 else { return }
        calculatedResult = nil
        session.positions.append(.init(coordinate: RoomMeasurementGeometry.suggestion(center: session.context.listener,
            radius: RoomMeasurementGeometry.radius(for: profile.effectiveSpatialSettings.seating), existing: session.positions.map(\.coordinate))))
        positionIndex = session.positions.count - 1; self.session = session; status = restoredMeasurementStatus; revision += 1; persistSession()
    }
    var canRemovePosition: Bool {
        guard !busy, !isVerifying, let session, session.source.kind == .microphone,
              let position, !position.isMain, session.positions.count > 3 else { return false }
        return position.skipped || session.positions.filter { !$0.skipped }.count > 3
    }
    func removePosition() {
        guard canRemovePosition, var session else { return }
        calculatedResult = nil
        let id = session.positions[positionIndex].id
        session.retireMicrophoneTakes(positionID: id, channels: Set(measurementChannels))
        session.positions.remove(at: positionIndex)
        self.session = session; positionIndex = max(0, min(positionIndex, session.positions.count - 1)); revision += 1
        status = restoredMeasurementStatus
        persistSession()
    }
    func skipPosition() {
        guard !busy, !isVerifying, var session, session.source.kind == .microphone,
              session.positions.indices.contains(positionIndex), !session.positions[positionIndex].isMain else { return }
        guard session.positions[positionIndex].skipped || session.positions.filter({ !$0.skipped }).count > 3 else { return }
        calculatedResult = nil
        session.positions[positionIndex].skipped.toggle(); self.session = session
        if session.positions[positionIndex].skipped { positionIndex = min(positionIndex + 1, session.positions.count - 1) }
        status = restoredMeasurementStatus; revision += 1; persistSession()
    }
    func persistSession(preservingSetupOnClose: Bool = false) {
        guard !busy, var session else { return }
        if session.blocks.isEmpty && session.recordings.isEmpty && session.source.kind == source.kind {
            session.source = source
            self.session = session
        }
        let snapshot = session
        let store = measurementStore
        savingSessionSetup = preservingSetupOnClose
        run { [self] in
            defer { savingSessionSetup = false }
            try await worker(committing: true) { try Task.checkCancellation(); try store.save(snapshot) }
            saveReference(snapshot)
        }
    }
    private func saveReference(_ session: RoomMeasurementSession) {
        guard !isVerifying else { return }
        guard let app, var profile = app.profiles.profiles.first(where: { $0.id == profileID }),
              profile.effectiveSpatialSettings.seating?.id == loadedSeatID else { return }
        var seat = profile.effectiveSpatialSettings.seating ?? .init(outputDeviceUID: profile.outputDeviceUID)
        seat.roomCorrectionSessionID = session.id
        loadedSeatID = seat.id
        profile.spatialSettings.seating = seat
        app.profiles.update(profile)
    }
    private func startMicrophoneCapture(id: String, retainAudio: Bool = true) async throws -> SpatialMicrophoneCapture {
        let recorder = SpatialMicrophoneCapture()
        capture = recorder; microphoneLevel = nil
        try await recorder.start(id: id, retainAudio: retainAudio)
        // Starting an AVCaptureSession does not guarantee that input frames
        // have arrived. Wait for the selected microphone before emitting codes.
        for _ in 0..<20 where recorder.inputLevel == nil { try await Task.sleep(for: .milliseconds(50)) }
        guard recorder.inputLevel != nil, !recorder.hasDiscontinuity else { throw AcousticMeasurementError.captureFailed }
        return recorder
    }
    func measure(profile: DeviceProfile, selectedChannel: Int?, preview: Bool = false) {
        guard !busy else { return }
        // An unused setup has no acoustic evidence to invalidate. Keep its
        // position offsets when the listener or output changes before a take.
        do {
            if !isVerifying, var setup = session, setup.blocks.isEmpty, setup.recordings.isEmpty,
               setup.positions.allSatisfy({ $0.observations.isEmpty }),
               let app, let saved = app.profiles.profiles.first(where: { $0.id == profile.id }),
               saved.effectiveSpatialSettings.seating?.id == loadedSeatID {
                let current = try app.applyingSessionEQDrafts(to: saved)
                let updated = try captureContext(for: current)
                if setup.context != updated {
                    let old = setup.context.listener, new = updated.listener
                    for index in setup.positions.indices {
                        let point = setup.positions[index].coordinate
                        setup.positions[index].coordinate = .init(x: point.x + new.x - old.x,
                            y: point.y + new.y - old.y, z: point.z + new.z - old.z)
                    }
                    setup.context = updated
                    session = setup; calculatedResult = nil; revision += 1
                }
                measurementChannels = current.configuredProcessingChannels.map(\.index)
            }
        } catch { self.error = error.localizedDescription; return }
        guard let initial = session, let position else { return }
        let planned = preview ? [] : plannedBlocks(selectedChannel: selectedChannel)
        let channels = measurementChannels.filter { initial.source.kind == .recorder || selectedChannel == nil || $0 == selectedChannel }
        let requestedGain = testVolumeDB
        let positionLabel = "Position \(positionIndex + 1) of \(initial.positions.count)"
        status = "Preparing sound · \(positionLabel)"
        let selectedSource = source
        let store = measurementStore
        run(preview ? .levelCheck : .measurement) { [self] in
            if !preview && initial.source.kind == .microphone {
                guard selectedSource.deviceID != nil, let calibration = selectedSource.calibration else {
                    throw RoomCorrectionError.calibrationRequired
                }
                try calibration.validateForRoomMeasurement()
            }
            let initial = try await worker(committing: true) { preview ? initial : try store.updatingSource(selectedSource, in: initial) }
            if planned.contains(where: { block in
                initial.context.topology.endpoints.first { $0.id.channelIndex == block.channel }?.isSubwooferLike == true && block.markerChannel == nil
            }) { throw RoomCorrectionError.referenceSpeakerRequired }
            self.session = initial
            guard let app else { throw RoomCorrectionError.routeUnavailable }
            await app.runtimeCoordinator.waitUntilSettled()
            try Task.checkCancellation()
            guard app.isActive, app.activeProfileID == profile.id else { throw RoomCorrectionError.routeUnavailable }
            guard let savedProfile = app.profiles.profiles.first(where: { $0.id == profile.id }),
                  savedProfile.effectiveSpatialSettings.seating?.id == loadedSeatID else { throw RoomCorrectionError.stale }
            let currentProfile = try app.applyingSessionEQDrafts(to: savedProfile)
            guard initial.context == (try captureContext(for: currentProfile)) else { throw RoomCorrectionError.stale }
            guard let startingVolume = app.acousticVolumeSnapshot else { throw RoomCorrectionError.routeUnavailable }
            guard !startingVolume.muted, startingVolume.scalar > 0 else { throw RoomCorrectionError.outputMuted }
            if !preview && !isVerifying { calculatedResult = nil }
            let measuringProfile = try isVerifying ? currentProfile : currentProfile.roomMeasurementProfile()
            let startingRuntimeID = app.activeSession?.id
            // The existing runtime prepares assets and validates the candidate before committing.
            app.clearTransientError()
            await app.apply(profile: measuringProfile)
            do {
                await app.runtimeCoordinator.waitUntilSettled()
                try Task.checkCancellation()
                guard app.errorMessage == nil, app.activeProfileID == profile.id,
                      try await app.runtimeCoordinator.hasAppliedConfiguration(for: measuringProfile) else {
                    throw RoomCorrectionError.routeUnavailable
                }
            } catch {
                let baselineApplied = (try? await Task { @MainActor in
                    try await app.runtimeCoordinator.hasAppliedConfiguration(for: measuringProfile)
                }.value) == true
                await restoreMeasurementProfile(profileID: profile.id,
                    runtimeID: baselineApplied ? app.activeSession?.id : startingRuntimeID, app: app)
                throw error
            }
            guard let context = app.beginSpatialCalibration(profileID: profile.id, roomMeasurement: true) else {
                await restoreMeasurementProfile(profileID: profile.id, runtimeID: app.activeSession?.id, app: app)
                throw RoomCorrectionError.routeUnavailable
            }
            self.context = context
            app.holdSpatialMeasurement(context: context, enabled: true)
            do {
                var session = initial
                if !preview && initial.source.kind == .microphone {
                    // Retire previous takes for just the selected physical channels.
                    // A failed or cancelled repeat must not pair with an older take.
                    let measured = Set(planned.map(\.channel))
                    session.retireMicrophoneTakes(positionID: position.id, channels: measured)
                    let retired = session
                    try await worker(committing: true) { try Task.checkCancellation(); try store.save(retired) }
                    self.session = session; saveReference(session)
                }
                guard let graph = app.runtimeCoordinator.appliedProcessingGraph else { throw RoomCorrectionError.routeUnavailable }
                // The baseline apply can replace the volume lease. Freeze only
                // this position's take, after that apply, not the whole editor.
                // Analysis normalizes broadband level across positions.
                guard let volume = app.acousticVolumeSnapshot else { throw RoomCorrectionError.playbackInterrupted }
                guard !volume.muted, volume.scalar > 0 else { throw RoomCorrectionError.outputMuted }
                @MainActor func validatePlayback() throws {
                    try Task.checkCancellation()
                    guard app.isActive, app.activeProfileID == profile.id,
                          app.activeSession?.id == context.runtimeSessionID,
                          app.spatialCalibrationContext == context,
                          app.runtimeCoordinator.activePhysicalOutputUID == context.outputDeviceUID,
                          Double(app.runtimeCoordinator.activeSampleRate ?? 0) == context.sampleRate,
                          app.coreAudio.defaultOutputUID == app.runtimeCoordinator.activeRoutingUID else { throw RoomCorrectionError.playbackInterrupted }
                    guard let saved = app.profiles.profiles.first(where: { $0.id == profile.id }),
                          saved.effectiveSpatialSettings.seating?.id == self.loadedSeatID,
                          try self.captureContext(for: app.applyingSessionEQDrafts(to: saved)) == initial.context,
                          app.runtimeCoordinator.appliedProcessingGraph == graph else { throw RoomCorrectionError.stale }
                    if !preview {
                        guard let current = app.acousticVolumeSnapshot else { throw RoomCorrectionError.playbackInterrupted }
                        guard current.scalar == volume.scalar, current.muted == volume.muted,
                              current.revision == volume.revision else { throw RoomCorrectionError.volumeChanged }
                        guard current.audibility == .permitted, current.physicalReady else { throw RoomCorrectionError.playbackInterrupted }
                    }
                }
                let ceiling = try await worker { try RoomMeasurementSignal.boundedVolumeDB(RoomMeasurementSignal.volumeRangeDB.upperBound, graph: graph) }
                testVolumeMaximumDB = floor(ceiling)
                let gain = min(preview ? testVolumeDB : requestedGain, testVolumeMaximumDB)
                testVolumeDB = gain
                var blocks = planned.map { block in
                    var adjusted = block
                    adjusted.playbackGainDB = RoomMeasurementSignal.playbackGainDB(forVolumeDB: gain)
                    return adjusted
                }
                if preview {
                    if selectedSource.kind == .microphone {
                        guard let id = selectedSource.deviceID else { throw AcousticMeasurementError.noMicrophone }
                        _ = try await startMicrophoneCapture(id: id, retainAudio: false)
                    }
                    let ceiling = testVolumeMaximumDB
                    guard !channels.isEmpty else { throw RoomCorrectionError.invalidSettings }
                    levelCheckCeilingDB = ceiling
                    // Measurement sweeps play one speaker at a time. Check every
                    // selected speaker at that same level, retaining live gain
                    // changes and a start/stop fade for each channel transition.
                    while true {
                        for channel in channels {
                            try validatePlayback()
                            let clip = try await worker {
                                try RoomMeasurementSignal.levelCheckClip(topology: initial.context.topology, channel: channel,
                                    gainDB: RoomMeasurementSignal.playbackGainDB(forVolumeDB: ceiling))
                            }
                            let initialGain = Float(pow(10, (testVolumeDB - ceiling) / 20))
                            status = "Playing sound · \(positionLabel)"
                            let playback = RoomMeasurementPlaybackCompletion()
                            try validatePlayback()
                            guard app.playSpatialCalibration(context: context, clip: clip, levelCheckGain: initialGain,
                                started: { playback.start(at: $0) }, completion: { playback.finish() }) else {
                                throw RoomCorrectionError.routeUnavailable
                            }
                            while !playback.isFinished {
                                try await Task.sleep(for: .milliseconds(100))
                                let output = playback.startedAt != nil && !playback.isFinished ? clip.physicalOutput : nil
                                if playingOutput != output { playingOutput = output }
                                microphoneLevel = capture?.inputLevel
                                if capture?.hasDiscontinuity == true { throw AcousticMeasurementError.captureFailed }
                                try validatePlayback()
                                if channels.count > 1, let started = playback.startedAt,
                                   ProcessInfo.processInfo.systemUptime - started >= 2 {
                                    app.pcmRouter.stopSpatialCalibrationSample(id: context.id)
                                }
                            }
                            try validatePlayback()
                            playingOutput = nil
                        }
                    }
                }
                if !preview && blocks.isEmpty { throw RoomCorrectionError.routeUnavailable }
                for index in blocks.indices {
                    let plannedBlock = blocks[index]
                    try validatePlayback()
                    let clip = try await worker { () -> SpatialCalibrationClip in
                        let signal = try RoomMeasurementSignal(block: plannedBlock, sampleRate: context.sampleRate)
                        guard let clip = signal.clip(topology: initial.context.topology) else { throw RoomCorrectionError.routeUnavailable }
                        return clip
                    }
                    var block = plannedBlock
                    let recorder: SpatialMicrophoneCapture?
                    if !preview && initial.source.kind == .microphone {
                        guard let microphone = initial.source.deviceID else { throw AcousticMeasurementError.noMicrophone }
                        recorder = try await startMicrophoneCapture(id: microphone)
                        try await Task.sleep(for: .milliseconds(250))
                    } else { recorder = nil }
                    status = "Playing sound · \(positionLabel)"
                    let playback = RoomMeasurementPlaybackCompletion()
                    try validatePlayback()
                    guard app.playSpatialCalibration(context: context, clip: clip,
                        started: { playback.start(at: $0) }, completion: { playback.finish() }) else { throw RoomCorrectionError.routeUnavailable }
                    var tail = 0
                    for _ in 0..<140 {
                        try await Task.sleep(for: .milliseconds(100))
                        let output = playback.startedAt != nil && !playback.isFinished ? clip.physicalOutput : nil
                        if playingOutput != output { playingOutput = output }
                        if let recorder {
                            microphoneLevel = recorder.inputLevel
                            if microphoneLevel?.clipped == true { throw RoomCorrectionError.inputClipped }
                            if recorder.hasDiscontinuity { throw AcousticMeasurementError.captureFailed }
                        }
                        try validatePlayback()
                        if playback.isFinished { tail += 1 }
                        if tail >= 8 { break }
                    }
                    try validatePlayback()
                    guard tail >= 8, playback.startedAt != nil else { throw RoomCorrectionError.playbackInterrupted }
                    block.playbackStartTime = playback.startedAt; block.playbackClockID = playbackClockID
                    blocks[index] = block
                    if let recorder {
                        status = "Analyzing · \(positionLabel)"
                        session.blocks.append(block)
                        let recording = await recorder.stop(); self.capture = nil
                        guard !recording.discontinuity else { throw AcousticMeasurementError.captureFailed }
                        let snapshot = session
                        let measuredBlock = block
                        session = try await worker(committing: true) {
                            var analyzed = try RoomMeasurementStore.analyze((recording.samples, recording.sampleRate, "wav", false), blocks: [measuredBlock], session: snapshot)
                            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID()).wav")
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            try RoomMeasurementStore.writeWAV(samples: recording.samples, sampleRate: recording.sampleRate, to: temporary)
                            let reference = try store.retain(temporary, sessionID: snapshot.id, blocks: [measuredBlock], format: "wav", isLossy: false)
                            analyzed.recordings.append(reference)
                            try Task.checkCancellation(); try store.save(analyzed)
                            return analyzed
                        }
                        self.session = session
                        saveReference(session)
                    }
                }
                try validatePlayback()
                if !preview {
                    if initial.source.kind == .recorder { session = try completedRecorderPosition(blocks, in: initial) }
                    if let i = session.positions.firstIndex(where: { $0.id == position.id }) { session.positions[i].skipped = false }
                    let saved = session
                    try await worker(committing: true) { try Task.checkCancellation(); try store.save(saved) }
                    self.session = session; saveReference(session)
                    advanceAfterPlayback()
                } else { status = "" }
            } catch {
                playingOutput = nil
                if let capture { _ = await capture.stop(); self.capture = nil }
                app.endSpatialCalibration(id: context.id); self.context = nil
                await restoreMeasurementProfile(profileID: profile.id, runtimeID: context.runtimeSessionID, app: app)
                throw error
            }
            if let capture { _ = await capture.stop(); self.capture = nil }
            app.endSpatialCalibration(id: context.id); self.context = nil
            await restoreMeasurementProfile(profileID: profile.id, runtimeID: context.runtimeSessionID, app: app)
            if !preview && isVerifying && session?.microphoneMeasurementsComplete == true {
                try finishVerification(profile: currentProfile)
            }
        }
    }
    private func restoreMeasurementProfile(profileID: UUID, runtimeID: UUID?, app: AppState) async {
        await app.runtimeCoordinator.waitUntilSettled()
        guard app.isActive, app.activeProfileID == profileID, app.activeSession?.id == runtimeID,
              let latest = app.profiles.profiles.first(where: { $0.id == profileID }),
              let current = try? app.applyingSessionEQDrafts(to: latest) else { return }
        await app.apply(profile: current)
    }
    func importRecording(_ url: URL) {
        guard !busy, !isVerifying else { return }
        guard let snapshot = session, !snapshot.blocks.isEmpty else { error = "Play the measurement positions before importing the recording."; return }
        let store = measurementStore
        status = "Analyzing recording…"
        run(.recordingImport) { [self] in
            session = try await worker(committing: true) {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let decoded = try RoomMeasurementStore.read(url)
                var clean = snapshot
                for i in clean.positions.indices { clean.positions[i].observations = [] }
                clean.recordings = []; clean.analysisIssues = nil
                var result = try RoomMeasurementStore.analyze(decoded, blocks: snapshot.blocks, session: clean)
                var recording = try store.retain(url, sessionID: result.id, blocks: snapshot.blocks, format: decoded.format, isLossy: decoded.isLossy)
                recording.originalFileName = url.lastPathComponent
                result.recordings.append(recording)
                try Task.checkCancellation(); try store.save(result); return result
            }
            if let session { saveReference(session) }; status = validationMessage; tab = .analysis
            calculatedResult = nil
        }
    }
    func removeImportedRecording() {
        guard let snapshot = session, snapshot.source.kind == .recorder, !snapshot.recordings.isEmpty else { return }
        let store = measurementStore
        run { [self] in
            var updated = snapshot
            updated.recordings = []
            for index in updated.positions.indices { updated.positions[index].observations = [] }
            updated.analysisIssues = nil
            let detached = updated
            // Keep the audio files and playback blocks so another file can be
            // imported without repeating playback or changing applied correction.
            try await worker(committing: true) { try Task.checkCancellation(); try store.save(detached) }
            session = detached; saveReference(detached)
            calculatedResult = nil
            status = restoredMeasurementStatus; tab = .measure
        }
    }
    func reanalyze() {
        guard !isVerifying, let snapshot = session else { return }
        let selectedSource = source
        let store = measurementStore
        run { [self] in
            status = "Reanalyzing saved recordings…"
            session = try await worker(committing: true) { try store.updatingSource(selectedSource, in: snapshot, force: true) }
            if let session { saveReference(session) }
            calculatedResult = nil; status = validationMessage
        }
    }
    func normalizeCorrectionSettings() {
        let calibrated = source.kind == .microphone
        if settings.method == .hybrid { settings.method = .iir }
        if let value = settings.lowHz { settings.lowHz = max(calibrated ? 20 : 45, value) }
        if let value = settings.highHz { settings.highHz = min(calibrated ? 20000 : 300, value) }
        if let value = settings.maximumBoostDB { settings.maximumBoostDB = min(calibrated ? 1 : 0, value) }
        if let value = settings.maximumCutDB { settings.maximumCutDB = min(calibrated ? 8 : 1.5, value) }
        if let value = settings.maximumQ { settings.maximumQ = min(4, value) }
        if let value = settings.filterCount { settings.filterCount = min(calibrated ? 8 : 5, value) }
        if (settings.lowHz ?? (calibrated ? 20 : 45)) >= (settings.highHz ?? (calibrated ? 800 : 300)) {
            settings.lowHz = nil; settings.highHz = nil
        }
    }

    private func captureContext(for profile: DeviceProfile) throws -> RoomMeasurementContext {
        try isVerifying ? profile.roomVerificationContext() : profile.roomMeasurementContext()
    }
    func verificationIsCurrent(profile: DeviceProfile) -> Bool {
        guard let current = try? app?.applyingSessionEQDrafts(to: profile),
              let result = current.effectiveSpatialSettings.seating?.roomCorrectionResult,
              let baseline = verificationBaseline ?? session,
              result.measurementIdentity == .init(session: baseline),
              let plan = try? RoomCorrectionImportPlan(result: result, profile: current) else { return false }
        return plan.matches(profile: current)
    }
    func canVerify(profile: DeviceProfile) -> Bool {
        guard !busy, !isVerifying, let session, session.source.kind == .microphone,
              let result = profile.effectiveSpatialSettings.seating?.roomCorrectionResult,
              result.sessionID == session.id,
              calculatedResult?.generatedAt == result.generatedAt, settings == result.settings,
              result.measurementIdentity == .init(session: session),
              result.predictions != nil, result.importedChannelChains != nil else { return false }
        return verificationIsCurrent(profile: profile)
    }
    func startVerification(profile: DeviceProfile) {
        guard canVerify(profile: profile), let baseline = session,
              let result = profile.effectiveSpatialSettings.seating?.roomCorrectionResult else { return }
        do {
            guard let current = try app?.applyingSessionEQDrafts(to: profile) else { throw RoomCorrectionError.stale }
            verificationBaseline = baseline; verificationCorrection = result
            let positions = baseline.positions.filter { !$0.skipped }.map { original -> RoomMeasurementPosition in
                var position = original; position.observations = []; return position
            }
            var verification = RoomMeasurementSession(context: try current.roomVerificationContext(), source: baseline.source, positions: positions)
            verification.requiresRepeatedPositions = true
            isVerifying = true; verificationMessage = "Measure the same marked positions with correction applied. Keep microphone orientation and output volume unchanged."
            session = verification; positionIndex = 0; tab = .measure; measurementOpen = profileIsActive
            status = verificationMessage; revision += 1
        } catch { self.error = error.localizedDescription }
    }
    func endVerification() {
        guard !busy, isVerifying else { return }
        session = verificationBaseline; verificationBaseline = nil; verificationCorrection = nil
        isVerifying = false; positionIndex = 0; tab = .correction; revision += 1
    }
    private func finishVerification(profile: DeviceProfile) throws {
        guard let app, let baseline = verificationBaseline, let measured = session,
              var result = verificationCorrection,
              var current = app.profiles.profiles.first(where: { $0.id == profile.id }),
              let existing = current.effectiveSpatialSettings.seating?.roomCorrectionResult,
              existing.generatedAt == result.generatedAt,
              try app.applyingSessionEQDrafts(to: current).roomVerificationContext() == measured.context else { throw RoomCorrectionError.stale }
        let report = try RoomCorrectionVerification.evaluate(baseline: baseline, measured: measured, result: result)
        result.verification = report
        current.spatialSettings.seating?.roomCorrectionResult = result
        publishRoomProfile(current, app: app)
        calculatedResult = result; verificationCorrection = result
        verificationMessage = report.reason; status = report.reason; tab = .analysis
    }

    func create(profile: DeviceProfile) {
        guard !busy, !isVerifying, let snapshot = session else { return }
        let settings = settings
        let selectedSource = source
        let store = measurementStore
        status = "Calculating correction…"
        run(.correction) { [self] in
            let snapshot = try await worker(committing: true) { try store.updatingSource(selectedSource, in: snapshot) }
            self.session = snapshot
            try Task.checkCancellation()
            if snapshot.source.kind == .microphone && !snapshot.microphoneMeasurementsComplete {
                throw RoomCorrectionError.incompleteMicrophoneMeasurement
            }
            if let quality = simpleRecordingQuality, !quality.canCalculate {
                calculatedResult = nil; status = ""
                return
            }
            guard let app else { return }
            let current = try app.applyingSessionEQDrafts(to: app.historyProfile(profile.id))
            let currentContext = try current.roomMeasurementContext()
            let sourceContext: RoomMeasurementContext
            if snapshot.context.canReprocess(to: currentContext) { sourceContext = currentContext }
            else if currentContext == importedContext, let importedMeasurementContext,
                    snapshot.context.canReprocess(to: importedMeasurementContext) { sourceContext = importedMeasurementContext }
            else { throw RoomCorrectionError.stale }
            var rebased = snapshot; rebased.context = sourceContext
            let designSession = rebased
            let result = try await worker { try RoomMeasurementStore.materialize(RoomCorrectionDesigner().design(session: designSession, settings: settings)) }
            let latest = try app.applyingSessionEQDrafts(to: app.historyProfile(profile.id))
            guard (try latest.roomMeasurementContext()) == currentContext else { throw RoomCorrectionError.stale }
            try await validateCommit(current, app: app)
            calculatedResult = result; calculationRevision += 1; tab = .correction
            status = ""
        }
    }

    func replacementMessage(profile: DeviceProfile) throws -> String? {
        guard let app, let result = calculatedResult else { return nil }
        let current = try app.applyingSessionEQDrafts(to: app.historyProfile(profile.id))
        return try RoomCorrectionImportPlan(result: result, profile: current).replacementMessage(profile: current)
    }

    var canImport: Bool {
        calculatedResult?.hasCorrection == true && calculatedResult?.settings == settings && !busy && !isVerifying
            && calculatedResult?.optimizerVersion == RoomCorrectionResult.currentOptimizerVersion
            && calculatedResult?.firGeneratorVersion == RoomCorrectionResult.currentFIRGeneratorVersion
            && importContextIsCurrent
    }

    private var importContextIsCurrent: Bool {
        guard let app, let id = profileID, let result = calculatedResult, let session,
              result.measurementIdentity == .init(session: session),
              let saved = app.profiles.profiles.first(where: { $0.id == id }),
              let current = try? app.applyingSessionEQDrafts(to: saved) else { return false }
        return (try? current.roomMeasurementContext()) == result.context
    }

    func importCorrection(profile: DeviceProfile) {
        guard canImport, let result = calculatedResult else { return }
        status = "Importing correction…"
        run(.correction) { [self] in
            guard let app, app.profiles.settingsMutationsAllowed else { throw ProfileSettingsError.busy }
            let saved = try app.historyProfile(profile.id)
            let current = try app.applyingSessionEQDrafts(to: saved)
            let plan = try RoomCorrectionImportPlan(result: result, profile: current)
            var candidate = try plan.applying(to: current)
            @MainActor func latestUnchangedProfile() throws -> DeviceProfile {
                let latest = try app.applyingSessionEQDrafts(to: app.historyProfile(profile.id))
                var normalized = latest
                normalized.outputVolumeScalar = current.outputVolumeScalar
                guard normalized == current else { throw RoomCorrectionError.stale }
                return latest
            }
            let prepared = candidate
            _ = try await worker { try AudioRuntimePlanPreparer.prepareForStorage(profile: prepared, revision: .init(profileID: prepared.id, generation: 0)) }
            candidate.outputVolumeScalar = try latestUnchangedProfile().outputVolumeScalar
            try await validateCommit(candidate, app: app)
            let before = try app.roomCorrectionImportSnapshot(profile: current)
            let after = try app.roomCorrectionImportSnapshot(profile: candidate)
            // Accept the active audio change before publishing saved filters or
            // undo history. A failed runtime apply must not look like an import.
            if app.isActive, app.activeProfileID == profile.id {
                do {
                    app.clearTransientError()
                    await app.apply(profile: candidate)
                    if let message = app.errorMessage { throw ProfileSettingsError.runtime(message) }
                    guard app.activeProfileID == profile.id,
                          try app.runtimeCoordinator.appliedProfile?.resolvedProcessing() == candidate.resolvedProcessing() else {
                        throw RoomCorrectionError.routeUnavailable
                    }
                    try await validateCommit(candidate, app: app)
                    candidate.outputVolumeScalar = try latestUnchangedProfile().outputVolumeScalar
                } catch {
                    if app.isActive, app.activeProfileID == profile.id,
                       let latest = try? app.applyingSessionEQDrafts(to: app.historyProfile(profile.id)) {
                        await app.apply(profile: latest)
                    }
                    throw error
                }
            }
            publishRoomProfile(candidate, app: app)
            for channel in after.channels.keys { app.clearChannelEQDraft(for: profile.id, channelIndex: channel) }
            app.history.record(actionName: "Import Room Correction", contextName: current.name,
                target: .profile(profile.id), before: .roomCorrectionImport(before), after: .roomCorrectionImport(after))
            importedContext = try candidate.roomMeasurementContext()
            importedMeasurementContext = result.context
            app.publishHistoryReplay()
            app.clearPendingEditorApply(profile.id)
            importRevision += 1; status = ""
        }
    }
    func setEnabled(_ enabled: Bool, profile: DeviceProfile) {
        run { [self] in
            guard let app else { return }
            var current = app.profiles.profiles.first(where: { $0.id == profile.id }) ?? profile
            if enabled && current.roomCorrectionIsStale { throw RoomCorrectionError.stale }
            if enabled && current.effectiveSpatialSettings.seating?.roomCorrectionResult?.hasCorrection == false { return }
            current.spatialSettings.seating?.roomCorrectionEnabled = enabled
            current.synchronizeListeningPositionCorrection()
            if app.activeProfileID == current.id {
                await app.apply(profile: current)
                guard app.runtimeCoordinator.appliedProfile?.effectiveSpatialSettings.seating?.roomCorrectionEnabled == enabled else { throw RoomCorrectionError.routeUnavailable }
            }
            try await validateCommit(current, app: app)
            publishRoomProfile(current, app: app); comparisonPlayback = nil
            status = enabled ? "Room Correction ON" : "Room Correction OFF"
        }
    }
    func reset(profile: DeviceProfile) {
        guard !busy else { return }
        if isVerifying { endVerification() }
        run { [self] in
            if let app {
                guard var current = app.profiles.profiles.first(where: { $0.id == profile.id }),
                      current.effectiveSpatialSettings.seating?.id == profile.effectiveSpatialSettings.seating?.id else { throw CancellationError() }
                current.resetRoomCorrection()
                if app.activeProfileID == current.id {
                    await app.apply(profile: current)
                    guard let applied = app.runtimeCoordinator.appliedProfile, applied.id == current.id,
                          applied.effectiveSpatialSettings.seating?.roomCorrectionEnabled != true,
                          applied.effectiveSpatialSettings.seating?.roomCorrectionResult == nil,
                          applied.effectiveSpatialSettings.seating?.roomCorrectionBands.isEmpty != false else { throw RoomCorrectionError.routeUnavailable }
                }
                try await validateCommit(current, app: app)
                publishRoomProfile(current, app: app)
                loadedSeatID = current.effectiveSpatialSettings.seating?.id
            }
            // Detach saved bundles instead of deleting files that another seat
            // or profile may reference. Nothing from this session reloads here.
            session = nil; comparison = nil; drafts = [:]
            calculatedResult = nil; importedContext = nil; importedMeasurementContext = nil
            context = nil; issuedTokens = []
            source = Self.defaultSource; source.deviceID = microphones.first?.id
            settings = .init(); positionIndex = 0; recorderPositionCount = .five; microphonePositionCount = .nine
            microphoneLevel = nil
            testVolumeDB = RoomMeasurementSignal.defaultVolumeDB; testVolumeMaximumDB = RoomMeasurementSignal.volumeRangeDB.upperBound
            levelCheckCeilingDB = nil; comparisonPlayback = nil; measurementOpen = false
            status = ""; error = nil; tab = .measure
        }
    }

    private struct ComparisonPlayback {
        let id = UUID()
        let profileID: UUID
        let sessionID: UUID
        let graph: ProcessingGraph
    }
    @Published private var comparisonPlayback: ComparisonPlayback?
    private var comparisonRestoreTask: Task<Void, Never>?
    private static let comparisonRestoreFailure = "The saved room correction could not be restored. Reactivate this profile to restore its saved processing."

    /// Runtime changes can restore saved correction without another button press.
    /// Keep the displayed comparison attached to the bypass that actually plays.
    func clearComparisonForRuntimeChange() {
        guard let playback = comparisonPlayback else { return }
        guard let app, app.activeSession?.id == playback.sessionID,
              app.activeProfileID == playback.profileID,
              app.runtimeCoordinator.appliedProcessingGraph == playback.graph else {
            comparisonPlayback = nil
            return
        }
    }

    private func comparisonInputsMatch(_ original: DeviceProfile, _ current: DeviceProfile) throws -> Bool {
        let before = original.effectiveSpatialSettings.seating
        let after = current.effectiveSpatialSettings.seating
        guard original.id == current.id, current.isEnabled,
              before?.id == after?.id,
              before?.roomCorrectionEnabled == after?.roomCorrectionEnabled,
              before?.roomCorrectionResult == after?.roomCorrectionResult else { return false }
        // Include user channel processing while ignoring persisted volume,
        // profile names and EQ editor metadata that cannot change the comparison.
        var a = try original.roomMeasurementContext(), b = try current.roomMeasurementContext()
        a.processing = try original.resolvedProcessing()
        b.processing = try current.resolvedProcessing()
        return a == b
    }

    private func comparisonConfigurationIsApplied(_ profile: DeviceProfile, app: AppState) async throws -> Bool {
        // Cleanup still has to determine what reached the audio engine after
        // navigation cancelled the editor task during an apply.
        try await Task { @MainActor in
            try await app.runtimeCoordinator.hasAppliedConfiguration(for: profile)
        }.value
    }

    private func restoreComparison(_ playback: ComparisonPlayback, app: AppState) async throws {
        await app.runtimeCoordinator.waitUntilSettled()
        clearComparisonForRuntimeChange()
        guard comparisonPlayback?.id == playback.id,
              let current = app.profiles.profiles.first(where: { $0.id == playback.profileID }) else { return }
        app.clearTransientError()
        await app.apply(profile: current)
        guard app.activeProfileID == playback.profileID else {
            clearComparisonForRuntimeChange()
            // A failed graph restore can stop the runtime. Report that failure
            // even though there is no longer a live bypass to track.
            if !app.isActive, app.errorMessage != nil { throw ProfileSettingsError.runtime(Self.comparisonRestoreFailure) }
            return
        }
        guard try await comparisonConfigurationIsApplied(current, app: app) else {
            clearComparisonForRuntimeChange()
            throw ProfileSettingsError.runtime(Self.comparisonRestoreFailure)
        }
        if comparisonPlayback?.id == playback.id { comparisonPlayback = nil }
        if error == Self.comparisonRestoreFailure { error = nil }
    }

    func compare(profile: DeviceProfile) {
        run { [self] in
            guard let app else { throw RoomCorrectionError.routeUnavailable }
            await app.runtimeCoordinator.waitUntilSettled()
            try Task.checkCancellation()
            clearComparisonForRuntimeChange()
            if let playback = comparisonPlayback {
                try await restoreComparison(playback, app: app)
                return
            }
            guard app.activeProfileID == profile.id, let runtimeSession = app.activeSession,
                  let current = app.profiles.profiles.first(where: { $0.id == profile.id }),
                  current.effectiveSpatialSettings.seating?.id == profile.effectiveSpatialSettings.seating?.id,
                  current.effectiveSpatialSettings.seating?.roomCorrectionEnabled == true,
                  !current.roomCorrectionIsStale,
                  let result = current.effectiveSpatialSettings.seating?.roomCorrectionResult else { throw RoomCorrectionError.routeUnavailable }
            let profile = current
            var bypass = profile
            bypass.spatialSettings.seating?.roomCorrectionEnabled = false
            bypass.synchronizeListeningPositionCorrection()
            let bypassSnapshot = bypass
            let plans = try await worker { () -> (Double, Double) in
                let revision = RuntimeIntentRevision(profileID: profile.id, generation: 0)
                let corrected = try AudioRuntimePlanPreparer.prepareForStorage(profile: profile, revision: revision)
                let uncorrected = try AudioRuntimePlanPreparer.prepareForStorage(profile: bypassSnapshot, revision: revision)
                return (corrected.processingGraph.automaticHeadroomDB, uncorrected.processingGraph.automaticHeadroomDB)
            }
            // Match broadband energy over a log-frequency grid, including actual room IR response.
            let level = try await worker { () -> Double in
                var energy = 0.0, count = 0
                let channels = profile.configuredProcessingChannels.map(\.index)
                for channel in channels {
                    var fir: [Float] = []
                    if let processor = result.channelFIR[channel] {
                        fir = try RoomMeasurementStore.read(ImpulseResponseStore().url(for: processor.asset)).samples
                    }
                    for i in 0..<192 {
                        let frequency = 30 * pow(20000.0 / 30, Double(i) / 191)
                        let db = EQResponseCalculator().gainDB(at: frequency,
                            parsed: .init(preampDB: 0, bands: result.sharedBands + (result.channelBands[channel] ?? [])), sampleRate: Double(profile.sampleRate))
                        var magnitude = 1.0
                        if !fir.isEmpty {
                            let omega = 2 * Double.pi * frequency / Double(profile.sampleRate)
                            var re = 0.0, im = 0.0
                            for j in fir.indices { re += Double(fir[j]) * cos(omega * Double(j)); im -= Double(fir[j]) * sin(omega * Double(j)) }
                            magnitude = re * re + im * im
                        }
                        energy += pow(10, db / 10) * magnitude; count += 1
                    }
                }
                return count == 0 ? 0 : 10 * log10(max(1e-12, energy / Double(count)))
            }
            // The bypass may only attenuate. Positive compensation could defeat headroom.
            let gain = min(0, plans.0 - plans.1 + level)
            guard app.activeSession?.id == runtimeSession.id else { throw RoomCorrectionError.routeUnavailable }
            guard let latest = app.profiles.profiles.first(where: { $0.id == profile.id }),
                  try comparisonInputsMatch(profile, latest) else { throw RoomCorrectionError.stale }
            bypass = latest
            bypass.spatialSettings.seating?.roomCorrectionEnabled = false
            bypass.synchronizeListeningPositionCorrection()
            bypass.processing.global.stages.insert(.init(id: UUID(uuidString: "CA117B72-0000-4000-0003-000000000000")!, processor: .gain(.init(gainDB: gain))), at: 0)
            try Task.checkCancellation()
            await app.apply(profile: bypass)
            guard try await comparisonConfigurationIsApplied(bypass, app: app),
                  let appliedSession = app.activeSession, appliedSession.profileID == profile.id,
                  let graph = app.runtimeCoordinator.appliedProcessingGraph else { throw RoomCorrectionError.routeUnavailable }
            let playback = ComparisonPlayback(profileID: profile.id, sessionID: appliedSession.id, graph: graph)
            comparisonPlayback = playback
            do {
                try Task.checkCancellation()
                guard let latest = app.profiles.profiles.first(where: { $0.id == profile.id }),
                      try comparisonInputsMatch(profile, latest) else { throw RoomCorrectionError.stale }
            } catch {
                try await restoreComparison(playback, app: app)
                throw error
            }
        }
    }

    func cancel() {
        playingOutput = nil
        task?.cancel()
        if let context { app?.endSpatialCalibration(id: context.id) }
        if measuring || testingSound { status = "Stopping · Position \(positionIndex + 1)" }
    }
    func close() {
        pauseMeasurement()
        if !savingSessionSetup { cancel() }
        endCompare()
    }
    func endCompare() {
        clearComparisonForRuntimeChange()
        guard let playback = comparisonPlayback, let app, comparisonRestoreTask == nil else { return }
        if error == Self.comparisonRestoreFailure { error = nil }
        comparisonRestoreTask = Task { [self] in
            defer { comparisonRestoreTask = nil }
            do { try await restoreComparison(playback, app: app) }
            catch {
                self.error = error.localizedDescription
                if app.errorMessage == nil { app.errorMessage = error.localizedDescription }
            }
        }
    }
    deinit { task?.cancel() }
}

private final class RoomMeasurementPlaybackCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var startTime: TimeInterval?
    func start(at time: TimeInterval) { lock.lock(); startTime = time; lock.unlock() }
    var startedAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return startTime }
    func finish() { lock.lock(); finished = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}
