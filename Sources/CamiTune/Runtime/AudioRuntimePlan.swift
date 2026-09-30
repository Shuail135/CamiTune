import CamiTuneDomain
import Foundation

/// Effective renderer values from exactly one intent snapshot. Live gain and
/// temporary calibration overlays deliberately have separate owners.

/// Prepare once. Compile once. Execute this plan without reinterpreting intent.
/// The intent snapshot is retained for diagnostics and endpoint publication only.

/// Pure derivation: no hardware provider, filesystem resolver, RPC, or store.

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
    var deliveryConfiguration: PCMDeliveryConfiguration
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
        deliveryConfiguration = plan.deliveryConfiguration
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
