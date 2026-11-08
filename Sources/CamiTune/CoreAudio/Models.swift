import CamiTuneDomain
import Foundation
import CoreAudio

struct AggregateOutputMember: Hashable, Sendable {
    let uid: String
    let outputChannelCount: Int
}

struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String          // CoreAudio UID
    let objectID: UInt32
    let name: String
    let transportType: UInt32
    let aggregateMembers: [AggregateOutputMember]

    static let systemAudioBridgeName = "System Audio Bridge"
    static let systemAudioBridgeUID = "local.systemaudiobridge.device"

    init(id: String, objectID: UInt32, name: String, transportType: UInt32 = 0,
         aggregateMembers: [AggregateOutputMember] = []) {
        self.id = id
        self.objectID = objectID
        self.name = name
        self.transportType = transportType
        self.aggregateMembers = aggregateMembers
    }

    var isRoutingDevice: Bool {
        Self.isCaptureUID(id) || aggregateMembers.contains { Self.isCaptureUID($0.uid) }
    }

    /// Creating a software endpoint is not a request to change the user's route.
    var selectsOnConnection: Bool {
        !isRoutingDevice && transportType != kAudioDeviceTransportTypeAggregate && transportType != kAudioDeviceTransportTypeVirtual
    }

    private static func isCaptureUID(_ uid: String) -> Bool {
        uid == systemAudioBridgeUID || ProfileRoutingDescriptor.isProfileRoutingUID(uid)
    }

    var hardwareOutputIDs: [PhysicalOutputID]? {
        guard transportType == kAudioDeviceTransportTypeAggregate else { return nil }
        return aggregateMembers.flatMap { member in
            (0..<member.outputChannelCount).map { PhysicalOutputID(deviceUID: member.uid, channelIndex: $0) }
        }
    }
}

struct SpectrumPoint: Identifiable, Equatable {
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
