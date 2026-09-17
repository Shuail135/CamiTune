import Foundation

struct RuntimeIntentRevision: Codable, Hashable, Sendable {
    let profileID: UUID
    let generation: UInt64
}

/// Effective renderer values from exactly one intent snapshot. Live gain and
/// temporary calibration overlays deliberately have separate owners.
struct RenderConfiguration: Codable, Hashable, Sendable {
    let revision: RuntimeIntentRevision
    var playbackMode: PlaybackMode
    var spatialRenderingMode: SpatialRenderingMode
    var spatialSettings: SpatialRenderSettings
    var spatialOutput: SpatialOutputKind
    var spatialListenerTuning: SpatialListenerTuning
    var spatialContentMode: SpatialContentMode
    var virtualSurroundLayout: VirtualSurroundLayout
    var referenceCorrection: DeviceCorrectionProfile?

    init(profile: DeviceProfile, revision: RuntimeIntentRevision) {
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

    // Compatibility for isolated renderer fixtures; runtime paths use plans.
    init(mode: SpatialRenderingMode = .standard, tuning: SpatialListenerTuning = .neutral,
         content: SpatialContentMode = .automatic, settings: SpatialRenderSettings = .init(),
         output: SpatialOutputKind = .speakers, playback: PlaybackMode = .direct,
         correction: DeviceCorrectionProfile? = nil) {
        revision = .init(profileID: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), generation: 0)
        spatialRenderingMode = mode == .standard ? .standard : .spatialAudio
        spatialListenerTuning = tuning.validated; spatialContentMode = content
        spatialSettings = settings
        if mode == .frontStage || mode == .virtualSurround { spatialSettings.enabled = true }
        spatialOutput = output; playbackMode = playback; referenceCorrection = correction
        virtualSurroundLayout = .standard
    }
}

struct RuntimeHardwareEvidence: Hashable, Sendable {
    let output: PhysicalOutputIdentity
    let sampleRate: Int
    let physicalChannelCount: Int
    let speakerTopology: SpeakerTopology?
    let fingerprint: HardwareTopologyFingerprint
    let simulated: Bool
}

struct PreparedRuntimeInputs: Sendable {
    let revision: RuntimeIntentRevision
    let preparedAt: Date
    let profile: DeviceProfile
    let hardware: RuntimeHardwareEvidence
    let assets: PreparedRuntimeAssets
}

struct RuntimePlanMetadata: Hashable, Sendable {
    let profileDisplayName: String
    let endpointDisplayName: String
}

/// Prepare once. Compile once. Execute this plan without reinterpreting intent.
/// The intent snapshot is retained for diagnostics and endpoint publication only.
struct AudioRuntimePlan: Hashable, Sendable {
    let revision: RuntimeIntentRevision
    let preparedAt: Date
    let intent: DeviceProfile
    let metadata: RuntimePlanMetadata
    let sourceFormat: AudioFormatDescriptor
    let dspInputFormat: AudioFormatDescriptor
    let physicalEndpointFormat: AudioFormatDescriptor
    let hardwareOutputFormat: AudioFormatDescriptor
    let profileRoutingDescriptor: ProfileRoutingDescriptor
    let route: ActiveAudioRoute
    let processingGraph: ProcessingGraph
    let renderConfiguration: RenderConfiguration
    let playbackContext: PerAppPlaybackContext
    let referenceTopology: SpeakerTopology?
    let hardwareEvidence: RuntimeHardwareEvidence
    let assets: PreparedRuntimeAssets
    var hardwareFingerprint: HardwareTopologyFingerprint { hardwareEvidence.fingerprint }
}

/// Pure derivation: no hardware provider, filesystem resolver, RPC, or store.
struct AudioRuntimePlanCompiler {
    func compile(_ input: PreparedRuntimeInputs) throws -> AudioRuntimePlan {
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
        let graph = try route.buildGraph(profile: profile, assets: input.assets)
        guard let descriptor = ProfileRoutingDescriptor.descriptors(for: [profile])[profile.id] else {
            throw AudioRouteFormatError.incompatibleOutput
        }
        _ = try descriptor.formatPayload()
        let endpoints = profile.configuredProcessingChannels.map {
            SpeakerEndpoint(id: $0.physicalOutputID, role: $0.role, displayName: $0.displayName, connectionState: .confirmedByUser)
        }
        return AudioRuntimePlan(revision: input.revision, preparedAt: input.preparedAt, intent: profile,
            metadata: .init(profileDisplayName: profile.name, endpointDisplayName: descriptor.name),
            sourceFormat: route.sourceFormat, dspInputFormat: route.dspInputFormat,
            physicalEndpointFormat: try .physicalEndpoints(sampleRate: profile.sampleRate, endpoints: endpoints),
            hardwareOutputFormat: route.hardwareOutputFormat, profileRoutingDescriptor: descriptor, route: route,
            processingGraph: graph, renderConfiguration: .init(profile: profile, revision: input.revision),
            playbackContext: .init(profile: profile), referenceTopology: topology,
            hardwareEvidence: hardware, assets: input.assets)
    }
}

