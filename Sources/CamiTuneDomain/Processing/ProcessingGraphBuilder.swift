import Foundation

/// A validated, runtime-oriented graph. It contains no UI, import-format, or
/// CamillaDSP YAML concerns and is therefore suitable for alternate backends.

package struct ProcessingGraphBuilder {
    package let channelCount: Int
    package let preparedAssets: PreparedRuntimeAssets

    package init(channelCount: Int = 2, preparedAssets: PreparedRuntimeAssets) {
        self.channelCount = channelCount
        self.preparedAssets = preparedAssets
    }

    package func build(profile: DeviceProfile) throws -> ProcessingGraph {
        var profile = profile
        try profile.migrateInterfaceTopology()
        try profile.validateMultichannelSettings()
        if let topology = try profile.validatedPhysicalSpeakerTopology(), topology.declaredChannelCount != channelCount {
            throw ProcessingGraphError.invalidChannelCount
        }
        _ = try profile.validatedReferenceTopology()
        if profile.isPersonalListening, let correction = profile.personalReferenceCorrection {
            guard correction.schemaVersion == DeviceCorrectionProfile.currentSchemaVersion,
                  ReferenceCorrection.validFilters(correction.filters, sampleRate: Double(profile.sampleRate)) else {
                throw ProfileSettingsError.runtime("Reference correction contains unsupported or invalid filters.")
            }
        }
        guard profile.sampleRate > 0 else { throw ProcessingGraphError.invalidSampleRate }
        guard profile.chunkSize > 0 else { throw ProcessingGraphError.invalidChunkSize }
        guard channelCount > 0 else { throw ProcessingGraphError.invalidChannelCount }

        var processing = try profile.resolvedProcessing()
        if profile.hasPhysicalSpeakerRoute {
            // Legacy L/R room measurements have no physical topology identity.
            // Preserve them in the profile but never apply them to a new map.
            processing.global.stages.removeAll { $0.id == ProcessingProfile.spatialRoomCorrectionStageID }
        }
        if !profile.supportsCrossfeed { processing.global.stages.removeAll { if case .crossfeed = $0.processor { return true }; return false } }
        guard processing.schemaVersion == ProcessingProfile.currentSchemaVersion else {
            throw ProcessingGraphError.unsupportedSchemaVersion(processing.schemaVersion)
        }

        var graph = ProcessingGraph(
            title: profile.name,
            sampleRate: profile.sampleRate,
            chunkSize: profile.chunkSize,
            channelCount: channelCount,
            capture: .init(format: .interleavedFloat32LittleEndian),
            playback: .init(deviceUID: profile.outputDeviceUID, exclusive: false),
            automaticHeadroomDB: 0,
            processors: [],
            mixers: [],
            pipeline: []
        )
        var usedStageIDs = Set<UUID>()
        if profile.hasPhysicalSpeakerRoute,
           let seat = profile.effectiveSpatialSettings.seating,
           let measuredTopology = seat.roomCorrectionTopology,
           measuredTopology == profile.speakerTopology,
           !seat.roomCorrectionBands.isEmpty {
            let measuredChannels = profile.configuredProcessingChannels.filter { $0.role == .left || $0.role == .right }.map(\.index)
            if !measuredChannels.isEmpty {
                try append(ProcessingChain(stages: [ProcessingStage(id: ProcessingProfile.spatialRoomCorrectionStageID,
                    processor: .equalizer(EqualizerProcessor(bands: seat.roomCorrectionBands)))]),
                    identifierScope: "measured_front_outputs", pipelineScope: .global, channels: measuredChannels,
                    sampleRate: profile.sampleRate, usedStageIDs: &usedStageIDs, to: &graph)
            }
        }

        // A global limiter is a terminal safety stage. Keep it after channel
        // processing even though it is persisted with the global chain.
        var regularGlobal = ProcessingChain(stages: processing.global.stages.filter {
            if case .limiter = $0.processor { return false }
            return true
        })
        // Canonical global semantics do not depend on which editor was used first.
        func rank(_ stage: ProcessingStage) -> Int {
            switch stage.processor {
            case .deviceCorrection: return 0
            case .gain: return 1
            case .equalizer: return 2
            case .convolution: return 3
            case .delay: return 4
            case .crossfeed: return 5
            case .limiter: return 6
            }
        }
        regularGlobal.stages = regularGlobal.stages.enumerated().sorted {
            let lhs = rank($0.element), rhs = rank($1.element)
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
        let tone = try SimpleToneFilterFactory.filters(for: processing.simpleTone, sampleRate: Double(profile.sampleRate))
        if !processing.simpleTone.isNeutral {
            let insertion = regularGlobal.stages.firstIndex {
                switch $0.processor { case .convolution, .crossfeed: return true; default: return false }
            } ?? regularGlobal.stages.count
            regularGlobal.stages.insert(ProcessingStage(id: SimpleToneFilterFactory.stageID,
                processor: .equalizer(EqualizerProcessor(bands: tone))), at: insertion)
        }
        try append(
            regularGlobal,
            identifierScope: "global",
            pipelineScope: .global,
            channels: Array(0..<channelCount),
            sampleRate: profile.sampleRate,
            correspondingChannels: profile.configuredProcessingChannels,
            usedStageIDs: &usedStageIDs,
            to: &graph
        )

        guard Set(processing.groups.map(\.id)).count == processing.groups.count else {
            throw ProfileSettingsError.runtime("Group processing identities must be unique.")
        }
        // Phase 5 maps the compact DSP bus into physical slots at graph ingress.
        // Group content processing therefore targets explicit member slots here,
        // after global content and before each physical output's calibration.
        let configuredGroups = profile.configuredSpeakerGroups
        let activeGroups = processing.groups.sorted { $0.id.rawValue < $1.id.rawValue }.compactMap { group -> (GroupProcessing, [Int])? in
            guard let members = configuredGroups.first(where: { $0.id == group.id })?.members else { return nil }
            return (group, members.map(\.channelIndex).sorted())
        }
        for (group, channels) in activeGroups {
            var regular = ProcessingChain(stages: group.chain.stages.filter {
                if case .limiter = $0.processor { return false }; return true
            })
            let tone = group.chain.simpleTone ?? SimpleToneSettings()
            let bands = try SimpleToneFilterFactory.filters(for: tone, sampleRate: Double(profile.sampleRate))
            if !tone.isNeutral {
                let insertion = regular.stages.firstIndex {
                    switch $0.processor { case .convolution, .delay, .crossfeed: return true; default: return false }
                } ?? regular.stages.endIndex
                regular.stages.insert(ProcessingStage(id: group.id.stageID("tone"),
                    processor: .equalizer(EqualizerProcessor(bands: bands))), at: insertion)
            }
            try append(regular, identifierScope: "group_\(compact(group.id.stageID("scope")))",
                pipelineScope: .group(group.id), channels: channels, sampleRate: profile.sampleRate,
                usedStageIDs: &usedStageIDs, to: &graph)
        }

        var usedChannelIndexes = Set<Int>()
        for channel in processing.channels.sorted(by: { $0.index < $1.index }) {
            if profile.hasPhysicalSpeakerRoute, !profile.configuredProcessingChannels.contains(where: { $0.index == channel.index }) { continue }
            if profile.hasPhysicalSpeakerRoute && channel.index >= channelCount && channel.chain.stages.isEmpty { continue }
            guard (0..<channelCount).contains(channel.index) else {
                throw ProcessingGraphError.channelOutOfRange(channel.index, channelCount)
            }
            guard usedChannelIndexes.insert(channel.index).inserted else {
                throw ProcessingGraphError.duplicateChannel(channel.index)
            }
            // Each channel limiter is terminal within that channel path. A
            // separately enabled global limiter still runs after every channel.
            var regularChannel = ProcessingChain(stages: channel.chain.stages.filter {
                if case .limiter = $0.processor { return false }
                return true
            })
            let channelTone = channel.chain.simpleTone ?? SimpleToneSettings()
            let channelToneBands = try SimpleToneFilterFactory.filters(
                for: channelTone, sampleRate: Double(profile.sampleRate)
            )
            if !channelTone.isNeutral {
                let insertion = regularChannel.stages.firstIndex {
                    switch $0.processor { case .convolution, .delay, .crossfeed: return true; default: return false }
                } ?? regularChannel.stages.endIndex
                regularChannel.stages.insert(ProcessingStage(
                    id: ProcessingProfile.toneStageID(forChannel: channel.index),
                    processor: .equalizer(EqualizerProcessor(bands: channelToneBands))
                ), at: insertion)
            }
            try append(
                regularChannel,
                identifierScope: "channel_\(channel.index)",
                pipelineScope: .channel(index: channel.index, role: channel.role),
                channels: [channel.index],
                sampleRate: profile.sampleRate,
                usedStageIDs: &usedStageIDs,
                to: &graph
            )
            let channelLimiters = ProcessingChain(stages: channel.chain.stages.filter {
                if case .limiter = $0.processor { return true }
                return false
            })
            try append(
                channelLimiters,
                identifierScope: "channel_\(channel.index)",
                pipelineScope: .channel(index: channel.index, role: channel.role),
                channels: [channel.index],
                sampleRate: profile.sampleRate,
                usedStageIDs: &usedStageIDs,
                to: &graph
            )
        }

        // Group limiters protect each member after its individual processing.
        for (group, channels) in activeGroups {
            let limiters = ProcessingChain(stages: group.chain.stages.filter {
                if case .limiter = $0.processor { return true }; return false
            })
            try append(limiters, identifierScope: "group_\(compact(group.id.stageID("scope")))",
                pipelineScope: .group(group.id), channels: channels, sampleRate: profile.sampleRate,
                usedStageIDs: &usedStageIDs, to: &graph)
        }
        let terminalLimiters = ProcessingChain(stages: processing.global.stages.filter {
            if case .limiter = $0.processor { return true }
            return false
        })
        try append(
            terminalLimiters,
            identifierScope: "global",
            pipelineScope: .global,
            channels: Array(0..<channelCount),
            sampleRate: profile.sampleRate,
            usedStageIDs: &usedStageIDs,
            to: &graph
        )

        // User preamp has a reserved semantic identity. It is an intentional
        // volume control, so automatic headroom must not cancel it. Other
        // present and future gains, including per-channel gain, remain part of
        // the safety calculation regardless of their position in the chain.
        let userPreampStageID = processing.global.stages.first(where: { stage in
            guard stage.id == ProcessingProfile.userPreampStageID else { return false }
            if case .gain = stage.processor { return true }
            return false
        })?.id
        graph.automaticHeadroomDB = ProcessingGraphHeadroomCalculator().calculate(
            for: graph,
            excludingGainStageIDs: Set(userPreampStageID.map { [$0] } ?? [])
        )
        // Keep this processor present even at 0 dB so crossing the headroom
        // boundary remains a WebSocket value patch, not a topology replacement.
        graph.processors.insert(.init(
            id: ProcessingGraph.automaticHeadroomProcessorID,
            sourceStageID: ProcessingGraph.automaticHeadroomStageID,
            implementation: .gain(db: graph.automaticHeadroomDB)
        ), at: 0)
        graph.pipeline.insert(.init(
            id: ProcessingGraph.automaticHeadroomStageID,
            scope: .global,
            channels: Array(0..<channelCount),
            processorIDs: [ProcessingGraph.automaticHeadroomProcessorID]
        ), at: 0)

        if let assignment = try profile.validatedInterfaceConfiguration() {
            let outputs = try profile.validatedInterfaceOutputIndices() ?? []
            graph.playback.channelCount = assignment.hardwareChannelCount
            let mixerID = "interface_output_assignment"
            let stageID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            graph.mixers.append(.init(id: mixerID, sourceStageID: stageID,
                inputChannelCount: channelCount, outputChannelCount: assignment.hardwareChannelCount,
                mappings: outputs.enumerated().map { logical, physical in
                    .init(destination: physical, sources: [.init(channel: profile.hasPhysicalSpeakerRoute ? physical : logical)])
                }))
            graph.pipeline.append(.init(id: stageID, kind: .mixer(id: mixerID), scope: .global,
                channels: [], processorIDs: []))
        }
        try graph.validate()
        return graph
    }

    private func append(
        _ chain: ProcessingChain,
        identifierScope: String,
        pipelineScope: ProcessingGraph.PipelineStep.Scope,
        channels: [Int],
        sampleRate: Int,
        correspondingChannels: [ConfiguredProcessingChannel]? = nil,
        usedStageIDs: inout Set<UUID>,
        to graph: inout ProcessingGraph
    ) throws {
        for stage in chain.stages {
            guard usedStageIDs.insert(stage.id).inserted else {
                throw ProcessingGraphError.duplicateStage(stage.id)
            }
            guard stage.isEnabled else { continue }

            let processors: [ProcessingGraph.Processor]
            switch stage.processor {
            case .gain(let gain):
                guard gain.gainDB.isFinite else {
                    throw ProcessingGraphError.nonFiniteValue("gain")
                }
                // A gain stage is part of the graph's identity even at 0 dB.
                // Keeping it present means crossing zero can use a value-only
                // WebSocket patch instead of replacing the whole configuration.
                processors = [
                    .init(
                        id: processorID(scope: identifierScope, stageID: stage.id, suffix: "gain"),
                        sourceStageID: stage.id,
                        implementation: .gain(db: gain.gainDB)
                    )
                ]
            case .equalizer(let equalizer):
                try validateUniqueBandIDs(equalizer.bands)
                // Biquads in a serial EQ commute. Compile them in stable UUID
                // order so UI frequency sorting cannot rename processors and
                // accidentally turn an ordinary edit into a topology change.
                processors = try equalizer.bands
                    .filter(\.enabled)
                    .sorted { compact($0.id) < compact($1.id) }
                    .map { band in
                    try validate(band: band, sampleRate: sampleRate)
                    return .init(
                        id: processorID(
                            scope: identifierScope,
                            stageID: stage.id,
                            suffix: "eq_\(compact(band.id))"
                        ),
                        sourceStageID: stage.id,
                        implementation: .biquad(band)
                    )
                }
            case .deviceCorrection(let correction):
                guard correction.schemaVersion == DeviceCorrectionProfile.currentSchemaVersion else {
                    throw ProcessingGraphError.unsupportedCorrectionSchemaVersion(
                        correction.schemaVersion
                    )
                }
                if let provenance = correction.speakerProvenance {
                    try SpeakerCorrectionValidator().validate(correction.filters, settings: provenance.settings, sampleRate: Double(sampleRate))
                }
                var correctionProcessors: [ProcessingGraph.Processor] = []
                try validateUniqueBandIDs(correction.filters)
                // preampDB in legacy correction profiles was an automatic
                // correction-only estimate. The graph-wide runtime headroom
                // stage supersedes it; it must not become user tonal gain.
                for band in correction.filters
                    .filter(\.enabled)
                    .sorted(by: { compact($0.id) < compact($1.id) }) {
                    try validate(band: band, sampleRate: sampleRate)
                    correctionProcessors.append(.init(
                        id: processorID(
                            scope: identifierScope,
                            stageID: stage.id,
                            suffix: "correction_eq_\(compact(band.id))"
                        ),
                        sourceStageID: stage.id,
                        implementation: .biquad(band)
                    ))
                }
                processors = correctionProcessors
            case .convolution(let convolution):
                if convolution.usesCorrespondingChannels {
                    guard case .global = pipelineScope, let correspondingChannels else {
                        throw ProfileSettingsError.runtime("Corresponding WAV channels is available only for All Channels FIR correction.")
                    }
                    let assignments = try ImpulseResponseAssignmentPlanner().resolvedAssignments(
                        for: convolution, channels: correspondingChannels, sampleRate: sampleRate)
                    for assignment in assignments {
                        let runtime = try validate(convolution: .init(asset: convolution.asset,
                            impulseChannel: assignment.impulseChannel), sampleRate: sampleRate)
                        let id = processorID(scope: identifierScope, stageID: stage.id,
                            suffix: "convolution_\(assignment.outputChannel)")
                        graph.processors.append(.init(id: id, sourceStageID: stage.id, implementation: .convolution(runtime)))
                        // These IRs belong to physical outputs. Keep them after
                        // source routing when the multichannel compiler splits buses.
                        let role = correspondingChannels.first { $0.index == assignment.outputChannel }!.role
                        graph.pipeline.append(.init(id: stage.id, scope: .channel(index: assignment.outputChannel, role: role),
                            channels: [assignment.outputChannel], processorIDs: [id]))
                    }
                    continue
                }
                let runtime = try validate(
                    convolution: convolution,
                    sampleRate: sampleRate
                )
                processors = [
                    .init(
                        id: processorID(
                            scope: identifierScope,
                            stageID: stage.id,
                            suffix: "convolution"
                        ),
                        sourceStageID: stage.id,
                        implementation: .convolution(runtime)
                    )
                ]
            case .crossfeed(let crossfeed):
                try appendCrossfeed(
                    crossfeed,
                    stageID: stage.id,
                    identifierScope: identifierScope,
                    pipelineScope: pipelineScope,
                    sampleRate: sampleRate,
                    to: &graph
                )
                continue
            case .delay(let delay):
                if case .global = pipelineScope {
                    throw ProcessingGraphError.delayMustBePerChannel
                }
                guard delay.milliseconds.isFinite,
                      (0...100).contains(delay.milliseconds) else {
                    throw ProcessingGraphError.invalidChannelDelay(delay.milliseconds)
                }
                processors = [
                    .init(
                        id: processorID(
                            scope: identifierScope,
                            stageID: stage.id,
                            suffix: "delay"
                        ),
                        sourceStageID: stage.id,
                        implementation: .delay(
                            milliseconds: delay.milliseconds,
                            subsample: true
                        )
                    )
                ]
            case .limiter(let limiter):
                guard limiter.clipLimitDB.isFinite,
                      limiter.clipLimitDB <= 0 else {
                    throw ProcessingGraphError.invalidLimiterCeiling(
                        limiter.clipLimitDB
                    )
                }
                processors = [
                    .init(
                        id: processorID(
                            scope: identifierScope,
                            stageID: stage.id,
                            suffix: "limiter"
                        ),
                        sourceStageID: stage.id,
                        implementation: .limiter(limiter)
                    )
                ]
            }

            guard !processors.isEmpty else { continue }
            graph.processors.append(contentsOf: processors)
            graph.pipeline.append(.init(
                id: stage.id,
                scope: pipelineScope,
                channels: channels,
                processorIDs: processors.map(\.id)
            ))
        }
    }

    private func validate(band: EQBand, sampleRate: Int) throws {
        guard band.frequency.isFinite else {
            throw ProcessingGraphError.nonFiniteValue("filter frequency")
        }
        guard band.frequency > 0, band.frequency < Double(sampleRate) / 2 else {
            throw ProcessingGraphError.invalidFilterFrequency(band.frequency, sampleRate)
        }
        if let gain = band.gain, !gain.isFinite {
            throw ProcessingGraphError.nonFiniteValue("filter gain")
        }
        if let q = band.q, (!q.isFinite || q <= 0) {
            throw ProcessingGraphError.invalidFilterQ(q)
        }
        if let bandwidth = band.bandwidth, (!bandwidth.isFinite || bandwidth <= 0) {
            throw ProcessingGraphError.invalidFilterBandwidth(bandwidth)
        }
        switch band.kind {
        case .peaking:
            guard band.gain != nil else {
                throw ProcessingGraphError.missingFilterGain(band.kind)
            }
            guard band.q != nil || band.bandwidth != nil else {
                throw ProcessingGraphError.missingFilterShape(band.kind)
            }
        case .lowShelf, .highShelf:
            guard band.gain != nil else {
                throw ProcessingGraphError.missingFilterGain(band.kind)
            }
        case .allPass:
            guard band.q != nil || band.bandwidth != nil else {
                throw ProcessingGraphError.missingFilterShape(band.kind)
            }
        case .lowPass, .highPass, .notch:
            break
        }
    }

    private func validateUniqueBandIDs(_ bands: [EQBand]) throws {
        var usedIDs = Set<UUID>()
        for band in bands where !usedIDs.insert(band.id).inserted {
            throw ProcessingGraphError.duplicateFilter(band.id)
        }
    }

    private func validate(
        convolution: ConvolutionProcessor,
        sampleRate: Int
    ) throws -> ProcessingGraph.Processor.Implementation.Convolution {
        let asset = convolution.asset
        let expectedFileName = "\(asset.id.uuidString.lowercased()).wav"
        guard asset.fileName == expectedFileName,
              URL(fileURLWithPath: asset.fileName).lastPathComponent == asset.fileName else {
            throw ProcessingGraphError.invalidImpulseResponseReference(asset.fileName)
        }
        guard asset.sampleRate == sampleRate else {
            throw ProcessingGraphError.impulseResponseSampleRateMismatch(
                asset.sampleRate,
                sampleRate
            )
        }
        guard asset.channelCount > 0,
              asset.frameCount > 0,
              asset.maximumMagnitudeDBByChannel.count == asset.channelCount,
              asset.maximumMagnitudeDBByChannel.allSatisfy(\.isFinite) else {
            throw ProcessingGraphError.invalidImpulseResponseMetadata
        }
        guard (0..<asset.channelCount).contains(convolution.impulseChannel) else {
            throw ProcessingGraphError.impulseResponseChannelOutOfRange(
                convolution.impulseChannel,
                asset.channelCount
            )
        }
        guard let prepared = preparedAssets.impulseResponses[asset.id], prepared.metadata == asset else {
            throw ProcessingGraphError.impulseResponseMissing(asset.displayName)
        }
        return .init(filePath: prepared.url.path, channel: convolution.impulseChannel,
                     maximumMagnitudeDB: asset.maximumMagnitudeDBByChannel[convolution.impulseChannel],
                     contentSHA256: prepared.sha256)
    }

    private func appendCrossfeed(
        _ crossfeed: CrossfeedProcessor,
        stageID: UUID,
        identifierScope: String,
        pipelineScope: ProcessingGraph.PipelineStep.Scope,
        sampleRate: Int,
        to graph: inout ProcessingGraph
    ) throws {
        guard case .global = pipelineScope else {
            throw ProcessingGraphError.crossfeedMustBeGlobal
        }
        guard channelCount == 2 else {
            throw ProcessingGraphError.crossfeedRequiresStereo(channelCount)
        }
        guard crossfeed.amountPercent.isFinite,
              (0...100).contains(crossfeed.amountPercent) else {
            throw ProcessingGraphError.invalidCrossfeedAmount(crossfeed.amountPercent)
        }
        guard crossfeed.delayMilliseconds.isFinite,
              (0...5).contains(crossfeed.delayMilliseconds) else {
            throw ProcessingGraphError.invalidCrossfeedDelay(crossfeed.delayMilliseconds)
        }
        guard crossfeed.cutoffFrequency.isFinite,
              crossfeed.cutoffFrequency > 0,
              crossfeed.cutoffFrequency < Double(sampleRate) / 2 else {
            throw ProcessingGraphError.invalidCrossfeedFrequency(
                crossfeed.cutoffFrequency,
                sampleRate
            )
        }

        let splitID = processorID(
            scope: identifierScope,
            stageID: stageID,
            suffix: "crossfeed_split"
        )
        let mergeID = processorID(
            scope: identifierScope,
            stageID: stageID,
            suffix: "crossfeed_merge"
        )
        let lowpassID = processorID(
            scope: identifierScope,
            stageID: stageID,
            suffix: "crossfeed_lowpass"
        )
        let delayID = processorID(
            scope: identifierScope,
            stageID: stageID,
            suffix: "crossfeed_delay"
        )
        let gainID = processorID(
            scope: identifierScope,
            stageID: stageID,
            suffix: "crossfeed_gain"
        )

        graph.mixers.append(contentsOf: [
            .init(
                id: splitID,
                sourceStageID: stageID,
                inputChannelCount: 2,
                outputChannelCount: 4,
                mappings: [
                    .init(destination: 0, sources: [.init(channel: 0)]),
                    .init(destination: 1, sources: [.init(channel: 1)]),
                    .init(destination: 2, sources: [.init(channel: 1)]),
                    .init(destination: 3, sources: [.init(channel: 0)])
                ]
            ),
            .init(
                id: mergeID,
                sourceStageID: stageID,
                inputChannelCount: 4,
                outputChannelCount: 2,
                mappings: [
                    .init(
                        destination: 0,
                        sources: [.init(channel: 0), .init(channel: 2)]
                    ),
                    .init(
                        destination: 1,
                        sources: [.init(channel: 1), .init(channel: 3)]
                    )
                ]
            )
        ])
        let processors: [ProcessingGraph.Processor] = [
            .init(
                id: lowpassID,
                sourceStageID: stageID,
                implementation: .firstOrderLowpass(
                    frequency: crossfeed.cutoffFrequency
                )
            ),
            .init(
                id: delayID,
                sourceStageID: stageID,
                implementation: .delay(
                    milliseconds: crossfeed.delayMilliseconds,
                    subsample: true
                )
            ),
            .init(
                id: gainID,
                sourceStageID: stageID,
                implementation: .crossfeedGain(
                    db: crossfeed.crossfeedGainDB,
                    muted: crossfeed.amountPercent == 0,
                    maximumBoostDB: crossfeed.maximumBoostDB
                )
            )
        ]
        graph.processors.append(contentsOf: processors)
        graph.pipeline.append(contentsOf: [
            .init(
                id: stageID,
                kind: .mixer(id: splitID),
                scope: pipelineScope,
                channels: [],
                processorIDs: []
            ),
            .init(
                id: stageID,
                scope: pipelineScope,
                channels: [2, 3],
                processorIDs: processors.map(\.id)
            ),
            .init(
                id: stageID,
                kind: .mixer(id: mergeID),
                scope: pipelineScope,
                channels: [],
                processorIDs: []
            )
        ])
    }

    private func processorID(scope: String, stageID: UUID, suffix: String) -> String {
        "\(scope)_\(compact(stageID))_\(suffix)"
    }

    private func compact(_ id: UUID) -> String {
        id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}

/// Finds the largest boost produced by response-shaping processing that reaches
/// each output channel. This covers global EQ, per-channel gain/EQ, and legacy
/// correction stages while keeping the intentional User preamp independent.
package struct ProcessingGraphHeadroomCalculator {
    package init() {}

    package func calculate(
        for graph: ProcessingGraph,
        pointCount: Int = 1_200,
        excludingGainStageIDs: Set<UUID> = []
    ) -> Double {
        guard let outputs = peakOutputMagnitudes(for: graph, pointCount: pointCount,
                excludingGainStageIDs: excludingGainStageIDs) else { return .nan }
        return -20 * log10(max(1, outputs.max() ?? 1))
    }

    /// Per-output conservative response bounds, retaining attenuation for driver
    /// protection. The ordinary headroom result above never adds positive gain.
    package func peakOutputMagnitudes(for graph: ProcessingGraph, pointCount: Int = 1_200,
                              excludingGainStageIDs: Set<UUID> = [], includingAutomaticHeadroom: Bool = false) -> [Double]? {
        guard graph.channelCount > 0, pointCount > 0 else { return nil }
        let response = EQResponseCalculator()
        let frequencies = response.calculate(parsed: ParsedEQ(preampDB: 0), sampleRate: Double(graph.sampleRate), count: pointCount).map(\.frequency)
        var magnitudes: [String: [Double]] = [:]
        for processor in graph.processors {
            var parsed = ParsedEQ(preampDB: 0)
            var constant = 1.0
            switch processor.implementation {
            case .gain(let db):
                if (includingAutomaticHeadroom || processor.id != ProcessingGraph.automaticHeadroomProcessorID) && !excludingGainStageIDs.contains(processor.sourceStageID) { parsed.preampDB = db }
            case .biquad(let band): parsed.bands = [band]
            case .convolution(let fir): parsed.preampDB = max(0, fir.maximumMagnitudeDB)
            case .crossfeedGain(_, _, let maximumBoostDB): constant = max(0, pow(10, maximumBoostDB / 20) - 1)
            case .delay, .firstOrderLowpass, .limiter: break
            }
            magnitudes[processor.id] = frequencies.map {
                constant * pow(10, response.gainDB(at: $0, parsed: parsed, sampleRate: Double(graph.sampleRate)) / 20)
            }
        }
        let mixers = Dictionary(graph.mixers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var peaks = [Double](repeating: 0, count: graph.outputFormat.channelCount)
        for frequency in frequencies.indices {
            var envelope = [Double](repeating: 1, count: graph.inputFormat.channelCount)
            for step in graph.pipeline {
                switch step.kind {
                case .filter:
                    for channel in step.channels where envelope.indices.contains(channel) {
                        for id in step.processorIDs { envelope[channel] *= magnitudes[id]?[frequency] ?? 1 }
                    }
                case .mixer(let id):
                    guard let mixer = mixers[id], mixer.inputChannelCount == envelope.count, mixer.outputChannelCount > 0 else { return nil }
                    var mixed = [Double](repeating: 0, count: mixer.outputChannelCount)
                    for mapping in mixer.mappings {
                        guard mixed.indices.contains(mapping.destination) else { return nil }
                        for source in mapping.sources where !source.muted {
                            guard envelope.indices.contains(source.channel) else { return nil }
                            // Magnitude sums bound coherent signals without relying on
                            // phase cancellation. Fan-out and sparse silent slots retain
                            // their own envelopes through later filters and merges.
                            mixed[mapping.destination] += envelope[source.channel] * pow(10, source.gainDB / 20)
                        }
                    }
                    envelope = mixed
                }
            }
            guard envelope.allSatisfy(\.isFinite) else { return nil }
            guard envelope.count == peaks.count else { return nil }
            for channel in peaks.indices { peaks[channel] = max(peaks[channel], envelope[channel]) }
        }
        return peaks
    }
}
