import Foundation

/// Resource-private, ephemeral HAL bindings. Never persisted, planned, or exposed to SwiftUI.
/// Stable UIDs identify devices; object IDs expire across graph mutations.
struct CoreAudioRuntimeBinding: Equatable, Sendable {
    let bridge: AudioDeviceInfo
    let routing: AudioDeviceInfo
    let physical: AudioDeviceInfo
    let graphGeneration: UInt64
    func hasSameObjects(as other: Self) -> Bool {
        bridge.id == other.bridge.id && bridge.objectID == other.bridge.objectID
            && routing.id == other.routing.id && routing.objectID == other.routing.objectID
            && physical.id == other.physical.id && physical.objectID == other.physical.objectID
    }
}

struct CoreAudioEndpointPublicationReceipt: Equatable, Sendable {
    let graphGeneration: UInt64
    let objectGraphMayHaveChanged: Bool
    var visibilityWaits: [CoreAudioWaitResult] = []
}
