import CamiTuneAudio
import CamiTuneDomain
import Combine
import Foundation

@MainActor
final class RoomCorrectionEditorState: ObservableObject {
    enum Tab: String, CaseIterable { case measure, analysis, correction }
    @Published var tab: Tab = .measure
    @Published var source = RoomMeasurementSource() {
        didSet {
            if let session, source.kind == session.source.kind, source != session.source {
                calculatedResult = nil
            }
        }
    }
    @Published var settings = RoomCorrectionSettings()
    @Published var microphones: [MeasurementMicrophone] = []
    @Published var positionIndex = 0
    @Published var recorderPositionCount: RoomRecorderPositionCount = .five
    @Published var microphonePositionCount: RoomRecorderPositionCount = .nine
    @Published private(set) var microphoneLevel: MicrophoneInputLevel?
    @Published private(set) var testingSound = false
    private var levelCheckCeilingDB: Double?
    @Published private(set) var testVolumeDB = 0.0
    @Published private(set) var testVolumeMaximumDB = RoomMeasurementSignal.volumeRangeDB.upperBound
    var testVolumeRangeDB: ClosedRange<Double> { min(-24, testVolumeMaximumDB)...testVolumeMaximumDB }
    func setTestVolumeDB(_ value: Double) {
        guard (!busy || testingSound), value.isFinite else { return }
        testVolumeDB = min(testVolumeMaximumDB, max(testVolumeRangeDB.lowerBound, value))
        if testingSound, let context, let ceiling = levelCheckCeilingDB {
            app?.setLevelCheckGain(context: context, gain: Float(pow(10, (testVolumeDB - ceiling) / 20)))
        }
    }
    @Published var status = ""
    @Published var error: String?
    @Published private(set) var busy = false
    @Published private(set) var comparing = false
    @Published private(set) var revision = 0
    @Published private(set) var calculatedResult: RoomCorrectionResult?
    @Published private(set) var calculationRevision = 0
    @Published private(set) var importRevision = 0
    private var importedContext: RoomMeasurementContext?
    private var importedMeasurementContext: RoomMeasurementContext?
    var session: RoomMeasurementSession?
    var comparison: RoomMeasurementSession?
    private var task: Task<Void, Never>?
    private var capture: SpatialMicrophoneCapture?
    private var context: SpatialCalibrationContext?
    private var loadedProfile: UUID?
    private var loadedSeatID: UUID?
    private weak var app: AppState?
    private var profileID: UUID?
    private var volume: SystemVolumeControlSession.Snapshot?
    private var drafts: [RoomMeasurementSource.Kind: RoomMeasurementSession] = [:]
    private var draftVolumes: [RoomMeasurementSource.Kind: SystemVolumeControlSession.Snapshot] = [:]
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
        hasMeasurements && !busy && (source.kind != .microphone || session?.microphoneMeasurementsComplete == true)
    }
    var microphoneActionTitle: String {
        guard let session, let position else { return "Measure Position" }
        return session.microphonePositionIsComplete(position) ? "Measure Again" : "Measure Position"
    }
    func setMicrophone(_ id: String?) {
        guard !busy, !hasMicrophoneCaptures, source.deviceID != id else { return }
        source.deviceID = id; source.deviceName = microphones.first { $0.id == id }?.name ?? "Unknown / not listed"
        source.calibration = nil; calculatedResult = nil
    }
    func setCalibration(_ calibration: MicrophoneCalibrationCurve) {
        guard !busy, source.kind == .microphone else { return }
        source.calibration = calibration
        if session != nil { reanalyze() }
    }
    func refreshMicrophones() {
        run { [self] in microphones = try await worker { SpatialMicrophoneCapture.microphones } }
    }
    func setMicrophonePositionCount(_ count: RoomRecorderPositionCount, profile: DeviceProfile) {
        guard !busy, !hasMicrophoneCaptures, microphonePositionCount != count else { return }
        microphonePositionCount = count
        if session?.source.kind == .microphone { beginSession(profile: profile) }
    }
    var recorderPlaybackComplete: Bool {
        guard let session, session.source.kind == .recorder, !session.positions.isEmpty else { return false }
        return session.positions.allSatisfy { hasPlayed($0, in: session) }
    }
    var recorderActionTitle: String {
        if recorderPlaybackComplete { return "Import Recording…" }
        if let position, let session, hasPlayed(position, in: session) { return "Play Again" }
        return session?.blocks.isEmpty == false ? "Next" : "Play Sound"
    }
    func hasPlayed(_ position: RoomMeasurementPosition, in session: RoomMeasurementSession) -> Bool {
        !measurementChannels.isEmpty && measurementChannels.allSatisfy { channel in
            let blocks = session.blocks.filter { $0.positionID == position.id && $0.channel == channel }
            return blocks.contains { !$0.isRepeat } && (!position.isMain || blocks.contains { $0.isRepeat })
        }
    }
    func selectPosition(_ index: Int) {
        guard !busy, session?.positions.indices.contains(index) == true else { return }
        positionIndex = index; status = ""; error = nil
    }
    func setSourceKind(_ kind: RoomMeasurementSource.Kind, profile: DeviceProfile) {
        guard !busy, source.kind != kind else { return }
        calculatedResult = nil
        let started = session != nil
        if let session {
            drafts[session.source.kind] = session
            draftVolumes[session.source.kind] = volume
        }
        source = drafts[kind]?.source ?? .init()
        source.kind = kind
        if kind == .microphone, source.deviceID == nil { source.deviceID = microphones.first?.id }
        guard started else { return }
        if let draft = drafts[kind], draft.context == (try? profile.roomMeasurementContext()) {
            session = draft
            positionIndex = kind == .recorder ? (draft.positions.indices.first { !hasPlayed(draft.positions[$0], in: draft) } ?? 0) : 0
            volume = draftVolumes[kind]; status = ""; error = nil
            recorderPositionCount = RoomRecorderPositionCount(rawValue: draft.positions.count) ?? .five
            revision += 1
        } else { beginSession(profile: profile) }
    }
    func setRecorderPositionCount(_ count: RoomRecorderPositionCount, profile: DeviceProfile) {
        guard !busy, recorderPositionCount != count else { return }
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
        status = ""; error = nil; revision += 1
        if wasRecorded { persistSession() }
    }
    /// Each attempt gets fresh acoustic IDs, including attempts cancelled before completion.
    func plannedBlocks(selectedChannel: Int?) -> [RoomMeasurementBlock] {
        guard let session, let position else { return [] }
        issuedTokens.formUnion(session.blocks.map(\.token))
        return measurementChannels.filter { session.source.kind == .recorder || selectedChannel == nil || $0 == selectedChannel }
            .flatMap { channel in
                (0..<(position.isMain ? 2 : 1)).map { repeatIndex in
                    var token: UInt32
                    repeat { token = UInt32.random(in: 1...UInt32.max) } while issuedTokens.contains(token)
                    issuedTokens.insert(token)
                    var block = RoomMeasurementBlock(token: token, positionID: position.id, channel: channel, isRepeat: repeatIndex == 1)
                    block.playbackGainDB = testVolumeDB
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
                return "Position \(i + 1) · \(names): \(missingSweep ? "no complete sweep was found in this recording" : "too little repeatable signal above the noise"). Select this position to repeat it."
            }
        }
        return hasMeasurements ? "Measurements ready" : ""
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.testingSound = false; self.levelCheckCeilingDB = nil; self.task = nil; self.revision += 1 }
            do { try Task.checkCancellation(); try await action() } catch is CancellationError { self.status = self.testingSound ? "" : "Stopped" }
            catch { self.status = ""; self.error = error.localizedDescription }
        }
    }
    private func worker<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
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
            self.loadedProfile = nil; self.session = nil; self.comparison = nil; self.volume = nil
            self.source = .init(); self.drafts = [:]; self.draftVolumes = [:]; self.positionIndex = 0; self.status = ""
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
    func load(profile: DeviceProfile, app: AppState) {
        guard loadedProfile != profile.id else { return }
        self.app = app; profileID = profile.id; loadedProfile = profile.id
        measurementChannels = profile.configuredProcessingChannels.map(\.index)
        let seat = profile.effectiveSpatialSettings.seating
        loadedSeatID = seat?.id
        tab = seat?.roomCorrectionResult != nil || seat?.roomCorrectionBands.isEmpty == false ? .correction : .measure
        settings = profile.effectiveSpatialSettings.seating?.roomCorrectionSettings ?? .init()
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
                }
                recorderPositionCount = RoomRecorderPositionCount(rawValue: session.positions.count) ?? .five
                microphonePositionCount = RoomRecorderPositionCount(rawValue: session.positions.count) ?? .nine
            }
            else { source.deviceID = microphones.first?.id }
        }
    }
    func beginSession(profile: DeviceProfile) {
        guard !busy else { return }
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
            volume = nil; error = nil
            if source.kind == .recorder { source.calibration = nil }
            session = .init(context: context, source: source, positions: positions)
            calculatedResult = nil; importedContext = nil; importedMeasurementContext = nil
            positionIndex = 0; tab = .measure; status = "Position 1 of \(positions.count)"; revision += 1
        } catch { self.error = error.localizedDescription }
    }
    func movePosition(_ coordinate: SpatialVector3, profile: DeviceProfile) {
        guard !busy, var session, session.source.kind == .microphone,
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
        self.session = session; error = nil; revision += 1
    }
    func addPosition(profile: DeviceProfile) {
        guard !busy, var session, session.source.kind == .microphone, session.positions.count < 32 else { return }
        calculatedResult = nil
        session.positions.append(.init(coordinate: RoomMeasurementGeometry.suggestion(center: session.context.listener,
            radius: RoomMeasurementGeometry.radius(for: profile.effectiveSpatialSettings.seating), existing: session.positions.map(\.coordinate))))
        positionIndex = session.positions.count - 1; self.session = session; revision += 1; persistSession()
    }
    func removePosition() {
        guard !busy, var session, session.source.kind == .microphone,
              session.positions.indices.contains(positionIndex), !session.positions[positionIndex].isMain else { return }
        calculatedResult = nil
        let id = session.positions[positionIndex].id
        session.retireMicrophoneTakes(positionID: id, channels: Set(measurementChannels))
        session.positions.remove(at: positionIndex)
        self.session = session; positionIndex = max(0, min(positionIndex, session.positions.count - 1)); revision += 1
        persistSession()
    }
    func skipPosition() {
        guard !busy, var session, session.source.kind == .microphone,
              session.positions.indices.contains(positionIndex), !session.positions[positionIndex].isMain else { return }
        guard session.positions[positionIndex].skipped || session.positions.filter({ !$0.skipped }).count > 3 else { return }
        calculatedResult = nil
        session.positions[positionIndex].skipped.toggle(); self.session = session
        if session.positions[positionIndex].skipped { positionIndex = min(positionIndex + 1, session.positions.count - 1) }
        revision += 1; persistSession()
    }
    func persistSession() {
        guard let session else { return }
        let store = measurementStore
        run { [self] in
            try await worker { try store.save(session) }
            saveReference(session)
        }
    }
    private func saveReference(_ session: RoomMeasurementSession) {
        guard let app, var profile = app.profiles.profiles.first(where: { $0.id == profileID }) else { return }
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
        guard !busy, let initial = session, let position else { return }
        let planned = preview ? [] : plannedBlocks(selectedChannel: selectedChannel)
        let channels = measurementChannels.filter { initial.source.kind == .recorder || selectedChannel == nil || $0 == selectedChannel }
        let requestedGain = testVolumeDB
        testingSound = preview
        let selectedSource = source
        let store = measurementStore
        run { [self] in
            if !preview && initial.source.kind == .microphone {
                guard selectedSource.deviceID != nil, let calibration = selectedSource.calibration else {
                    throw RoomCorrectionError.calibrationRequired
                }
                try calibration.validateForRoomMeasurement()
            }
            let initial = try await worker { preview ? initial : try store.updatingSource(selectedSource, in: initial) }
            guard let app, app.isActive, app.activeProfileID == profile.id,
                  initial.context == (try profile.roomMeasurementContext()),
                  let volume = app.acousticVolumeSnapshot, !volume.muted, volume.scalar > 0 else { throw RoomCorrectionError.routeUnavailable }
            if !preview {
                calculatedResult = nil
                if let previous = self.volume, previous != volume { throw RoomCorrectionError.stale }
                self.volume = volume
            }
            let measuringProfile = try profile.roomMeasurementProfile()
            // The existing runtime prepares assets and validates the candidate before committing.
            app.clearTransientError()
            await app.apply(profile: measuringProfile)
            if Task.isCancelled {
                if let latest = app.profiles.profiles.first(where: { $0.id == profile.id }) { await app.apply(profile: latest) }
                throw CancellationError()
            }
            guard app.errorMessage == nil, app.activeProfileID == profile.id,
                  try app.runtimeCoordinator.appliedProfile?.resolvedProcessing() == measuringProfile.resolvedProcessing() else {
                if let latest = app.profiles.profiles.first(where: { $0.id == profile.id }) { await app.apply(profile: latest) }
                throw RoomCorrectionError.routeUnavailable
            }
            guard let context = app.beginSpatialCalibration(profileID: profile.id, roomMeasurement: true) else {
                await app.apply(profile: profile)
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
                    try await worker { try store.save(retired) }
                    self.session = session; saveReference(session)
                }
                guard let graph = app.runtimeCoordinator.appliedProcessingGraph else { throw RoomCorrectionError.routeUnavailable }
                let ceiling = try await worker { try RoomMeasurementSignal.boundedGainDB(RoomMeasurementSignal.volumeRangeDB.upperBound, graph: graph) }
                testVolumeMaximumDB = floor(ceiling)
                let gain = min(preview ? testVolumeDB : requestedGain, testVolumeMaximumDB)
                testVolumeDB = gain
                var blocks = planned.map { block in
                    var adjusted = block; adjusted.playbackGainDB = gain; return adjusted
                }
                if preview {
                    if selectedSource.kind == .microphone {
                        guard let id = selectedSource.deviceID else { throw AcousticMeasurementError.noMicrophone }
                        _ = try await startMicrophoneCapture(id: id, retainAudio: false)
                    }
                    let ceiling = testVolumeMaximumDB
                    let clip = try await worker {
                        try RoomMeasurementSignal.levelCheckClip(topology: initial.context.topology, channels: channels, gainDB: ceiling)
                    }
                    levelCheckCeilingDB = ceiling
                    let initialGain = Float(pow(10, (testVolumeDB - ceiling) / 20))
                    status = ""
                    let playback = RoomMeasurementPlaybackCompletion()
                    guard app.playSpatialCalibration(context: context, clip: clip, levelCheckGain: initialGain,
                        completion: { playback.finish() }) else { throw RoomCorrectionError.routeUnavailable }
                    while !playback.isFinished {
                        try await Task.sleep(for: .milliseconds(100))
                        microphoneLevel = capture?.inputLevel
                        if capture?.hasDiscontinuity == true { throw AcousticMeasurementError.captureFailed }
                        guard app.acousticVolumeSnapshot == volume, app.isActive,
                              app.runtimeCoordinator.appliedProfile?.id == profile.id,
                              (try app.profiles.profiles.first(where: { $0.id == profile.id })?.roomMeasurementContext()) == initial.context else { throw RoomCorrectionError.stale }
                    }
                }
                if !preview && blocks.isEmpty { throw RoomCorrectionError.routeUnavailable }
                for index in blocks.indices {
                    let plannedBlock = blocks[index]
                    try Task.checkCancellation()
                    guard app.acousticVolumeSnapshot == volume,
                          (try app.profiles.profiles.first(where: { $0.id == profile.id })?.roomMeasurementContext()) == initial.context else { throw RoomCorrectionError.stale }
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
                    status = preview ? "Test Sound" : initial.source.kind == .recorder ? "Playing sound · Position \(positionIndex + 1) of \(initial.positions.count)"
                        : "Position \(positionIndex + 1) · Channel \(block.channel + 1)"
                    let playback = RoomMeasurementPlaybackCompletion()
                    guard app.playSpatialCalibration(context: context, clip: clip,
                        started: { playback.start(at: $0) }, completion: { playback.finish() }) else { throw RoomCorrectionError.routeUnavailable }
                    var tail = 0
                    for _ in 0..<140 {
                        try await Task.sleep(for: .milliseconds(100))
                        if let recorder {
                            microphoneLevel = recorder.inputLevel
                            if microphoneLevel?.clipped == true { throw RoomCorrectionError.inputClipped }
                            if recorder.hasDiscontinuity { throw AcousticMeasurementError.captureFailed }
                        }
                        guard app.acousticVolumeSnapshot == volume, app.isActive,
                              app.runtimeCoordinator.appliedProfile?.id == profile.id else { throw RoomCorrectionError.routeUnavailable }
                        if playback.isFinished { tail += 1 }
                        if tail >= 8 { break }
                    }
                    guard tail >= 8 else { throw RoomCorrectionError.routeUnavailable }
                    block.playbackStartTime = playback.startedAt; block.playbackClockID = playbackClockID
                    blocks[index] = block
                    if let recorder {
                        session.blocks.append(block)
                        let recording = await recorder.stop(); self.capture = nil
                        guard !recording.discontinuity else { throw AcousticMeasurementError.captureFailed }
                        let snapshot = session
                        let measuredBlock = block
                        session = try await worker {
                            var analyzed = try RoomMeasurementStore.analyze((recording.samples, recording.sampleRate, "wav", false), blocks: [measuredBlock], session: snapshot)
                            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID()).wav")
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            try RoomMeasurementStore.writeWAV(samples: recording.samples, sampleRate: recording.sampleRate, to: temporary)
                            let reference = try store.retain(temporary, sessionID: snapshot.id, blocks: [measuredBlock], format: "wav", isLossy: false)
                            analyzed.recordings.append(reference)
                            try store.save(analyzed)
                            return analyzed
                        }
                        self.session = session
                        saveReference(session)
                    }
                }
                try Task.checkCancellation()
                if !preview {
                    if initial.source.kind == .recorder { session = try completedRecorderPosition(blocks, in: initial) }
                    if let i = session.positions.firstIndex(where: { $0.id == position.id }) { session.positions[i].skipped = false }
                    let saved = session
                    try await worker { try store.save(saved) }
                    self.session = session; saveReference(session)
                    advanceAfterPlayback()
                } else { status = "" }
            } catch {
                if let capture { _ = await capture.stop(); self.capture = nil }
                app.endSpatialCalibration(id: context.id); self.context = nil
                if let latest = app.profiles.profiles.first(where: { $0.id == profile.id }) { await app.apply(profile: latest) }
                throw error
            }
            if let capture { _ = await capture.stop(); self.capture = nil }
            app.endSpatialCalibration(id: context.id); self.context = nil
            if let latest = app.profiles.profiles.first(where: { $0.id == profile.id }) { await app.apply(profile: latest) }
        }
    }
    func importRecording(_ url: URL) {
        guard let snapshot = session, !snapshot.blocks.isEmpty else { error = "Play the measurement positions before importing the recording."; return }
        let store = measurementStore
        run { [self] in
            status = "Analyzing recording…"
            session = try await worker {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let decoded = try RoomMeasurementStore.read(url)
                var clean = snapshot
                for i in clean.positions.indices { clean.positions[i].observations = [] }
                var result = try RoomMeasurementStore.analyze(decoded, blocks: snapshot.blocks, session: clean)
                var recording = try store.retain(url, sessionID: result.id, blocks: snapshot.blocks, format: decoded.format, isLossy: decoded.isLossy)
                recording.originalFileName = url.lastPathComponent
                result.recordings.append(recording)
                try store.save(result); return result
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
            try await worker { try store.save(detached) }
            session = detached; saveReference(detached)
            calculatedResult = nil
            status = ""; tab = .measure
        }
    }
    func reanalyze() {
        guard let snapshot = session else { return }
        let selectedSource = source
        let store = measurementStore
        run { [self] in
            status = "Reanalyzing saved recordings…"
            session = try await worker { try store.updatingSource(selectedSource, in: snapshot, force: true) }
            if let session { saveReference(session) }
            calculatedResult = nil; status = validationMessage
        }
    }
    func create(profile: DeviceProfile) {
        guard let snapshot = session else { return }
        let settings = settings
        let selectedSource = source
        let store = measurementStore
        run { [self] in
            let snapshot = try await worker { try store.updatingSource(selectedSource, in: snapshot) }
            self.session = snapshot
            if snapshot.source.kind == .microphone && !snapshot.microphoneMeasurementsComplete {
                throw RoomCorrectionError.incompleteMicrophoneMeasurement
            }
            guard let app else { return }
            let current = try app.applyingSessionEQDrafts(to: app.historyProfile(profile.id))
            let currentContext = try current.roomMeasurementContext()
            let sourceContext: RoomMeasurementContext
            if snapshot.context.canReprocess(to: currentContext) { sourceContext = currentContext }
            else if currentContext == importedContext, let importedMeasurementContext,
                    snapshot.context.canReprocess(to: importedMeasurementContext) { sourceContext = importedMeasurementContext }
            else { throw RoomCorrectionError.stale }
            status = "Calculating correction…"
            var rebased = snapshot; rebased.context = sourceContext
            let designSession = rebased
            let result = try await worker { try RoomMeasurementStore.materialize(RoomCorrectionDesigner().design(session: designSession, settings: settings)) }
            let latest = try app.applyingSessionEQDrafts(to: app.historyProfile(profile.id))
            guard (try latest.roomMeasurementContext()) == currentContext else { throw RoomCorrectionError.stale }
            try await validateCommit(current, app: app)
            calculatedResult = result; calculationRevision += 1; tab = .correction
            let reasons = Array(Set((result.channelDiagnostics ?? [:]).values.map(\.reason))).sorted()
            status = result.hasCorrection ? "" : "No correction: "
                + (reasons.isEmpty ? "the measurements do not support a safe improvement." : reasons.joined(separator: ". ") + ".")
        }
    }

    func replacementMessage(profile: DeviceProfile) throws -> String? {
        guard let app, let result = calculatedResult else { return nil }
        let current = try app.applyingSessionEQDrafts(to: app.historyProfile(profile.id))
        return try RoomCorrectionImportPlan(result: result, profile: current).replacementMessage(profile: current)
    }

    var canImport: Bool {
        calculatedResult?.hasCorrection == true && calculatedResult?.settings == settings && !busy
            && calculatedResult?.optimizerVersion == RoomCorrectionResult.currentOptimizerVersion
            && calculatedResult?.firGeneratorVersion == RoomCorrectionResult.currentFIRGeneratorVersion
    }

    func importCorrection(profile: DeviceProfile) {
        guard canImport, let result = calculatedResult else { return }
        run { [self] in
            guard let app, app.profiles.settingsMutationsAllowed else { throw ProfileSettingsError.busy }
            let saved = try app.historyProfile(profile.id)
            let current = try app.applyingSessionEQDrafts(to: saved)
            let context = try current.roomMeasurementContext()
            guard context == result.context || (context == importedContext && result.context == importedMeasurementContext) else { throw RoomCorrectionError.stale }
            let plan = try RoomCorrectionImportPlan(result: result, profile: current)
            let candidate = try plan.applying(to: current)
            status = "Importing correction…"
            _ = try await worker { try AudioRuntimePlanPreparer.prepareForStorage(profile: candidate, revision: .init(profileID: candidate.id, generation: 0)) }
            guard try app.historyProfile(profile.id) == saved,
                  (try app.applyingSessionEQDrafts(to: saved)) == current else { throw RoomCorrectionError.stale }
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
                    guard try app.historyProfile(profile.id) == saved,
                          (try app.applyingSessionEQDrafts(to: saved)) == current else { throw RoomCorrectionError.stale }
                } catch {
                    if app.isActive, app.activeProfileID == profile.id,
                       let latest = try? app.applyingSessionEQDrafts(to: app.historyProfile(profile.id)) {
                        await app.apply(profile: latest)
                    }
                    throw error
                }
            }
            app.profiles.update(candidate)
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
            app.profiles.update(current); comparing = false
            status = enabled ? "Room Correction ON" : "Room Correction OFF"
        }
    }
    func reset(profile: DeviceProfile) {
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
                app.profiles.update(current)
                loadedSeatID = current.effectiveSpatialSettings.seating?.id
            }
            // Detach saved bundles instead of deleting files that another seat
            // or profile may reference. Nothing from this session reloads here.
            session = nil; comparison = nil; drafts = [:]; draftVolumes = [:]
            calculatedResult = nil; importedContext = nil; importedMeasurementContext = nil
            volume = nil; context = nil; issuedTokens = []
            source = .init(); source.deviceID = microphones.first?.id
            settings = .init(); positionIndex = 0; recorderPositionCount = .five; microphonePositionCount = .nine
            microphoneLevel = nil
            testVolumeDB = 0; testVolumeMaximumDB = RoomMeasurementSignal.volumeRangeDB.upperBound
            testingSound = false; levelCheckCeilingDB = nil; comparing = false
            status = ""; error = nil; tab = .measure
        }
    }
    func clearCorrection(profile: DeviceProfile) {
        run { [self] in
            guard let app else { return }
            var current = app.profiles.profiles.first(where: { $0.id == profile.id }) ?? profile
            current.spatialSettings.seating?.roomCorrectionResult = nil
            current.spatialSettings.seating?.roomCorrectionBands = []
            current.spatialSettings.seating?.roomCorrectionEnabled = false
            current.processing.removeRoomStages()
            if app.activeProfileID == current.id {
                await app.apply(profile: current)
                guard app.runtimeCoordinator.appliedProfile?.effectiveSpatialSettings.seating?.roomCorrectionEnabled == false else { throw RoomCorrectionError.routeUnavailable }
            }
            try await validateCommit(current, app: app)
            app.profiles.update(current); comparing = false
            status = "Correction removed. Measurements retained."
        }
    }
    func compare(profile: DeviceProfile) {
        run { [self] in
            guard let app, app.activeProfileID == profile.id, !profile.roomCorrectionIsStale,
                  let result = profile.effectiveSpatialSettings.seating?.roomCorrectionResult else { throw RoomCorrectionError.routeUnavailable }
            if comparing { await app.apply(profile: profile); comparing = false; return }
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
            bypass.processing.global.stages.insert(.init(id: UUID(uuidString: "CA117B72-0000-4000-0003-000000000000")!, processor: .gain(.init(gainDB: gain))), at: 0)
            guard app.profiles.profiles.first(where: { $0.id == profile.id }) == profile else { throw RoomCorrectionError.stale }
            try Task.checkCancellation()
            await app.apply(profile: bypass)
            guard app.runtimeCoordinator.appliedProfile?.effectiveSpatialSettings.seating?.roomCorrectionEnabled == false else { throw RoomCorrectionError.routeUnavailable }
            try await validateCommit(bypass, app: app)
            comparing = true
        }
    }

    func cancel() {
        task?.cancel()
        if let context { app?.endSpatialCalibration(id: context.id) }
    }
    func close() {
        cancel(); endCompare()
    }
    func endCompare() {
        if comparing, let app, let current = app.profiles.profiles.first(where: { $0.id == profileID }) {
            comparing = false; Task { await app.apply(profile: current) }
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
