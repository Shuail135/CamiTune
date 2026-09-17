import Foundation

/// Compare plans, not profiles. These values describe changes; AudioRuntimeCoordinator
/// owns execution. Required effects are derived here, never in individual callers.
struct RuntimePlanDelta: Hashable, Sendable {
    let fromRevision: RuntimeIntentRevision
    let toRevision: RuntimeIntentRevision
    let endpoint: EndpointDelta
    let transport: TransportDelta
    let physicalRoute: PhysicalRouteDelta
    let graph: ProcessingGraphDelta
    let renderer: RenderConfigurationDelta
    let metadata: RuntimeMetadataDelta
    let engine: EngineConfigurationDelta

    var requirements: RuntimeApplyRequirements {
        let route = physicalRoute.changed || endpoint.uidChanged
        let pipeline = route || endpoint.routingDescriptorChanged || transport.changed || renderer.referenceTopologyChanged
        return .init(requiresEndpointMetadataUpdate: endpoint.changed || metadata.profileDisplayNameChanged,
            requiresVolumeSafeHandoff: physicalRoute.outputDeviceUIDChanged || endpoint.uidChanged,
            requiresTransportRestart: pipeline, requiresPCMRestart: pipeline,
            requiresEngineQuiescence: engine.changed,
            requiresFullRuntimeRestart: pipeline,
            requiresGraphUpdate: graph != .unchanged,
            requiresRenderConfigurationUpdate: renderer.changed)
    }
    var isNoOp: Bool { isAcousticallyEquivalent && !requirements.requiresEndpointMetadataUpdate }
    var isAcousticallyEquivalent: Bool {
        !endpoint.uidChanged && !endpoint.routingDescriptorChanged && !transport.changed
            && !physicalRoute.changed && graph == .unchanged && !renderer.changed && !engine.changed
    }
    var disruptionLevel: RuntimeDisruptionLevel {
        let effects = requirements
        if effects.requiresVolumeSafeHandoff { return .routeHandoff }
        if effects.requiresFullRuntimeRestart { return .pipelineRestart }
        if effects.requiresEngineQuiescence { return .engineQuiescence }
        if effects.requiresGraphUpdate || effects.requiresRenderConfigurationUpdate { return .inPlace }
        return effects.requiresEndpointMetadataUpdate ? .metadataOnly : .none
    }
}

struct RuntimeApplyRequirements: Hashable, Sendable {
    let requiresEndpointMetadataUpdate: Bool
    let requiresVolumeSafeHandoff: Bool
    let requiresTransportRestart: Bool
    let requiresPCMRestart: Bool
    let requiresEngineQuiescence: Bool
    let requiresFullRuntimeRestart: Bool
    let requiresGraphUpdate: Bool
    let requiresRenderConfigurationUpdate: Bool

    /// Stage 5 executes quiescence conservatively through existing teardown/start.
    /// The classified requirement remains distinct for Stage 6's lifecycle owner.
    var usesExistingRestartPath: Bool {
        requiresFullRuntimeRestart || requiresTransportRestart || requiresPCMRestart || requiresEngineQuiescence
    }
}

enum RuntimeDisruptionLevel: Int, Comparable, Hashable, Sendable {
    case none, metadataOnly, inPlace, engineQuiescence, pipelineRestart, routeHandoff
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var description: String {
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

struct EndpointDelta: Hashable, Sendable {
    let uidChanged: Bool
    let displayNameChanged: Bool
    /// Signal/publication format only; excludes the display name and UID.
    let routingDescriptorChanged: Bool
    var changed: Bool { uidChanged || displayNameChanged || routingDescriptorChanged }
}
struct TransportDelta: Hashable, Sendable {
    let sourceFormatChanged: Bool
    let dspInputFormatChanged: Bool
    let sampleRateChanged: Bool
    let sourceChannelLayoutChanged: Bool
    let routingSemanticsChanged: Bool
    var changed: Bool { sourceFormatChanged || dspInputFormatChanged || routingSemanticsChanged }
}
struct PhysicalRouteDelta: Hashable, Sendable {
    let outputDeviceUIDChanged: Bool
    let physicalEndpointFormatChanged: Bool
    let hardwareOutputFormatChanged: Bool
    let hardwareFingerprintChanged: Bool
    var changed: Bool {
        outputDeviceUIDChanged || physicalEndpointFormatChanged || hardwareOutputFormatChanged || hardwareFingerprintChanged
    }
}
enum ProcessingGraphDelta: Hashable, Sendable {
    case unchanged
    case runtimePatch(changedProcessorIDs: [String])
    case replaceConfiguration
    var description: String {
        switch self {
        case .unchanged: return "Unchanged"
        case .runtimePatch(let ids): return "Runtime patch (\(ids.joined(separator: ", ")))"
        case .replaceConfiguration: return "Full configuration"
        }
    }
}
struct EngineConfigurationDelta: Hashable, Sendable {
    let chunkSizeChanged: Bool
    let captureChanged: Bool
    let exclusiveModeChanged: Bool
    var changed: Bool { chunkSizeChanged || captureChanged || exclusiveModeChanged }
}
struct RenderConfigurationDelta: Hashable, Sendable {
    let playbackModeChanged: Bool
    let spatialModeChanged: Bool
    let spatialSettingsChanged: Bool
    let spatialOutputChanged: Bool
    let listenerTuningChanged: Bool
    let contentModeChanged: Bool
    let virtualLayoutChanged: Bool
    let referenceCorrectionChanged: Bool
    let playbackContextChanged: Bool
    /// Physical renderer geometry is fixed when a PCM branch is constructed.
    let referenceTopologyChanged: Bool
    var changed: Bool {
        playbackModeChanged || spatialModeChanged || spatialSettingsChanged || spatialOutputChanged
            || listenerTuningChanged || contentModeChanged || virtualLayoutChanged || referenceCorrectionChanged
            || playbackContextChanged || referenceTopologyChanged
    }
}
struct RuntimeMetadataDelta: Hashable, Sendable {
    let profileDisplayNameChanged: Bool
    let endpointDisplayNameChanged: Bool
}

extension RuntimePlanDelta {
    var summary: String {
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
