import Foundation

/// Source content is processed globally, then routed/split, then processed by
/// speaker group and physical endpoint. Subwoofer group controls therefore act
/// on the distributed bass signal without changing the main speakers' crossover.
struct MultichannelGraphCompiler {
    func build(profile: DeviceProfile, inputFormat: AudioFormatDescriptor, assets: PreparedRuntimeAssets? = nil) throws -> ProcessingGraph {
        try profile.validateMultichannelSettings()
        let settings = profile.multichannel
        let width = profile.configuredPhysicalChannelCount
        var graph = try ProcessingGraphBuilder(channelCount: width, preparedAssets: assets).build(profile: profile)
        let processors = Dictionary(uniqueKeysWithValues: graph.processors.map { ($0.id, $0) })
        func isSourceContent(_ step: ProcessingGraph.PipelineStep) -> Bool {
            guard step.kind == .filter, step.scope == .global,
                  step.id != SpatialRoomCorrection.stageID else { return false }
            return !step.processorIDs.contains { id in
                if case .limiter = processors[id]?.implementation { return true }; return false
            }
        }
        let physicalPipeline = graph.pipeline.filter { !isSourceContent($0) }
        graph.pipeline = graph.pipeline.filter(isSourceContent).map { step in
            var step = step; step.channels = Array(0..<inputFormat.channelCount); return step
        }
        graph.inputFormat = inputFormat
        let routes = settings.routing.enabled ? settings.routing.routes : profile.defaultSpeakerRoutes(source: inputFormat)
        let bass = settings.bass
        let subs = Set(bass.subwooferEndpointIDs)
        var mappings: [ProcessingGraph.Mixer.Mapping] = profile.configuredSpeakerEndpoints.compactMap { endpoint in
            if bass.enabled && subs.contains(endpoint.id) { return nil }
            let sources = routes.filter { $0.destination == endpoint.id }.map {
                ProcessingGraph.Mixer.Source(channel: $0.sourceChannel, gainDB: $0.gainDB, inverted: $0.inverted, muted: $0.muted)
            }
            return sources.isEmpty ? nil : .init(destination: endpoint.id.channelIndex, sources: sources)
        }
        // LFE is a logical source lane, independent of every physical sub ID.
        let lfeLane = width
        if bass.enabled, let lfe = inputFormat.channels.firstIndex(where: { $0.role == .lowFrequencyEffects }) {
            mappings.append(.init(destination: lfeLane, sources: [.init(channel: lfe, gainDB: bass.lfeGainDB)]))
        }
        let routedWidth = width + (bass.enabled ? 1 : 0)
        appendMixer("source_routes", inputs: inputFormat.channelCount, outputs: routedWidth, mappings: mappings, to: &graph)

        if bass.enabled {
            let endpoints = profile.configuredSpeakerEndpoints
            let groups = profile.configuredSpeakerGroups
            let taps: [(SpeakerEndpoint, BassManagedGroupSettings)] = bass.groups.flatMap { group in
                let members = groups.first { $0.id == group.groupID }!.members
                return endpoints.filter { members.contains($0.id) && [.fullRange, .woofer].contains($0.function) }
                    .map { ($0, group) }
            }
            var expanded = (0..<routedWidth).map { ProcessingGraph.Mixer.Mapping(destination: $0, sources: [.init(channel: $0)]) }
            for (index, tap) in taps.enumerated() {
                expanded.append(.init(destination: routedWidth + index, sources: [.init(channel: tap.0.id.channelIndex)]))
            }
            appendMixer("bass_split", inputs: routedWidth, outputs: routedWidth + taps.count, mappings: expanded, to: &graph)
            for (index, tap) in taps.enumerated() {
                appendCrossover("bass_main_\(tap.0.id.channelIndex)", frequency: tap.1.crossoverHz, highPass: true,
                    slope: tap.1.slope, channel: tap.0.id.channelIndex, to: &graph)
                appendCrossover("bass_tap_\(tap.0.id.channelIndex)", frequency: tap.1.crossoverHz, highPass: false,
                    slope: tap.1.slope, channel: routedWidth + index, to: &graph)
            }
            var distributed = endpoints.filter { !subs.contains($0.id) }.map {
                ProcessingGraph.Mixer.Mapping(destination: $0.id.channelIndex, sources: [.init(channel: $0.id.channelIndex)])
            }
            for id in bass.subwooferEndpointIDs.sorted(by: { $0.channelIndex < $1.channelIndex }) {
                let sub = bass.subwooferSettings[id] ?? .init()
                let sources = ([lfeLane] + taps.indices.map { routedWidth + $0 }).map {
                    ProcessingGraph.Mixer.Source(channel: $0, gainDB: sub.gainDB, inverted: sub.inverted)
                }
                distributed.append(.init(destination: id.channelIndex, sources: sources))
            }
            appendMixer("bass_distribution", inputs: routedWidth + taps.count, outputs: width, mappings: distributed, to: &graph)
            for id in bass.subwooferEndpointIDs.sorted(by: { $0.channelIndex < $1.channelIndex }) {
                appendFilter("sub_delay_\(id.channelIndex)", channel: id.channelIndex,
                    implementation: .delay(milliseconds: bass.subwooferSettings[id]?.delayMilliseconds ?? 0, subsample: true), to: &graph)
            }
        }

        if settings.crossover.enabled {
            for endpoint in settings.crossover.endpoints.sorted(by: { $0.endpointID.channelIndex < $1.endpointID.channelIndex }) {
                let slot = endpoint.endpointID.channelIndex
                if let frequency = endpoint.highPassHz {
                    appendCrossover("driver_\(slot)_hp", frequency: frequency, highPass: true, slope: endpoint.slope, channel: slot, to: &graph)
                }
                if let frequency = endpoint.lowPassHz {
                    appendCrossover("driver_\(slot)_lp", frequency: frequency, highPass: false, slope: endpoint.slope, channel: slot, to: &graph)
                }
            }
        }
        graph.pipeline += physicalPipeline
        // Required protection is compiler-owned and cannot be disabled by the
        // editable physical/group limiter toggles. It follows all user processing.
        if settings.crossover.enabled {
            let assignment = graph.pipeline.last.flatMap { step -> ProcessingGraph.PipelineStep? in
                if case .mixer(let id) = step.kind, id == "interface_output_assignment" { return step }; return nil
            }
            if assignment != nil { graph.pipeline.removeLast() }
            for (id, protection) in settings.crossover.protection.sorted(by: { $0.key.channelIndex < $1.key.channelIndex }) where protection.limiterRequired {
                appendFilter("protection_\(id.channelIndex)", channel: id.channelIndex,
                    implementation: .limiter(.init(clipLimitDB: -3, softClip: false)), to: &graph)
            }
            if let assignment { graph.pipeline.append(assignment) }
        }
        try graph.validate()
        graph.automaticHeadroomDB = ProcessingGraphHeadroomCalculator().calculate(for: graph,
            excludingGainStageIDs: [ProcessingProfile.userPreampStageID])
        guard graph.automaticHeadroomDB.isFinite else { throw invalid("The routing gain exceeds the supported range.") }
        if let index = graph.processors.firstIndex(where: { $0.id == ProcessingGraph.automaticHeadroomProcessorID }) {
            graph.processors[index].implementation = .gain(db: graph.automaticHeadroomDB)
        }
        try validateProtection(profile: profile, graph: graph)
        return graph
    }

