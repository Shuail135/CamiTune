import Foundation

/// Validated activation/export result. Generated plans are runtime values, while
/// profiles persist the user's speaker, routing and processing intent.
struct AudioRuntimePlan: Hashable, Sendable {
    let sourceFormat: AudioFormatDescriptor
    let dspInputFormat: AudioFormatDescriptor
    let physicalEndpointFormat: AudioFormatDescriptor
    let hardwareOutputFormat: AudioFormatDescriptor
    let profileRoutingDescriptor: ProfileRoutingDescriptor
    let processingGraph: ProcessingGraph
    let hardwareFingerprint: HardwareTopologyFingerprint
}

struct AudioRuntimePlanCompiler {
    func compile(profile original: DeviceProfile, detectedHardware: SpeakerTopology) throws -> AudioRuntimePlan {
        var profile = original
        try profile.migrateInterfaceTopology()
        guard profile.outputDeviceUID == detectedHardware.deviceUID,
              profile.configuredPhysicalChannelCount == detectedHardware.declaredChannelCount else {
            throw SpeakerTopologyError.hardwareLayoutChanged
        }
        try profile.speakerTopology?.validateHardware(detectedHardware)
        try profile.validateMultichannelHardware(detectedHardware)
        let route = try ActiveAudioRoute(profile: profile)
        let graph = try route.buildGraph(profile: profile)
        let descriptor = ProfileRoutingDescriptor.descriptors(for: [profile])[profile.id]!
        _ = try descriptor.formatPayload()
        let endpoints = profile.configuredProcessingChannels.map {
            SpeakerEndpoint(id: $0.physicalOutputID, role: $0.role, displayName: $0.displayName, connectionState: .confirmedByUser)
        }
        return AudioRuntimePlan(sourceFormat: route.sourceFormat, dspInputFormat: route.dspInputFormat,
            physicalEndpointFormat: try .physicalEndpoints(sampleRate: profile.sampleRate, endpoints: endpoints),
            hardwareOutputFormat: route.hardwareOutputFormat, profileRoutingDescriptor: descriptor,
            processingGraph: graph, hardwareFingerprint: try .init(topology: detectedHardware))
    }

    func compile(profile: DeviceProfile, hardware: any AudioHardwareTopologyProvider) throws -> AudioRuntimePlan {
        try compile(profile: profile, detectedHardware: hardware.topology(for: profile.outputDeviceUID,
            sampleRate: Double(profile.sampleRate)).speakerTopology)
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
    var schemaVersion = 1
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

    init(plan: AudioRuntimePlan, profile: DeviceProfile, simulated: Bool) throws {
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
