import Foundation

/// Compare plans, not profiles. These values describe changes; AudioRuntimeCoordinator
/// owns execution. Required effects are derived here, never in individual callers.
package struct RuntimePlanDelta: Hashable, Sendable {
    package init(
        fromRevision: RuntimeIntentRevision,
        toRevision: RuntimeIntentRevision,
        endpoint: EndpointDelta,
        transport: TransportDelta,
        physicalRoute: PhysicalRouteDelta,
        graph: ProcessingGraphDelta,
        renderer: RenderConfigurationDelta,
        metadata: RuntimeMetadataDelta,
        engine: EngineConfigurationDelta,
        pcmDeliveryChanged: Bool
    ) {
        self.fromRevision = fromRevision
        self.toRevision = toRevision
        self.endpoint = endpoint
        self.transport = transport
        self.physicalRoute = physicalRoute
        self.graph = graph
        self.renderer = renderer
        self.metadata = metadata
        self.engine = engine
        self.pcmDeliveryChanged = pcmDeliveryChanged
    }

    package let fromRevision: RuntimeIntentRevision
    package let toRevision: RuntimeIntentRevision
    package let endpoint: EndpointDelta
    package let transport: TransportDelta
    package let physicalRoute: PhysicalRouteDelta
    package let graph: ProcessingGraphDelta
    package let renderer: RenderConfigurationDelta
    package let metadata: RuntimeMetadataDelta
    package let engine: EngineConfigurationDelta
    package let pcmDeliveryChanged: Bool

    package var requirements: RuntimeApplyRequirements {
        let route = physicalRoute.changed || endpoint.uidChanged
        let pipeline = route || endpoint.routingDescriptorChanged || transport.changed || renderer.referenceTopologyChanged
        return .init(requiresEndpointMetadataUpdate: endpoint.changed || metadata.profileDisplayNameChanged,
            requiresVolumeSafeHandoff: physicalRoute.outputDeviceUIDChanged || endpoint.uidChanged,
            requiresTransportRestart: pipeline, requiresPCMRestart: pipeline,
            requiresEngineQuiescence: engine.changed,
            requiresFullRuntimeRestart: pipeline,
            requiresGraphUpdate: graph != .unchanged,
            requiresRenderConfigurationUpdate: renderer.changed,
            requiresPCMDeliveryUpdate: pcmDeliveryChanged)
    }
    package var isNoOp: Bool { isAcousticallyEquivalent && !requirements.requiresEndpointMetadataUpdate }
    package var isAcousticallyEquivalent: Bool {
        !endpoint.uidChanged && !endpoint.routingDescriptorChanged && !transport.changed
            && !physicalRoute.changed && graph == .unchanged && !renderer.changed && !engine.changed && !pcmDeliveryChanged
    }
    package var disruptionLevel: RuntimeDisruptionLevel {
        let effects = requirements
        if effects.requiresVolumeSafeHandoff { return .routeHandoff }
        if effects.requiresFullRuntimeRestart { return .pipelineRestart }
        if effects.requiresEngineQuiescence { return .engineQuiescence }
        if effects.requiresGraphUpdate || effects.requiresRenderConfigurationUpdate || effects.requiresPCMDeliveryUpdate { return .inPlace }
        return effects.requiresEndpointMetadataUpdate ? .metadataOnly : .none
    }
}

