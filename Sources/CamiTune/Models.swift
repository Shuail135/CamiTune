import CamiTuneDomain
import Foundation
import CoreAudio

struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String          // CoreAudio UID
    let objectID: UInt32
    let name: String
    let transportType: UInt32

    static let systemAudioBridgeName = "System Audio Bridge"
    static let systemAudioBridgeUID = "local.systemaudiobridge.device"

    init(id: String, objectID: UInt32, name: String, transportType: UInt32 = 0) {
        self.id = id
        self.objectID = objectID
        self.name = name
        self.transportType = transportType
    }

    var isRoutingDevice: Bool {
        id == Self.systemAudioBridgeUID ||
            ProfileRoutingDescriptor.isProfileRoutingUID(id) ||
            transportType == kAudioDeviceTransportTypeAggregate ||
            transportType == kAudioDeviceTransportTypeVirtual
    }
}

struct SpectrumPoint: Identifiable {
    let frequency: Double
    let db: Double
    var id: Double { frequency }
}

/// Shared by the runtime adapter and failure-injection tests. Persistence is the
/// final fallible commit, and failed application/commit rolls back the runtime.
@MainActor
enum ProfileSettingsTransaction {
    static func run(preflight: () async throws -> Void,
                    apply: () async throws -> Void,
                    commit: () throws -> Void,
                    rollback: () async throws -> Void) async throws {
        try await preflight()
        do {
            try await apply()
            try commit()
        } catch {
            let failure = error
            do { try await rollback() }
            catch { throw ProfileSettingsError.rollback(failure.localizedDescription, error.localizedDescription) }
            throw failure
        }
    }
}
