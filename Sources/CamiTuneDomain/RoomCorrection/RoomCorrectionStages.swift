import Foundation

extension ProcessingProfile {
    package static let roomFIRStageID = UUID(uuidString: "CA117B70-0000-4000-8000-000000000052")!
    package static func roomEQStageID(channel: Int) -> UUID { roomStageID(channel: channel, kind: 1) }
    package static func roomFIRStageID(channel: Int) -> UUID { roomStageID(channel: channel, kind: 2) }
    private static func roomStageID(channel: Int, kind: Int) -> UUID {
        UUID(uuidString: String(format: "CA117B71-0000-4000-%04X-%012X", kind, max(0, channel)))!
    }
    package static func isRoomStage(_ id: UUID) -> Bool {
        id == spatialRoomCorrectionStageID || id == roomFIRStageID || id.uuidString.hasPrefix("CA117B71-")
    }
    package mutating func removeRoomStages() {
        global.stages.removeAll { Self.isRoomStage($0.id) }
        for i in channels.indices { channels[i].chain.stages.removeAll { Self.isRoomStage($0.id) } }
    }
    package mutating func materializeRoomCorrection(_ result: RoomCorrectionResult?) {
        removeRoomStages()
        guard let result else { return }
        global.setEqualizer(result.sharedBands.isEmpty ? nil : result.sharedBands, stageID: Self.spatialRoomCorrectionStageID)
        for channel in Set(result.channelBands.keys).union(result.channelFIR.keys).sorted() {
            if !channels.contains(where: { $0.index == channel }) { channels.append(.init(index: channel, role: .unknown, chain: .init())) }
            guard let index = channels.firstIndex(where: { $0.index == channel }) else { continue }
            let bands = result.channelBands[channel] ?? []
            channels[index].chain.setEqualizer(bands.isEmpty ? nil : bands, stageID: Self.roomEQStageID(channel: channel))
            channels[index].chain.setConvolution(result.channelFIR[channel], stageID: Self.roomFIRStageID(channel: channel))
        }
    }
}
extension ProcessingChain {
    /// Exact semantic identity; does not adopt, delete or reorder another feature's stage.
    package mutating func setEqualizer(_ bands: [EQBand]?, stageID: UUID, enabled: Bool = true) {
        setManagedProcessor(bands.map { .equalizer(.init(bands: $0)) }, stageID: stageID, enabled: enabled)
    }
    package mutating func setConvolution(_ processor: ConvolutionProcessor?, stageID: UUID, enabled: Bool = true) {
        setManagedProcessor(processor.map { .convolution($0) }, stageID: stageID, enabled: enabled)
    }
    private mutating func setManagedProcessor(_ processor: ProcessingStage.Processor?, stageID: UUID, enabled: Bool) {
        if let index = stages.firstIndex(where: { $0.id == stageID }) {
            guard let processor else { stages.remove(at: index); return }
            stages[index].processor = processor; stages[index].isEnabled = enabled
        } else if let processor {
            let insertion = stages.firstIndex {
                switch $0.processor { case .delay, .crossfeed, .limiter: return true; default: return false }
            } ?? stages.endIndex
            stages.insert(.init(id: stageID, isEnabled: enabled, processor: processor), at: insertion)
        }
    }
}
extension DeviceProfile {
    /// Reset only room correction for the selected listening position. Speaker
    /// geometry/alignment and user processing have independent ownership.
    package mutating func resetRoomCorrection() {
        if var seat = spatialSettings.seating {
            seat.roomCorrectionBands = []; seat.roomCorrectionTopology = nil
            seat.roomCorrectionEnabled = false; seat.roomCorrectionSessionID = nil
            seat.roomCorrectionSettings = .init(); seat.roomCorrectionResult = nil
            seat.roomCorrectionRevision += 1
            spatialSettings.seating = seat
        }
        processing.removeRoomStages()
        for id in physicalChannelProcessing.keys {
            physicalChannelProcessing[id]?.stages.removeAll { ProcessingProfile.isRoomStage($0.id) }
        }
        synchronizeListeningPositionCorrection()
    }
    package func roomMeasurementContext() throws -> RoomMeasurementContext {
        guard let topology = speakerTopology, try validatedPhysicalSpeakerTopology() != nil else { throw RoomCorrectionError.routeUnavailable }
        var base = try baseResolvedProcessing(); base.removeRoomStages()
        // Empty channel chains and presentation metadata must not invalidate acoustics.
        base.channels = configuredProcessingChannels.map { configured in
            .init(index: configured.index, role: configured.role,
                  chain: base.channels.first(where: { $0.index == configured.index })?.chain ?? .init())
        }.sorted { $0.index < $1.index }
        let seat = effectiveSpatialSettings.seating
        var context = RoomMeasurementContext(topology: topology, listener: .init(x: seat?.roomX ?? 0, y: seat?.roomY ?? 0, z: 0), processing: base)
        context.multichannel = multichannel
        return context
    }
    package var roomCorrectionIsStale: Bool {
        guard let seat = effectiveSpatialSettings.seating else { return false }
        guard let result = seat.roomCorrectionResult else {
            return hasPhysicalSpeakerRoute && !seat.roomCorrectionBands.isEmpty && seat.roomCorrectionTopology != speakerTopology
        }
        return (try? roomMeasurementContext()) != result.context
            || result.optimizerVersion != RoomCorrectionResult.currentOptimizerVersion
            || result.firGeneratorVersion != RoomCorrectionResult.currentFIRGeneratorVersion
    }
}