package struct RuntimeApplyRequirements: Hashable, Sendable {
    package init(
        requiresEndpointMetadataUpdate: Bool,
        requiresVolumeSafeHandoff: Bool,
        requiresTransportRestart: Bool,
        requiresPCMRestart: Bool,
        requiresEngineQuiescence: Bool,
        requiresFullRuntimeRestart: Bool,
        requiresGraphUpdate: Bool,
        requiresRenderConfigurationUpdate: Bool,
        requiresPCMDeliveryUpdate: Bool
    ) {
        self.requiresEndpointMetadataUpdate = requiresEndpointMetadataUpdate
        self.requiresVolumeSafeHandoff = requiresVolumeSafeHandoff
        self.requiresTransportRestart = requiresTransportRestart
        self.requiresPCMRestart = requiresPCMRestart
        self.requiresEngineQuiescence = requiresEngineQuiescence
        self.requiresFullRuntimeRestart = requiresFullRuntimeRestart
        self.requiresGraphUpdate = requiresGraphUpdate
        self.requiresRenderConfigurationUpdate = requiresRenderConfigurationUpdate
        self.requiresPCMDeliveryUpdate = requiresPCMDeliveryUpdate
    }

    package let requiresEndpointMetadataUpdate: Bool
    package let requiresVolumeSafeHandoff: Bool
    package let requiresTransportRestart: Bool
    package let requiresPCMRestart: Bool
    package let requiresEngineQuiescence: Bool
    package let requiresFullRuntimeRestart: Bool
    package let requiresGraphUpdate: Bool
    package let requiresRenderConfigurationUpdate: Bool
    package let requiresPCMDeliveryUpdate: Bool

    /// Stage 5 executes quiescence conservatively through existing teardown/start.
    /// The classified requirement remains distinct for Stage 6's lifecycle owner.
    package var usesExistingRestartPath: Bool {
        requiresFullRuntimeRestart || requiresTransportRestart || requiresPCMRestart || requiresEngineQuiescence
    }
}

package enum RuntimeDisruptionLevel: Int, Comparable, Hashable, Sendable {
    case none, metadataOnly, inPlace, engineQuiescence, pipelineRestart, routeHandoff
    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    package var description: String {
        switch self {
        case .none: return "None"
        case .metadataOnly: return "Metadata only"
        case .inPlace: return "In-place"
        case .engineQuiescence: return "Engine quiescence"
        case .pipelineRestart: return "Pipeline restart"
        case .routeHandoff: return "Route handoff"
        }
    }
}

