import Foundation

package struct RenderConfiguration: Codable, Hashable, Sendable {
    package let revision: RuntimeIntentRevision
    package var playbackMode: PlaybackMode
    package var spatialRenderingMode: SpatialRenderingMode
    package var spatialSettings: SpatialRenderSettings
    package var spatialOutput: SpatialOutputKind
    package var spatialListenerTuning: SpatialListenerTuning
    package var spatialContentMode: SpatialContentMode
    package var virtualSurroundLayout: VirtualSurroundLayout
    package var referenceCorrection: DeviceCorrectionProfile?

    package init(profile: DeviceProfile, revision: RuntimeIntentRevision) {
        self.revision = revision
        playbackMode = profile.playbackMode
        spatialRenderingMode = profile.effectiveSpatialRenderingMode
        spatialSettings = profile.effectiveSpatialSettings
        spatialOutput = spatialSettings.resolvedOutput(deviceName: profile.outputDeviceName)
        spatialListenerTuning = profile.spatialListenerTuning.validated
        spatialContentMode = profile.spatialContentMode
        virtualSurroundLayout = profile.virtualSurroundLayout
        referenceCorrection = profile.personalReferenceCorrection
    }

}

package struct RuntimeHardwareEvidence: Hashable, Sendable {
    package init(
        output: PhysicalOutputIdentity,
        sampleRate: Int,
        physicalChannelCount: Int,
        speakerTopology: SpeakerTopology? = nil,
        fingerprint: HardwareTopologyFingerprint,
        simulated: Bool
    ) {
        self.output = output
        self.sampleRate = sampleRate
        self.physicalChannelCount = physicalChannelCount
        self.speakerTopology = speakerTopology
        self.fingerprint = fingerprint
        self.simulated = simulated
    }

    package let output: PhysicalOutputIdentity
    package let sampleRate: Int
    package let physicalChannelCount: Int
    package let speakerTopology: SpeakerTopology?
    package let fingerprint: HardwareTopologyFingerprint
    package let simulated: Bool
}

package struct PreparedRuntimeInputs: Sendable {
    package init(
        revision: RuntimeIntentRevision,
        preparedAt: Date,
        profile: DeviceProfile,
        hardware: RuntimeHardwareEvidence,
        assets: PreparedRuntimeAssets,
        deliveryConfiguration: PCMDeliveryConfiguration? = nil
    ) {
        self.revision = revision
        self.preparedAt = preparedAt
        self.profile = profile
        self.hardware = hardware
        self.assets = assets
        self.deliveryConfiguration = deliveryConfiguration
    }

    package let revision: RuntimeIntentRevision
    package let preparedAt: Date
    package let profile: DeviceProfile
    package let hardware: RuntimeHardwareEvidence
    package let assets: PreparedRuntimeAssets
    package var deliveryConfiguration: PCMDeliveryConfiguration? = nil
}

package struct RuntimePlanMetadata: Hashable, Sendable {
    package init(profileDisplayName: String, endpointDisplayName: String) {
        self.profileDisplayName = profileDisplayName
        self.endpointDisplayName = endpointDisplayName
    }

    package let profileDisplayName: String
    package let endpointDisplayName: String
}

package struct AudioRuntimePlan: Hashable, Sendable {
    package init(
        revision: RuntimeIntentRevision,
        preparedAt: Date,
        intent: DeviceProfile,
        metadata: RuntimePlanMetadata,
        sourceFormat: AudioFormatDescriptor,
        dspInputFormat: AudioFormatDescriptor,
        physicalEndpointFormat: AudioFormatDescriptor,
        hardwareOutputFormat: AudioFormatDescriptor,
        profileRoutingDescriptor: ProfileRoutingDescriptor,
        route: ActiveAudioRoute,
        processingGraph: ProcessingGraph,
        deliveryConfiguration: PCMDeliveryConfiguration,
        renderConfiguration: RenderConfiguration,
        playbackContext: PerAppPlaybackContext,
        referenceTopology: SpeakerTopology? = nil,
        hardwareEvidence: RuntimeHardwareEvidence,
        assets: PreparedRuntimeAssets
    ) {
        self.revision = revision
        self.preparedAt = preparedAt
        self.intent = intent
        self.metadata = metadata
        self.sourceFormat = sourceFormat
        self.dspInputFormat = dspInputFormat
        self.physicalEndpointFormat = physicalEndpointFormat
        self.hardwareOutputFormat = hardwareOutputFormat
        self.profileRoutingDescriptor = profileRoutingDescriptor
        self.route = route
        self.processingGraph = processingGraph
        self.deliveryConfiguration = deliveryConfiguration
        self.renderConfiguration = renderConfiguration
        self.playbackContext = playbackContext
        self.referenceTopology = referenceTopology
        self.hardwareEvidence = hardwareEvidence
        self.assets = assets
    }

    package let revision: RuntimeIntentRevision
    package let preparedAt: Date
    package let intent: DeviceProfile
    package let metadata: RuntimePlanMetadata
    package let sourceFormat: AudioFormatDescriptor
    package let dspInputFormat: AudioFormatDescriptor
    package let physicalEndpointFormat: AudioFormatDescriptor
    package let hardwareOutputFormat: AudioFormatDescriptor
    package let profileRoutingDescriptor: ProfileRoutingDescriptor
    package let route: ActiveAudioRoute
    package let processingGraph: ProcessingGraph
    package let deliveryConfiguration: PCMDeliveryConfiguration
    package let renderConfiguration: RenderConfiguration
    package let playbackContext: PerAppPlaybackContext
    package let referenceTopology: SpeakerTopology?
    package let hardwareEvidence: RuntimeHardwareEvidence
    package let assets: PreparedRuntimeAssets
    package var hardwareFingerprint: HardwareTopologyFingerprint { hardwareEvidence.fingerprint }
}

