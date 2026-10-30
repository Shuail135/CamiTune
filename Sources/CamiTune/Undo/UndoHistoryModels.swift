import CamiTuneDomain
import Foundation

enum HistoryTarget: Hashable, Sendable {
    case autoEQ(UUID, ProfileEndpointKind), speakerAutoEQ(UUID)
    case globalSettings, preference(AppHistoryPreference)
    case scopedAppPresentation(String, PerAppSettingsScope), scopedAppPresentationDocument(PerAppSettingsScope)
    case scopedApplication(String, PerAppSettingsScope), scopedApplications(PerAppSettingsScope)
    case profile(UUID), profileChannel(UUID, Int), application(String)
    case applicationPresentation(String), applicationPresentationDocument, profileOrganization
    case referenceCorrection(UUID), speakerSystem(UUID)
    case profileGroup(UUID, SpeakerGroupID)
    case plugin(UUID, UUID)
}

enum AppHistoryPreference: Hashable, Sendable {
    case appearance, closingReminder, enabledExplanation, automaticUpdates, notifications, loginStartup
}

struct ProfileSettingsHistoryState: Equatable, Sendable {
    var profile: DeviceProfile
    var replacing: DeviceProfile
    var routing: ProfileRoutingHistoryState
}

struct ProfileRoutingHistoryState: Equatable, Sendable {
    var defaults: [PhysicalDeviceDefaultProfile]
    var outputUIDs: Set<String>
    var autoActivation: [UUID: Bool]
}

struct ProfileLayoutHistoryState: Equatable, Sendable {
    var profileID: UUID
    var layout: ProfileSectionLayout?
}

struct AudioBufferHistoryState: Equatable, Sendable {
    var defaultValue: AudioBufferSetting
    var overrides: [UUID: AudioBufferSetting?]
}

struct GlobalEQHistoryState: Equatable, Sendable {
    var preampDB: Double
    var bands: [EQBand]
    var limiterEnabled: Bool
    var simpleTone: SimpleToneSettings
    var replacesDeviceCorrection: Bool
    var deviceCorrectionProvenance: DeviceCorrectionProfile?
    var deviceCorrection: DeviceCorrectionProfile? = nil
    var ownsLegacyCorrectionTransfer = false
    var sectionLayout: ProfileSectionLayout? = nil
    var ownsSectionLayout = false
}
struct CrossfeedHistoryState: Equatable, Sendable {
    var processor: CrossfeedProcessor
    var isEnabled: Bool
}
struct ConvolutionHistoryState: Equatable, Sendable {
    var processor: ConvolutionProcessor?
    var isEnabled: Bool
}
struct RoomCorrectionImportHistoryState: Equatable, Sendable {
    var channels: [Int: ProcessingChain]
    var seat: SpatialSeatingCalibration?
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
    var bass = BassManagementSettings()
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
    case autoEQDraft(AutoEQEditorDraft), speakerAutoEQDraft(SpeakerAutoEQEditorDraft)
    case profileSettings(ProfileSettingsHistoryState), profileEnabled(Bool)
    case routing(ProfileRoutingHistoryState)
    case defaultLayout(ProfileEndpointKind, ProfileSectionLayout), profileLayouts([ProfileLayoutHistoryState])
    case globalAudioBuffer(AudioBufferHistoryState)
    case boolean(Bool), appearance(String)
    case appAudioScope(usesGlobal: Bool)
    case personalSpatial(context: String, settings: PersonalSpatialSettings)
    case pluginOrder([UUID])
    case pluginRack(PluginRack)
    case pluginMIDI(PluginMIDIConfiguration)
    case pluginState(Data?)
    case equalizerPresentation(EqualizerPresentation)
    case audioBuffer(AudioBufferSetting?)
    case deviceCorrection(DeviceCorrectionProfile?)
    case globalEQ(GlobalEQHistoryState), channel(PerChannelEditorSnapshot)
    case crossfeed(CrossfeedHistoryState), convolution(ConvolutionHistoryState)
    case convolutionBatch([Int: ConvolutionHistoryState])
    case roomCorrectionImport(RoomCorrectionImportHistoryState)
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
struct HistoryPosition: Hashable, Comparable, Sendable {
    let ordinal: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.ordinal < rhs.ordinal }
}
struct HistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let position: HistoryPosition
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

extension HistoryState {
    var assetReferences: ProfileAssetReferences {
        var references = ProfileAssetReferences()
        switch self {
        case .convolution(let value):
            if let processor = value.processor { references.include(processor) }
        case .convolutionBatch(let values):
            for value in values.values {
                if let processor = value.processor { references.include(processor) }
            }
        case .roomCorrectionImport(let value):
            for chain in value.channels.values { references.include(chain) }
            if let seat = value.seat { references.include(seat) }
        case .speakerSystem(let value):
            if let seat = value.seat { references.include(seat) }
        case .deletion(let value, _):
            references = .init(profiles: value.profiles)
        case .profileSettings(let value):
            references = .init(profiles: [value.profile, value.replacing])
        case .autoEQDraft, .speakerAutoEQDraft, .profileEnabled, .routing,
             .defaultLayout, .profileLayouts, .globalAudioBuffer, .boolean, .appearance, .appAudioScope:
            break
        case .personalSpatial, .pluginOrder, .pluginRack, .pluginMIDI, .pluginState, .equalizerPresentation, .audioBuffer,
             .deviceCorrection, .globalEQ, .channel, .crossfeed, .perAppAudio, .perAppBatch,
             .appAlias, .appPlacement, .profileName, .profileOrganization,
             .referenceCorrection, .referenceTransfer, .multichannel:
            break
        }
        return references
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