package struct EndpointDelta: Hashable, Sendable {
    package init(uidChanged: Bool, displayNameChanged: Bool, routingDescriptorChanged: Bool) {
        self.uidChanged = uidChanged
        self.displayNameChanged = displayNameChanged
        self.routingDescriptorChanged = routingDescriptorChanged
    }

    package let uidChanged: Bool
    package let displayNameChanged: Bool
    /// Signal/publication format only; excludes the display name and UID.
    package let routingDescriptorChanged: Bool
    package var changed: Bool { uidChanged || displayNameChanged || routingDescriptorChanged }
}
package struct TransportDelta: Hashable, Sendable {
    package init(
        sourceFormatChanged: Bool,
        dspInputFormatChanged: Bool,
        sampleRateChanged: Bool,
        sourceChannelLayoutChanged: Bool,
        routingSemanticsChanged: Bool
    ) {
        self.sourceFormatChanged = sourceFormatChanged
        self.dspInputFormatChanged = dspInputFormatChanged
        self.sampleRateChanged = sampleRateChanged
        self.sourceChannelLayoutChanged = sourceChannelLayoutChanged
        self.routingSemanticsChanged = routingSemanticsChanged
    }

    package let sourceFormatChanged: Bool
    package let dspInputFormatChanged: Bool
    package let sampleRateChanged: Bool
    package let sourceChannelLayoutChanged: Bool
    package let routingSemanticsChanged: Bool
    package var changed: Bool { sourceFormatChanged || dspInputFormatChanged || routingSemanticsChanged }
}
package struct PhysicalRouteDelta: Hashable, Sendable {
    package init(
        outputDeviceUIDChanged: Bool,
        physicalEndpointFormatChanged: Bool,
        hardwareOutputFormatChanged: Bool,
        hardwareFingerprintChanged: Bool
    ) {
        self.outputDeviceUIDChanged = outputDeviceUIDChanged
        self.physicalEndpointFormatChanged = physicalEndpointFormatChanged
        self.hardwareOutputFormatChanged = hardwareOutputFormatChanged
        self.hardwareFingerprintChanged = hardwareFingerprintChanged
    }

    package let outputDeviceUIDChanged: Bool
    package let physicalEndpointFormatChanged: Bool
    package let hardwareOutputFormatChanged: Bool
    package let hardwareFingerprintChanged: Bool
    package var changed: Bool {
        outputDeviceUIDChanged || physicalEndpointFormatChanged || hardwareOutputFormatChanged || hardwareFingerprintChanged
    }
}
package enum ProcessingGraphDelta: Hashable, Sendable {
    case unchanged
    case runtimePatch(changedProcessorIDs: [String])
    case replaceConfiguration
    package var description: String {
        switch self {
        case .unchanged: return "Unchanged"
        case .runtimePatch(let ids): return "Runtime patch (\(ids.joined(separator: ", ")))"
        case .replaceConfiguration: return "Full configuration"
        }
    }
}
package struct EngineConfigurationDelta: Hashable, Sendable {
    package init(chunkSizeChanged: Bool, captureChanged: Bool, exclusiveModeChanged: Bool, queueLimitChanged: Bool) {
        self.chunkSizeChanged = chunkSizeChanged
        self.captureChanged = captureChanged
        self.exclusiveModeChanged = exclusiveModeChanged
        self.queueLimitChanged = queueLimitChanged
    }

    package let chunkSizeChanged: Bool
    package let captureChanged: Bool
    package let exclusiveModeChanged: Bool
    package let queueLimitChanged: Bool
    package var changed: Bool { chunkSizeChanged || captureChanged || exclusiveModeChanged || queueLimitChanged }
}
package struct RenderConfigurationDelta: Hashable, Sendable {
    package init(
        playbackModeChanged: Bool,
        spatialModeChanged: Bool,
        spatialSettingsChanged: Bool,
        spatialOutputChanged: Bool,
        listenerTuningChanged: Bool,
        contentModeChanged: Bool,
        virtualLayoutChanged: Bool,
        referenceCorrectionChanged: Bool,
        playbackContextChanged: Bool,
        referenceTopologyChanged: Bool
    ) {
        self.playbackModeChanged = playbackModeChanged
        self.spatialModeChanged = spatialModeChanged
        self.spatialSettingsChanged = spatialSettingsChanged
        self.spatialOutputChanged = spatialOutputChanged
        self.listenerTuningChanged = listenerTuningChanged
        self.contentModeChanged = contentModeChanged
        self.virtualLayoutChanged = virtualLayoutChanged
        self.referenceCorrectionChanged = referenceCorrectionChanged
        self.playbackContextChanged = playbackContextChanged
        self.referenceTopologyChanged = referenceTopologyChanged
    }

    package let playbackModeChanged: Bool
    package let spatialModeChanged: Bool
    package let spatialSettingsChanged: Bool
    package let spatialOutputChanged: Bool
    package let listenerTuningChanged: Bool
    package let contentModeChanged: Bool
    package let virtualLayoutChanged: Bool
    package let referenceCorrectionChanged: Bool
    package let playbackContextChanged: Bool
    /// Physical renderer geometry is fixed when a PCM branch is constructed.
    package let referenceTopologyChanged: Bool
    package var changed: Bool {
        playbackModeChanged || spatialModeChanged || spatialSettingsChanged || spatialOutputChanged
            || listenerTuningChanged || contentModeChanged || virtualLayoutChanged || referenceCorrectionChanged
            || playbackContextChanged || referenceTopologyChanged
    }
}
package struct RuntimeMetadataDelta: Hashable, Sendable {
    package init(profileDisplayNameChanged: Bool, endpointDisplayNameChanged: Bool) {
        self.profileDisplayNameChanged = profileDisplayNameChanged
        self.endpointDisplayNameChanged = endpointDisplayNameChanged
    }

    package let profileDisplayNameChanged: Bool
    package let endpointDisplayNameChanged: Bool
}

