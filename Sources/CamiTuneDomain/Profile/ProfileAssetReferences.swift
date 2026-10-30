import Foundation

/// All restorable assets, including disabled stages and unselected seats.
/// Runtime resolution intentionally omits some of these saved values.
package struct ProfileAssetReferences: Equatable, Sendable {
    package var profileIDs: Set<UUID> = []
    package var impulseResponses: Set<String> = []
    package var roomSessions: Set<UUID> = []
    package var roomRecordings: [UUID: Set<String>] = [:]

    package init() {}
    package init(profiles: [DeviceProfile]) {
        for profile in profiles { include(profile) }
    }
    package mutating func formUnion(_ other: Self) {
        profileIDs.formUnion(other.profileIDs)
        impulseResponses.formUnion(other.impulseResponses)
        roomSessions.formUnion(other.roomSessions)
        for (id, names) in other.roomRecordings { roomRecordings[id, default: []].formUnion(names) }
    }
    package mutating func include(_ profile: DeviceProfile) {
        profileIDs.insert(profile.id)
        include(profile.processing)
        for chain in profile.physicalChannelProcessing.values { include(chain) }
        for seat in profile.spatialSettings.listeningPositions { include(seat) }
        if let acoustic = profile.spatialAcousticProfile { include(acoustic.processing) }
        for configuration in profile.deviceTypeConfigurations.values {
            include(configuration.processing)
            for chain in configuration.physicalChannels.values { include(chain) }
            for seat in configuration.spatialSettings.listeningPositions { include(seat) }
            if let acoustic = configuration.acoustic { include(acoustic.processing) }
        }
    }
    package mutating func include(_ processing: ProcessingProfile) {
        include(processing.global)
        for channel in processing.channels { include(channel.chain) }
        for group in processing.groups { include(group.chain) }
    }
    package mutating func include(_ chain: ProcessingChain) {
        for stage in chain.stages {
            if case .convolution(let convolution) = stage.processor { include(convolution) }
        }
    }
    package mutating func include(_ convolution: ConvolutionProcessor) {
        impulseResponses.insert(convolution.asset.fileName)
    }
    package mutating func include(_ seat: SpatialSeatingCalibration) {
        if let id = seat.roomCorrectionSessionID { roomSessions.insert(id) }
        if let result = seat.roomCorrectionResult { include(result) }
    }
    package mutating func include(_ result: RoomCorrectionResult) {
        include(result.context)
        roomSessions.insert(result.sessionID)
        if let verification = result.verification { roomSessions.insert(verification.sessionID) }
        for convolution in result.channelFIR.values { include(convolution) }
        if let chains = result.importedChannelChains {
            for chain in chains.values { include(chain) }
        }
        if let identity = result.measurementIdentity {
            roomRecordings[result.sessionID, default: []].formUnion(identity.recordings)
        }
    }
    package mutating func include(_ session: RoomMeasurementSession) {
        include(session.context)
        roomSessions.insert(session.id)
        roomRecordings[session.id, default: []].formUnion(session.recordings.map(\.fileName))
    }
    private mutating func include(_ context: RoomMeasurementContext) {
        include(context.processing)
        if let baseline = context.importBaselineProcessing { include(baseline) }
    }
}
