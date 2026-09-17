import Foundation

/// Pure comparison of acknowledged and prepared runtime values. No profile
/// interpretation, external evidence lookup, execution, or lifecycle ownership.
struct RuntimePlanDiffer: Sendable {
    private let graphDiffer: ProcessingGraphDiffer
    init(graphDiffer: ProcessingGraphDiffer = .init()) { self.graphDiffer = graphDiffer }

    func delta(from old: AudioRuntimePlan, to new: AudioRuntimePlan) -> RuntimePlanDelta {
        let oldEndpoint = old.profileRoutingDescriptor, newEndpoint = new.profileRoutingDescriptor
        let a = old.renderConfiguration, b = new.renderConfiguration
        let graph: ProcessingGraphDelta
        switch graphDiffer.update(from: old.processingGraph, to: new.processingGraph) {
        case .unchanged: graph = .unchanged
        case .patch(let processors): graph = .runtimePatch(changedProcessorIDs: processors.map(\.id))
        case .replaceConfiguration: graph = .replaceConfiguration
        }
        return .init(fromRevision: old.revision, toRevision: new.revision,
            endpoint: .init(uidChanged: oldEndpoint.uid != newEndpoint.uid,
                displayNameChanged: oldEndpoint.name != newEndpoint.name,
                routingDescriptorChanged: oldEndpoint.channelCount != newEndpoint.channelCount
                    || oldEndpoint.channelLayoutTag != newEndpoint.channelLayoutTag
                    || Set(oldEndpoint.supportedSampleRates) != Set(newEndpoint.supportedSampleRates)),
            transport: .init(sourceFormatChanged: old.sourceFormat.signalSignature != new.sourceFormat.signalSignature,
                dspInputFormatChanged: old.dspInputFormat.signalSignature != new.dspInputFormat.signalSignature,
                sampleRateChanged: old.sourceFormat.sampleRate != new.sourceFormat.sampleRate
                    || old.dspInputFormat.sampleRate != new.dspInputFormat.sampleRate,
                sourceChannelLayoutChanged: old.sourceFormat.signalSignature.channels != new.sourceFormat.signalSignature.channels,
                routingSemanticsChanged: old.route.usesPhysicalSpeakerBus != new.route.usesPhysicalSpeakerBus
                    || old.route.usesSourceProcessingBus != new.route.usesSourceProcessingBus
                    || old.route.usesDiscreteSource != new.route.usesDiscreteSource),
            physicalRoute: .init(outputDeviceUIDChanged: old.hardwareEvidence.output.uid != new.hardwareEvidence.output.uid,
                physicalEndpointFormatChanged: old.physicalEndpointFormat.signalSignature != new.physicalEndpointFormat.signalSignature,
                hardwareOutputFormatChanged: old.hardwareOutputFormat.signalSignature != new.hardwareOutputFormat.signalSignature,
                hardwareFingerprintChanged: old.hardwareFingerprint != new.hardwareFingerprint),
            graph: graph,
            renderer: .init(playbackModeChanged: a.playbackMode != b.playbackMode,
                spatialModeChanged: a.spatialRenderingMode != b.spatialRenderingMode,
                spatialSettingsChanged: a.spatialSettings != b.spatialSettings,
                spatialOutputChanged: a.spatialOutput != b.spatialOutput,
                listenerTuningChanged: a.spatialListenerTuning != b.spatialListenerTuning,
                contentModeChanged: a.spatialContentMode != b.spatialContentMode,
                virtualLayoutChanged: a.virtualSurroundLayout != b.virtualSurroundLayout,
                referenceCorrectionChanged: a.referenceCorrection != b.referenceCorrection,
                playbackContextChanged: old.playbackContext != new.playbackContext,
                referenceTopologyChanged: referenceSignature(old.referenceTopology) != referenceSignature(new.referenceTopology)),
            metadata: .init(profileDisplayNameChanged: old.metadata.profileDisplayName != new.metadata.profileDisplayName,
                endpointDisplayNameChanged: old.metadata.endpointDisplayName != new.metadata.endpointDisplayName),
            engine: .init(chunkSizeChanged: old.processingGraph.chunkSize != new.processingGraph.chunkSize,
                captureChanged: old.processingGraph.capture != new.processingGraph.capture,
                exclusiveModeChanged: old.processingGraph.playback.exclusive != new.processingGraph.playback.exclusive))
    }

    /// Physical renderer construction consumes geometry and enabled identities,
    /// not labels, provenance, timestamps, or layout-editor group names.
    private func referenceSignature(_ topology: SpeakerTopology?) -> SpeakerTopology? {
        guard var topology else { return nil }
        topology.createdAt = .distantPast; topology.updatedAt = .distantPast
        topology.layoutTemplateID = nil; topology.groups = []
        topology.hardwareRoles = nil; topology.hardwarePositions = nil
        topology.endpoints = topology.endpoints.filter {
            $0.connectionState == .confirmedByUser || $0.connectionState == .acousticallyDetected
        }.map {
            var endpoint = $0
            endpoint.displayName = ""; endpoint.positionSource = .unknown; endpoint.roleOrigin = .user
            endpoint.groupID = nil; endpoint.connectionState = .confirmedByUser
            return endpoint
        }
        return topology
    }
}