extension RuntimePlanDelta {
    package var summary: String {
        func changed(_ name: String, _ value: Bool) -> String { "\(name): \(value ? "Changed" : "Unchanged")" }
        let effects = requirements
        return [
            "Compared acknowledged revision: \(fromRevision.generation) (\(fromRevision.profileID))",
            "Candidate revision: \(toRevision.generation) (\(toRevision.profileID))",
            "Disruption: \(disruptionLevel.description)",
            "Acoustically equivalent: \(isAcousticallyEquivalent ? "Yes" : "No")",
            "Planned graph update: \(graph.description)",
            changed("Endpoint UID", endpoint.uidChanged),
            changed("Endpoint publication format", endpoint.routingDescriptorChanged),
            changed("Profile name", metadata.profileDisplayNameChanged),
            changed("Endpoint name", endpoint.displayNameChanged),
            changed("Source format", transport.sourceFormatChanged),
            changed("DSP input format", transport.dspInputFormatChanged),
            changed("Routing semantics", transport.routingSemanticsChanged),
            changed("Physical output UID", physicalRoute.outputDeviceUIDChanged),
            changed("Physical endpoint format", physicalRoute.physicalEndpointFormatChanged),
            changed("Hardware output format", physicalRoute.hardwareOutputFormatChanged),
            changed("Hardware fingerprint", physicalRoute.hardwareFingerprintChanged),
            changed("Playback mode", renderer.playbackModeChanged),
            changed("Spatial mode", renderer.spatialModeChanged),
            changed("Spatial settings", renderer.spatialSettingsChanged),
            changed("Spatial output", renderer.spatialOutputChanged),
            changed("Listener tuning", renderer.listenerTuningChanged),
            changed("Content mode", renderer.contentModeChanged),
            changed("Virtual layout", renderer.virtualLayoutChanged),
            changed("Reference correction", renderer.referenceCorrectionChanged),
            changed("Per-app playback context", renderer.playbackContextChanged),
            changed("Physical renderer geometry", renderer.referenceTopologyChanged),
            changed("Engine chunk size", engine.chunkSizeChanged),
            changed("Camilla queue limit", engine.queueLimitChanged),
            changed("PCM delivery policy", pcmDeliveryChanged),
            changed("Capture configuration", engine.captureChanged),
            changed("Exclusive playback", engine.exclusiveModeChanged),
            "Required effects:",
            "  Graph update: \(effects.requiresGraphUpdate)",
            "  Renderer snapshot: \(effects.requiresRenderConfigurationUpdate)",
            "  Endpoint publication: \(effects.requiresEndpointMetadataUpdate)",
            "  Transport restart: \(effects.requiresTransportRestart)",
            "  PCM restart: \(effects.requiresPCMRestart)",
            "  Engine quiescence: \(effects.requiresEngineQuiescence)",
            "  Full runtime restart: \(effects.requiresFullRuntimeRestart)",
            "  Volume-safe handoff: \(effects.requiresVolumeSafeHandoff)"
        ].joined(separator: "\n")
    }
}

/// Cross-session transfer is deliberately disabled. This decision consumes the
/// authoritative delta; it does not compare profiles or affect in-session patches.
package enum RuntimeResourceReuseDecision: Equatable, Sendable {
    package enum RestartReason: String, Sendable {
        case endpointChanged, physicalRouteChanged, transportChanged, backendChanged
        case deliveryChanged, rendererTopologyChanged, reuseNotQualified
    }
    case cleanRestart(RestartReason)

    package static func evaluate(_ delta: RuntimePlanDelta) -> Self {
        if delta.endpoint.uidChanged || delta.endpoint.routingDescriptorChanged { return .cleanRestart(.endpointChanged) }
        if delta.physicalRoute.changed { return .cleanRestart(.physicalRouteChanged) }
        if delta.transport.changed || delta.transport.sampleRateChanged || delta.transport.sourceChannelLayoutChanged {
            return .cleanRestart(.transportChanged)
        }
        if delta.engine.changed { return .cleanRestart(.backendChanged) }
        if delta.pcmDeliveryChanged { return .cleanRestart(.deliveryChanged) }
        if delta.renderer.referenceTopologyChanged { return .cleanRestart(.rendererTopologyChanged) }
        return .cleanRestart(.reuseNotQualified)
    }
}
