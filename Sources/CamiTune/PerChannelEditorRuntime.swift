import Combine
import Foundation

final class PerChannelValueState<Value: Equatable>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

final class PerChannelStatusState: ObservableObject {
    @Published var isSaved = true
    @Published var canReset = false
}

final class PerChannelResponseState: ObservableObject {
    @Published var filterResponse: [EQResponsePoint] = []
    @Published var totalResponse: [EQResponsePoint] = []
}

final class PerChannelBandState: ObservableObject, Identifiable {
    let id: UUID
    @Published var band: EQBand

    init(_ band: EQBand) {
        id = band.id
        self.band = band
    }
}

final class PerChannelBandsState: ObservableObject {
    /// Only structural changes publish here. Editing gain/Q/type/enabled mutates
    /// the individual PerChannelBandState, so one slider does not invalidate the
    /// entire EQ strip or its parent editor.
    @Published private(set) var items: [PerChannelBandState] = []

    var count: Int { items.count }
    var values: [EQBand] { items.map(\.band) }
    var isEmpty: Bool { items.isEmpty }

    func replace(with bands: [EQBand]) {
        let oldByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = bands.map { band in
            if let existing = oldByID[band.id] {
                existing.band = band
                return existing
            }
            return PerChannelBandState(band)
        }
    }

    func commitFrequency(_ frequency: Double, for bandID: UUID) {
        guard frequency.isFinite, frequency > 0,
              let item = items.first(where: { $0.id == bandID }),
              item.band.frequency != frequency else { return }

        var updated = item.band
        updated.frequency = frequency
        item.band = updated
    }
}

struct PerChannelEditorSnapshot: Equatable, Sendable {
    let gainDB: Double
    let delayMilliseconds: Double
    let limiterEnabled: Bool
    let bands: [EQBand]
    var simpleTone = SimpleToneSettings()

    var processingSettings: ChannelProcessingSettings {
        .init(gainDB: gainDB, bands: bands, delayMilliseconds: delayMilliseconds,
            limiterEnabled: limiterEnabled, simpleTone: simpleTone)
    }

    var canReset: Bool {
        gainDB != 0 || delayMilliseconds != 0 || limiterEnabled || !bands.isEmpty || !simpleTone.isNeutral
    }
}

/// Non-visual editor coordination. The runtime itself intentionally has no
/// @Published editor values. Each piece of UI observes only its small state
/// object, preventing a band drag from rebuilding the whole per-channel panel.
@MainActor
final class PerChannelEditorRuntime: ObservableObject {
    let gain = PerChannelValueState<Double>(0)
    let delay = PerChannelValueState<Double>(0)
    let limiter = PerChannelValueState<Bool>(false)
    let simpleTone = PerChannelValueState(SimpleToneSettings())
    let bands = PerChannelBandsState()
    let responses = PerChannelResponseState()
    let status = PerChannelStatusState()

    var historyActionName: String?
    var historyBaseline: PerChannelEditorSnapshot?
    var suppressChanges = false
    var liveApplyTask: Task<Void, Never>?
    var responseCalculationTask: Task<Void, Never>?
    var loadedProfileID: UUID?
    var loadedChannelIndex: Int?
    var loadedGroupID: SpeakerGroupID?

    /// Continuous slider gestures keep expensive serialization/DSP work parked
    /// until pointer-up. Text fields, menus, toggles, and band-count edits still
    /// use the normal idle debounce.
    var continuousEditDepth = 0
    var commitPendingAfterContinuousEdit = false

    var snapshot: PerChannelEditorSnapshot {
        PerChannelEditorSnapshot(
            gainDB: gain.value,
            delayMilliseconds: delay.value,
            limiterEnabled: limiter.value,
            bands: bands.values,
            simpleTone: simpleTone.value
        )
    }

    func updateStatus(isSaved: Bool? = nil) {
        if let isSaved, status.isSaved != isSaved {
            status.isSaved = isSaved
        }
        let canReset = snapshot.canReset
        if status.canReset != canReset {
            status.canReset = canReset
        }
    }

    deinit {
        liveApplyTask?.cancel()
        responseCalculationTask?.cancel()
    }
}
