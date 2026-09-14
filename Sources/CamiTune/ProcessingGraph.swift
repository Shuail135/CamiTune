import Foundation

/// A validated, runtime-oriented graph. It contains no UI, import-format, or
/// CamillaDSP YAML concerns and is therefore suitable for alternate backends.
struct ProcessingGraph: Hashable, Sendable {
    static let automaticHeadroomStageID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 1
    ))
    static let automaticHeadroomProcessorID = "system_automatic_headroom"

    var title: String
    var sampleRate: Int
    var chunkSize: Int
    var channelCount: Int
    var capture: CaptureEndpoint
    var playback: PlaybackEndpoint
    /// Runtime-only protection derived from response-shaping and per-channel
    /// processing. Intentional user-preamp gain is kept independent, and this
    /// value is deliberately not part of the persisted processing profile.
    var automaticHeadroomDB: Double
    var processors: [Processor]
    var mixers: [Mixer]
    var pipeline: [PipelineStep]

    struct CaptureEndpoint: Hashable, Sendable {
        var format: SampleFormat
    }

    struct PlaybackEndpoint: Hashable, Sendable {
        var deviceUID: String
        var channelCount: Int? = nil
        var exclusive: Bool
    }

    enum SampleFormat: String, Hashable, Sendable {
        case interleavedFloat32LittleEndian
    }

    struct Processor: Identifiable, Hashable, Sendable {
        var id: String
        var sourceStageID: UUID
        var implementation: Implementation

        enum Implementation: Hashable, Sendable {
            case gain(db: Double)
            case biquad(EQBand)
            case convolution(Convolution)
            case delay(milliseconds: Double, subsample: Bool)
            case firstOrderLowpass(frequency: Double)
            case crossfeedGain(db: Double, muted: Bool, maximumBoostDB: Double)
            case limiter(LimiterProcessor)

            struct Convolution: Hashable, Sendable {
                var filePath: String
                var channel: Int
                var maximumMagnitudeDB: Double
            }
        }
    }

    struct Mixer: Identifiable, Hashable, Sendable {
        var id: String
        var sourceStageID: UUID
        var inputChannelCount: Int
        var outputChannelCount: Int
        var mappings: [Mapping]

        struct Mapping: Hashable, Sendable {
            var destination: Int
            var sources: [Source]
        }

        struct Source: Hashable, Sendable {
            var channel: Int
            var gainDB: Double = 0
        }
    }

    struct PipelineStep: Identifiable, Hashable, Sendable {
        var id: UUID
        var kind: Kind = .filter
        var scope: Scope
        var channels: [Int]
        var processorIDs: [String]

        enum Kind: Hashable, Sendable {
            case filter
            case mixer(id: String)
        }

        enum Scope: Hashable, Sendable {
            case global
            case channel(index: Int, role: ChannelRole)
        }
    }
}

struct ProcessingGraphBuilder {
    let channelCount: Int
    let impulseResponseStore: ImpulseResponseStore

    init(
        channelCount: Int = 2,
        impulseResponseDirectory: URL = CamiTunePaths.impulseResponsesDirectory
    ) {
        self.channelCount = channelCount
        self.impulseResponseStore = ImpulseResponseStore(directory: impulseResponseDirectory)
    }