struct AudioRuntimePlanDiagnostic: Codable {
    struct Bus: Codable {
        var id: String
        var name: String
        var format: AudioFormatDescriptor
    }
    struct Step: Codable {
        var id: UUID
        var operation: String
        var scope: String
        var channels: [Int]
        var processors: [String]
    }
    var revision: RuntimeIntentRevision
    var preparedAt: Date
    var renderConfiguration: RenderConfiguration
    var defaultPlaybackMode: PlaybackMode
    var availablePlaybackModes: [PlaybackMode]
    var rendererSummary: String
    var preparedAssets: [String]
    var schemaVersion = 2
    var generatedAt = Date()
    var profileID: UUID
    var profileName: String
    var hardwareEvidence: String
    var sourceFormat: AudioFormatDescriptor
    var dspInputFormat: AudioFormatDescriptor
    var physicalEndpointFormat: AudioFormatDescriptor
    var hardwareOutputFormat: AudioFormatDescriptor
    var hardwareFingerprint: HardwareTopologyFingerprint
    var virtualDeviceUID: String
    var virtualChannelLayoutTag: UInt32
    var supportedSampleRates: [Int]
    var automaticHeadroomDB: Double
    var multichannelSettings: MultichannelProcessingSettings
    var speakerTopology: SpeakerTopology?
    var speakerVerification: SpeakerVerificationRecord?
    var buses: [Bus]
    var pipeline: [Step]
    var camillaDSPConfiguration: String

    init(plan: AudioRuntimePlan) throws {
        let profile = plan.intent
        let simulated = plan.hardwareEvidence.simulated
        revision = plan.revision; preparedAt = plan.preparedAt
        renderConfiguration = plan.renderConfiguration
        defaultPlaybackMode = plan.playbackContext.profileMode
        availablePlaybackModes = plan.playbackContext.availableModes.sorted { $0.rawValue < $1.rawValue }
        rendererSummary = plan.rendererSummary
        preparedAssets = plan.assets.impulseResponses.values.map { "\($0.metadata.id): \($0.sha256)" }.sorted()
        profileID = profile.id; profileName = profile.name
        hardwareEvidence = simulated ? "Simulated topology; physical channel mapping is unverified" : "Detected hardware; speaker identity still requires listening verification"
        sourceFormat = plan.sourceFormat; dspInputFormat = plan.dspInputFormat
        physicalEndpointFormat = plan.physicalEndpointFormat; hardwareOutputFormat = plan.hardwareOutputFormat
        hardwareFingerprint = plan.hardwareFingerprint
        virtualDeviceUID = plan.profileRoutingDescriptor.uid
        virtualChannelLayoutTag = plan.profileRoutingDescriptor.channelLayoutTag
        supportedSampleRates = plan.profileRoutingDescriptor.supportedSampleRates
        automaticHeadroomDB = plan.processingGraph.automaticHeadroomDB
        multichannelSettings = profile.multichannel; speakerTopology = profile.speakerTopology
        speakerVerification = profile.speakerVerification.flatMap { record in
            profile.speakerTopology.map(record.matches) == true ? record : nil
        }
        buses = try plan.processingGraph.resolvedBuses().map { .init(id: $0.id.rawValue, name: $0.name, format: $0.format) }
        pipeline = plan.processingGraph.pipeline.map { step in
            let operation: String
            switch step.kind { case .filter: operation = "filter"; case .mixer(let id): operation = "mixer:\(id)" }
            return Step(id: step.id, operation: operation, scope: String(describing: step.scope), channels: step.channels, processors: step.processorIDs)
        }
        camillaDSPConfiguration = CamillaDSPCompiler().compile(plan.processingGraph).yaml
    }

    func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

extension AudioRuntimePlan {
    var rendererSummary: String {
        let config = renderConfiguration
        return "Playback: \(config.playbackMode.rawValue) · Spatial: \(config.spatialRenderingMode.rawValue) · Output: \(config.spatialOutput.rawValue)\nContent: \(config.spatialContentMode.rawValue) · Virtual layout: \(String(describing: config.virtualSurroundLayout))\nListener tuning: \(String(describing: config.spatialListenerTuning))\nReference correction: \(config.referenceCorrection.map { String(describing: $0.id) } ?? "None")\nPer-app default: \(playbackContext.profileMode.rawValue)"
    }
    var summary: String {
        "Profile: \(intent.name)\nAcknowledged plan revision: \(revision.generation)\nPrepared: \(preparedAt.formatted())\nSource: \(sourceFormat.sampleRate) Hz / \(sourceFormat.channelCount) ch\nDSP input: \(dspInputFormat.sampleRate) Hz / \(dspInputFormat.channelCount) ch\nPhysical endpoint: \(physicalEndpointFormat.channelCount) ch\nHardware output: \(hardwareOutputFormat.channelCount) ch\n\(rendererSummary)\nHardware evidence: \(hardwareEvidence.simulated ? "Simulated" : "Verified at application; not continuously probed")\nAssets: \(assets.impulseResponses.count) prepared"
    }
}
