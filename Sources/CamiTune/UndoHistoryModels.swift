import Foundation

enum HistoryTarget: Hashable, Sendable {
    case profile(UUID), profileChannel(UUID, Int), application(String)
    case applicationPresentation(String), applicationPresentationDocument, profileOrganization
    case referenceCorrection(UUID), speakerSystem(UUID)
    case profileGroup(UUID, SpeakerGroupID)
}

struct GlobalEQHistoryState: Equatable, Sendable {
    var preampDB: Double
    var bands: [EQBand]
    var limiterEnabled: Bool
    var simpleTone: SimpleToneSettings
    var replacesDeviceCorrection: Bool
    var deviceCorrectionProvenance: DeviceCorrectionProfile?
    var deviceCorrection: DeviceCorrectionProfile? = nil
}
struct CrossfeedHistoryState: Equatable, Sendable {
    var processor: CrossfeedProcessor
    var isEnabled: Bool
}
struct ConvolutionHistoryState: Equatable, Sendable {
    var processor: ConvolutionProcessor?
    var isEnabled: Bool
}
struct AppPlacementHistoryState: Equatable, Sendable {
    var orderedApplicationIDs: [String]
    var hiddenByApplicationID: [String: Bool]
}
struct ProfileOrganizationHistoryState: Equatable, Sendable {
    var orderedProfileIDs: [UUID]
    var folders: [ProfileFolder]
    var rootOrder: [ProfileRootItem]
}
struct SpeakerSystemHistoryState: Equatable, Sendable {
    var topology: SpeakerTopology?
    var seat: SpatialSeatingCalibration?
}
struct ReferenceTransferHistoryState: Equatable, Sendable {
    var correction: DeviceCorrectionProfile?
    var globalEQ: GlobalEQHistoryState
    var sectionLayout: ProfileSectionLayout?
}
struct ProfileDeletionSnapshot: Equatable, Sendable {
    var profiles: [DeviceProfile]
    var folderID: UUID?
    var organization: ProfileOrganizationHistoryState
    var physicalDeviceDefaults: [PhysicalDeviceDefaultProfile]
    var selectedProfileID: UUID?
}
enum HistoryState: Equatable, Sendable {
    case globalEQ(GlobalEQHistoryState), channel(PerChannelEditorSnapshot)
    case crossfeed(CrossfeedHistoryState), convolution(ConvolutionHistoryState)
    case perAppAudio(PerAppAudioSettings), perAppBatch([String: PerAppAudioSettings])
    case appAlias(String?), appPlacement(AppPlacementHistoryState)
    case deletion(ProfileDeletionSnapshot, deleted: Bool)
    case profileName(String), profileOrganization(ProfileOrganizationHistoryState)
    case referenceCorrection(DeviceCorrectionProfile?), referenceTransfer(ReferenceTransferHistoryState)
    case speakerSystem(SpeakerSystemHistoryState)
    case multichannel(MultichannelHistoryState)
}
struct HistoryCoalescingKey: Hashable, Sendable {
    var target: HistoryTarget
    var control: String
}
typealias GestureKey = HistoryCoalescingKey
struct HistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let actionName: String
    let contextName: String?
    let target: HistoryTarget
    let before: HistoryState
    var after: HistoryState
    let coalescingKey: HistoryCoalescingKey?
    var timestamp: Date
    var title: String { actionName + (contextName.map { " — " + $0 } ?? "") }
}
enum HistoryRestoreError: LocalizedError {
    case invalidStateForTarget, missingProfile, invalidOrganization, busy
    var errorDescription: String? {
        switch self {
        case .invalidStateForTarget: return "The undo state does not match its target."
        case .missingProfile: return "The profile for this edit is no longer available."
        case .invalidOrganization: return "The profile organization has changed and cannot be restored."
        case .busy: return "Finish the current profile operation before undoing this edit."
        }
    }
}

extension GlobalEQHistoryState {
    func numericControl(changedFrom before: Self) -> String? {
        var candidate = before
        candidate.preampDB = preampDB
        if candidate == self { return "preamp" }
        candidate = before; candidate.simpleTone = simpleTone
        if candidate == self {
            let changed = [("bass", before.simpleTone.bassDB != simpleTone.bassDB),
                           ("mids", before.simpleTone.midsDB != simpleTone.midsDB),
                           ("treble", before.simpleTone.trebleDB != simpleTone.trebleDB)].filter { $0.1 }
            return changed.count == 1 ? "tone." + changed[0].0 : nil
        }
        guard bands.count == before.bands.count else { return nil }
        let indices = bands.indices.filter { bands[$0] != before.bands[$0] }
        guard indices.count == 1, let index = indices.first else { return nil }
        for field in ["gain", "frequency", "q"] {
            candidate = before
            switch field {
            case "gain": candidate.bands[index].gain = bands[index].gain
            case "frequency": candidate.bands[index].frequency = bands[index].frequency
            default: candidate.bands[index].q = bands[index].q
            }
            if candidate == self { return "band.\(bands[index].id).\(field)" }
        }
        return nil
    }
}

extension PerChannelEditorSnapshot {
    func numericControl(changedFrom before: Self) -> String? {
        if gainDB == before.gainDB, bands == before.bands, limiterEnabled == before.limiterEnabled,
           simpleTone == before.simpleTone, delayMilliseconds != before.delayMilliseconds { return "delay" }
        guard delayMilliseconds == before.delayMilliseconds else { return nil }
        let previous = GlobalEQHistoryState(preampDB: before.gainDB, bands: before.bands, limiterEnabled: before.limiterEnabled,
            simpleTone: before.simpleTone, replacesDeviceCorrection: false, deviceCorrectionProvenance: nil)
        let current = GlobalEQHistoryState(preampDB: gainDB, bands: bands, limiterEnabled: limiterEnabled,
            simpleTone: simpleTone, replacesDeviceCorrection: false, deviceCorrectionProvenance: nil)
        return current.numericControl(changedFrom: previous)
    }
}