package struct AudioRuntimePlanCompiler {
    package init() {}

    package func compile(_ input: PreparedRuntimeInputs) throws -> AudioRuntimePlan {
        let profile = input.profile; let hardware = input.hardware
        guard input.revision.profileID == profile.id,
              profile.outputDeviceUID == hardware.output.uid,
              profile.sampleRate == hardware.sampleRate,
              profile.configuredPhysicalChannelCount == hardware.physicalChannelCount,
              hardware.fingerprint.deviceUID == hardware.output.uid,
              hardware.fingerprint.channelCount == hardware.physicalChannelCount else {
            throw SpeakerTopologyError.hardwareLayoutChanged
        }
        if let detected = hardware.speakerTopology {
            guard try HardwareTopologyFingerprint(topology: detected) == hardware.fingerprint else {
                throw SpeakerTopologyError.hardwareLayoutChanged
            }
        }
        let topology = try profile.validatedPhysicalSpeakerTopology()
        let assignment = try profile.validatedInterfaceConfiguration()
        if topology != nil || assignment != nil {
            guard let detected = hardware.speakerTopology else { throw SpeakerTopologyError.hardwareLayoutChanged }
            try topology?.validateHardware(detected)
            try profile.validateMultichannelHardware(detected)
            if let assignment, assignment.hardwareChannelCount != detected.declaredChannelCount {
                throw SpeakerTopologyError.hardwareLayoutChanged
            }
        }
        let route = try ActiveAudioRoute(profile: profile)
        var graph = try route.buildGraph(profile: profile, assets: input.assets)
        let delivery = input.deliveryConfiguration
            ?? .standard(sampleRate: Double(graph.sampleRate), chunkSize: graph.chunkSize)
        guard delivery.queue.isValid, delivery.queue.sampleRate == Double(graph.sampleRate),
              (1...64).contains(delivery.camillaQueueLimit) else {
            throw AudioRouteFormatError.incompatibleOutput
        }
        graph.camillaQueueLimit = delivery.camillaQueueLimit
        guard let descriptor = ProfileRoutingDescriptor.descriptors(for: [profile])[profile.id] else {
            throw AudioRouteFormatError.incompatibleOutput
        }
        let endpoints = profile.configuredProcessingChannels.map {
            SpeakerEndpoint(id: $0.physicalOutputID, role: $0.role, displayName: $0.displayName, connectionState: .confirmedByUser)
        }
        return AudioRuntimePlan(revision: input.revision, preparedAt: input.preparedAt, intent: profile,
            metadata: .init(profileDisplayName: profile.name, endpointDisplayName: descriptor.name),
            sourceFormat: route.sourceFormat, dspInputFormat: route.dspInputFormat,
            physicalEndpointFormat: try .physicalEndpoints(sampleRate: profile.sampleRate, endpoints: endpoints),
            hardwareOutputFormat: route.hardwareOutputFormat, profileRoutingDescriptor: descriptor, route: route,
            processingGraph: graph, deliveryConfiguration: delivery,
            renderConfiguration: .init(profile: profile, revision: input.revision),
            playbackContext: .init(profile: profile), referenceTopology: topology,
            hardwareEvidence: hardware, assets: input.assets)
    }
}
