import CamiTuneDomain
import Combine
import Foundation

final class PerChannelValueState<Value: Equatable>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

final class PerChannelStatusState: ObservableObject {
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
        guard values != bands else { return }
        let oldByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let next = bands.map { band in
            if let existing = oldByID[band.id] {
                if existing.band != band { existing.band = band }
                return existing
            }
            return PerChannelBandState(band)
        }
        if items.map(\.id) != next.map(\.id) { items = next }
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

/// Only values exposed by Channel Processing affect its disclosure. In
/// particular, APO parsing can replace band IDs without changing any controls.
struct ChannelProcessingPresentationSnapshot: Equatable {
    let profileID: UUID
    let settings: [HistoryTarget: ChannelProcessingSettings]

    init(profile: DeviceProfile) throws {
        profileID = profile.id
        let processing = try profile.resolvedProcessing()
        var settings: [HistoryTarget: ChannelProcessingSettings] = [:]
        for channel in profile.configuredProcessingChannels {
            settings[.profileChannel(profile.id, channel.index)] = processing.settings(forChannel: channel.index) ?? .identity
        }
        for group in profile.configuredSpeakerGroups {
            settings[.profileGroup(profile.id, group.id)] = processing.settings(forGroup: group.id) ?? .identity
        }
        self.settings = settings
    }

    var hasProcessing: Bool {
        settings.values.contains {
            $0.gainDB != 0 || $0.delayMilliseconds != 0 || $0.limiterEnabled
                || !$0.simpleTone.isNeutral || $0.bands.contains(where: \.hasMeaningfulProcessing)
        }
    }

    static func sameSettings(_ lhs: ChannelProcessingSettings, _ rhs: ChannelProcessingSettings) -> Bool {
        lhs.gainDB == rhs.gainDB && lhs.delayMilliseconds == rhs.delayMilliseconds
            && lhs.limiterEnabled == rhs.limiterEnabled && lhs.simpleTone == rhs.simpleTone
            && lhs.bands.elementsEqual(rhs.bands) {
                $0.enabled == $1.enabled && $0.kind == $1.kind && $0.frequency == $1.frequency
                    && $0.gain == $1.gain && $0.q == $1.q && $0.bandwidth == $1.bandwidth
                    && $0.isLocked == $1.isLocked
            }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profileID == rhs.profileID && lhs.settings.count == rhs.settings.count
            && lhs.settings.allSatisfy { target, value in
                rhs.settings[target].map { sameSettings(value, $0) } == true
            }
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
    // Loading default controls is presentation, not an edit. Merely selecting
    // another channel must not serialize defaults or publish a profile change.
    var persistedSnapshot: PerChannelEditorSnapshot?
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

    func updateStatus(presentation: EqualizerPresentation = .both) {
        let canReset = EqualizerReset.channel(snapshot, presentation: presentation) != snapshot
        if status.canReset != canReset {
            status.canReset = canReset
        }
    }

    deinit {
        liveApplyTask?.cancel()
        responseCalculationTask?.cancel()
    }
}