    func build(profile: DeviceProfile) throws -> ProcessingGraph {
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
            processing.global.stages.removeAll { $0.id == SpatialRoomCorrection.stageID }
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
                try append(ProcessingChain(stages: [ProcessingStage(id: SpatialRoomCorrection.stageID,
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
            usedStageIDs: &usedStageIDs,
            to: &graph
        )

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
                regularChannel.stages.append(ProcessingStage(
                    id: ProcessingProfile.toneStageID(forChannel: channel.index),
                    processor: .equalizer(EqualizerProcessor(bands: channelToneBands))
                ))
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
            graph.playback.channelCount = assignment.hardwareChannelCount
            let mixerID = "interface_output_assignment"
            let stageID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            graph.mixers.append(.init(id: mixerID, sourceStageID: stageID,
                inputChannelCount: channelCount, outputChannelCount: assignment.hardwareChannelCount,
                mappings: assignment.outputChannels.enumerated().map { logical, physical in
                    .init(destination: physical, sources: [.init(channel: profile.hasPhysicalSpeakerRoute ? physical : logical)])
                }))
            graph.pipeline.append(.init(id: stageID, kind: .mixer(id: mixerID), scope: .global,
                channels: [], processorIDs: []))
        }
        return graph
    }

    private func append(
        _ chain: ProcessingChain,
        identifierScope: String,
        pipelineScope: ProcessingGraph.PipelineStep.Scope,
        channels: [Int],
        sampleRate: Int,
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
                guard case .channel = pipelineScope else {
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
        let url = impulseResponseStore.url(for: asset)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw ProcessingGraphError.impulseResponseMissing(asset.displayName)
        }
        return .init(
            filePath: url.path,
            channel: convolution.impulseChannel,
            maximumMagnitudeDB: asset.maximumMagnitudeDBByChannel[convolution.impulseChannel]
        )
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
struct ProcessingGraphHeadroomCalculator {
    func calculate(
        for graph: ProcessingGraph,
        pointCount: Int = 1_200,
        excludingGainStageIDs: Set<UUID> = []
    ) -> Double {
        guard graph.channelCount > 0 else { return 0 }
        let processors = Dictionary(graph.processors.map { ($0.id, $0) }, uniquingKeysWith: {
            // GraphBuilder rejects duplicate IDs. Keeping this calculation
            // total also makes manually constructed test/future graphs safe.
            first, _ in first
        })
        let response = EQResponseCalculator()
        let crossfeedBoostDB = graph.processors.reduce(0.0) { result, processor in
            guard case .crossfeedGain(_, _, let maximumBoostDB) = processor.implementation else {
                return result
            }
            return result + maximumBoostDB
        }
        var largestBoost = 0.0

        for channel in 0..<graph.channelCount {
            var parsed = ParsedEQ(preampDB: crossfeedBoostDB)
            for step in graph.pipeline where step.kind == .filter
                && step.channels.contains(channel) {
                for processorID in step.processorIDs {
                    guard processorID != ProcessingGraph.automaticHeadroomProcessorID else {
                        continue
                    }
                    guard let processor = processors[processorID] else { continue }
                    switch processor.implementation {
                    case .gain(let db):
                        guard !excludingGainStageIDs.contains(processor.sourceStageID) else {
                            continue
                        }
                        parsed.preampDB += db
                    case .biquad(let band):
                        parsed.bands.append(band)
                    case .convolution(let convolution):
                        // Sum the FIR maximum with the exact IIR response as a
                        // conservative bound for the cascaded response.
                        parsed.preampDB += max(0, convolution.maximumMagnitudeDB)
                    case .delay, .firstOrderLowpass, .crossfeedGain:
                        break
                    case .limiter:
                        break
                    }
                }
            }
            for point in response.calculate(
                parsed: parsed,
                sampleRate: Double(graph.sampleRate),
                count: pointCount
            ) {
                largestBoost = max(largestBoost, point.gainDB)
            }
        }
        guard largestBoost.isFinite else { return 0 }
        return -max(0, largestBoost)
    }
}

enum ProcessingGraphError: LocalizedError, Equatable {
    case invalidSampleRate
    case invalidChunkSize
    case invalidChannelCount
    case unsupportedSchemaVersion(Int)
    case unsupportedCorrectionSchemaVersion(Int)
    case channelOutOfRange(Int, Int)
    case duplicateChannel(Int)
    case duplicateStage(UUID)
    case duplicateFilter(UUID)
    case nonFiniteValue(String)
    case invalidFilterFrequency(Double, Int)
    case invalidFilterQ(Double)
    case invalidFilterBandwidth(Double)
    case missingFilterGain(EQBand.Kind)
    case missingFilterShape(EQBand.Kind)
    case invalidImpulseResponseReference(String)
    case invalidImpulseResponseMetadata
    case impulseResponseSampleRateMismatch(Int, Int)
    case impulseResponseChannelOutOfRange(Int, Int)
    case impulseResponseMissing(String)
    case crossfeedMustBeGlobal
    case crossfeedRequiresStereo(Int)
    case invalidCrossfeedAmount(Double)
    case invalidCrossfeedDelay(Double)
    case invalidCrossfeedFrequency(Double, Int)
    case delayMustBePerChannel
    case invalidChannelDelay(Double)
    case invalidLimiterCeiling(Double)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            return "The processing sample rate must be greater than zero."
        case .invalidChunkSize:
            return "The processing chunk size must be greater than zero."
        case .invalidChannelCount:
            return "The processing graph must contain at least one channel."
        case .unsupportedSchemaVersion(let version):
            return "This processing profile uses unsupported schema version \(version)."
        case .unsupportedCorrectionSchemaVersion(let version):
            return "This device correction uses unsupported schema version \(version)."
        case .channelOutOfRange(let index, let count):
            return "Processing channel \(index) is outside the \(count)-channel audio layout."
        case .duplicateChannel(let index):
            return "Processing channel \(index) is defined more than once."
        case .duplicateStage(let id):
            return "Processing stage \(id.uuidString) is defined more than once in a chain."
        case .duplicateFilter(let id):
            return "Equalizer filter \(id.uuidString) is defined more than once in one stage."
        case .nonFiniteValue(let name):
            return "The \(name) must be a finite number."
        case .invalidFilterFrequency(let frequency, let sampleRate):
            return "Filter frequency \(frequency) Hz must be below the Nyquist frequency for \(sampleRate) Hz audio."
        case .invalidFilterQ(let q):
            return "Filter Q must be greater than zero (received \(q))."
        case .invalidFilterBandwidth(let bandwidth):
            return "Filter bandwidth must be greater than zero (received \(bandwidth))."
        case .missingFilterGain(let kind):
            return "The \(kind.rawValue) filter requires a gain value."
        case .missingFilterShape(let kind):
            return "The \(kind.rawValue) filter requires Q or bandwidth."
        case .invalidImpulseResponseReference(let fileName):
            return "The impulse-response asset reference \(fileName) is invalid."
        case .invalidImpulseResponseMetadata:
            return "The impulse-response metadata is invalid. Import the WAV again."
        case .impulseResponseSampleRateMismatch(let impulseRate, let processingRate):
            return "The impulse response is \(impulseRate) Hz, but this profile processes at \(processingRate) Hz. Import a matching WAV to avoid changing the correction response."
        case .impulseResponseChannelOutOfRange(let channel, let count):
            return "Impulse-response channel \(channel + 1) is outside the \(count)-channel WAV."
        case .impulseResponseMissing(let name):
            return "The managed impulse response “\(name)” is missing. Import the WAV again."
        case .crossfeedMustBeGlobal:
            return "Headphone crossfeed must be a global processing stage."
        case .crossfeedRequiresStereo(let channelCount):
            return "Headphone crossfeed requires stereo audio, but this graph has \(channelCount) channels."
        case .invalidCrossfeedAmount(let amount):
            return "Crossfeed amount must be between 0% and 100% (received \(amount)%)."
        case .invalidCrossfeedDelay(let delay):
            return "Crossfeed delay must be between 0 and 5 ms (received \(delay) ms)."
        case .invalidCrossfeedFrequency(let frequency, let sampleRate):
            return "Crossfeed frequency \(frequency) Hz must be positive and below the Nyquist frequency for \(sampleRate) Hz audio."
        case .delayMustBePerChannel:
            return "Channel delay must belong to one physical channel."
        case .invalidChannelDelay(let delay):
            return "Channel delay must be between 0 and 100 ms (received \(delay) ms)."
        case .invalidLimiterCeiling(let ceiling):
            return "Limiter ceiling must be a finite value at or below 0 dBFS (received \(ceiling))."
        }
    }
}