    private func appendMixer(_ key: String, inputs: Int, outputs: Int, mappings: [ProcessingGraph.Mixer.Mapping], to graph: inout ProcessingGraph) {
        let name = "multichannel_\(key)", id = identity(key)
        graph.mixers.append(.init(id: name, sourceStageID: id, inputChannelCount: inputs, outputChannelCount: outputs, mappings: mappings))
        graph.pipeline.append(.init(id: id, kind: .mixer(id: name), scope: .global, channels: [], processorIDs: []))
    }
    private func appendFilter(_ key: String, channel: Int, implementation: ProcessingGraph.Processor.Implementation, to graph: inout ProcessingGraph) {
        let name = "multichannel_\(key)", id = identity(key)
        graph.processors.append(.init(id: name, sourceStageID: id, implementation: implementation))
        graph.pipeline.append(.init(id: id, scope: .channel(index: channel, role: .unknown), channels: [channel], processorIDs: [name]))
    }
    private func appendCrossover(_ key: String, frequency: Double, highPass: Bool, slope: CrossoverSlope, channel: Int, to graph: inout ProcessingGraph) {
        for (index, q) in slope.sectionQs.enumerated() {
            let key = "\(key)_\(index)"
            appendFilter(key, channel: channel, implementation: .biquad(.init(id: identity(key),
                kind: highPass ? .highPass : .lowPass, frequency: frequency, q: q)), to: &graph)
        }
    }
    private func identity(_ key: String) -> UUID { SpeakerGroupID(rawValue: "multichannel:\(key)").stageID("processor") }
    private func invalid(_ message: String) -> ProfileSettingsError { .runtime(message) }

    private func validateProtection(profile: DeviceProfile, graph: ProcessingGraph) throws {
        guard profile.multichannel.crossover.enabled else { return }
        guard let magnitudes = ProcessingGraphHeadroomCalculator().peakOutputMagnitudes(for: graph,
                includingAutomaticHeadroom: true) else { throw invalid("The active driver gain could not be validated.") }
        for (id, protection) in profile.multichannel.crossover.protection {
            let maximumGain = 20 * log10(max(Double.leastNormalMagnitude, magnitudes[id.channelIndex]))
            if let limit = protection.maximumGainDB, maximumGain > limit + 0.001 {
                throw invalid("The processed gain exceeds an active driver's protection limit. Reduce global preamp or review its maximum gain.")
            }
        }
    }
}

extension DeviceProfile {
    func validateMultichannelSettings() throws {
        let value = multichannel
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw ProfileSettingsError.runtime(message) } }
        try require(value.schemaVersion == 1, "This multichannel settings version is unsupported.")
        let endpoints = configuredSpeakerEndpoints
        let ids = Set(endpoints.map(\.id))
        let activeDrivers = endpoints.filter { [.woofer, .midrange, .tweeter].contains($0.function) }
        try require(activeDrivers.isEmpty || value.crossover.enabled, "Configure active crossovers and driver protection before activating these drivers.")
        guard value.isEnabled else { return }
        try require(hasPhysicalSpeakerRoute, "Configure physical speakers before enabling multichannel processing.")
        try require(playbackMode == .direct, "Bass management, custom routing and active crossovers currently require Direct playback.")
        func frequency(_ hz: Double) -> Bool { hz.isFinite && hz >= 10 && hz < Double(sampleRate) * 0.49 }
        if value.routing.enabled {
            try require((1...32).contains(value.routing.discreteChannelCount), "The discrete source must have 1–32 channels.")
            let count = value.routing.sourceLayout.layout(channelCount: value.routing.discreteChannelCount).channelCount
            var keys = Set<String>(), routeIDs = Set<UUID>()
            for route in value.routing.routes {
                try require(routeIDs.insert(route.id).inserted && keys.insert("\(route.sourceChannel):\(route.destination.channelIndex)").inserted,
                    "Each source-to-speaker route must be unique.")
                try require(ids.contains(route.destination) && (0..<count).contains(route.sourceChannel), "A route references an unavailable source or physical speaker. Review Advanced Routing.")
                try require(route.gainDB.isFinite && (-120...24).contains(route.gainDB), "Route gain must be between −120 and +24 dB.")
                if value.bass.enabled {
                    try require(!value.bass.subwooferEndpointIDs.contains(route.destination), "Remove direct routes to bass-managed subwoofers; Bass & Subwoofers supplies their signal.")
                }
            }
        }
        if value.bass.enabled {
            let bass = value.bass
            try require(!bass.subwooferEndpointIDs.isEmpty && Set(bass.subwooferEndpointIDs).count == bass.subwooferEndpointIDs.count,
                "Choose at least one distinct subwoofer for bass management.")
            try require(bass.lfeGainDB.isFinite && (-120...24).contains(bass.lfeGainDB), "LFE trim must be between −120 and +24 dB.")
            for id in bass.subwooferEndpointIDs {
                try require(endpoints.contains { $0.id == id && $0.function == .subwoofer }, "A bass-management output is unavailable or is no longer a subwoofer. Review Bass & Subwoofers.")
                let sub = bass.subwooferSettings[id] ?? .init()
                try require(sub.gainDB.isFinite && (-120...24).contains(sub.gainDB) && sub.delayMilliseconds.isFinite && (0...100).contains(sub.delayMilliseconds), "Subwoofer trim or delay is outside the supported range.")
            }
            var members = Set<PhysicalOutputID>(), groups = Set<SpeakerGroupID>()
            for group in bass.groups {
                try require(groups.insert(group.groupID).inserted && frequency(group.crossoverHz), "Bass crossover groups must be unique and their frequencies must be below Nyquist.")
                guard let configured = configuredSpeakerGroups.first(where: { $0.id == group.groupID }) else {
                    throw ProfileSettingsError.runtime("A bass-managed speaker group is unavailable. Review Bass & Subwoofers.")
                }
                for id in configured.members {
                    try require(!bass.subwooferEndpointIDs.contains(id) && members.insert(id).inserted,
                        "Bass-managed groups must not overlap or include a subwoofer.")
                }
            }
        }
        if value.crossover.enabled {
            let crossover = value.crossover
            try require(!activeDrivers.isEmpty, "Assign Woofer, Midrange or Tweeter speaker functions before enabling active crossovers.")
            guard let topology = speakerTopology, let reviewed = crossover.reviewedHardware,
                  reviewed == (try? HardwareTopologyFingerprint(topology: topology)) else {
                throw ProfileSettingsError.runtime("Review the active speaker hardware map before enabling crossovers.")
            }
            try require(Set(crossover.endpoints.map(\.endpointID)).count == crossover.endpoints.count, "Each physical driver must have one crossover configuration.")
            for item in crossover.endpoints {
                try require(ids.contains(item.endpointID), "A crossover targets an unavailable physical driver.")
                try require(item.highPassHz.map(frequency) ?? true, "A crossover high-pass frequency is invalid.")
                try require(item.lowPassHz.map(frequency) ?? true, "A crossover low-pass frequency is invalid.")
                if let hp = item.highPassHz, let lp = item.lowPassHz { try require(hp < lp, "The driver high-pass must be below its low-pass.") }
            }
            for endpoint in activeDrivers {
                guard let filter = crossover.endpoints.first(where: { $0.endpointID == endpoint.id }),
                      let protection = crossover.protection[endpoint.id] else {
                    throw ProfileSettingsError.runtime("\(endpoint.displayName) needs crossover and protection settings before activation.")
                }
                if endpoint.function == .woofer || endpoint.function == .midrange {
                    try require(filter.lowPassHz != nil, "\(endpoint.displayName) needs a low-pass crossover.")
                }
                if endpoint.function == .tweeter || endpoint.function == .midrange {
                    try require(protection.requiredHighPassHz != nil && protection.limiterRequired,
                        "\(endpoint.displayName) needs mandatory high-pass and limiter protection.")
                }
            }
            for (id, protection) in crossover.protection {
                try require(ids.contains(id), "Protection references an unavailable physical output.")
                if let maximum = protection.maximumGainDB { try require(maximum.isFinite && (-24...24).contains(maximum), "The protection gain limit is invalid.") }
                if let minimum = protection.requiredHighPassHz {
                    let filter = crossover.endpoints.first { $0.endpointID == id }
                    try require(frequency(minimum) && (filter?.highPassHz ?? 0) >= minimum && (filter?.slope.rawValue ?? 0) >= protection.requiredHighPassSlope.rawValue,
                        "The required driver high-pass protection is missing or too weak. Activation is blocked.")
                }
            }
        }
    }

    func validateMultichannelHardware(_ discovered: SpeakerTopology) throws {
        guard multichannel.crossover.enabled else { return }
        guard multichannel.crossover.reviewedHardware == (try? HardwareTopologyFingerprint(topology: discovered)) else {
            throw ProfileSettingsError.runtime("The active speaker hardware map changed. Review Speakers and driver protection before activation.")
        }
    }
}
