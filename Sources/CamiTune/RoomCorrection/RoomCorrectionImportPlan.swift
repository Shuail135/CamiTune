import CamiTuneAudio
import CamiTuneDomain
import Foundation

/// Transfers calculated filters to the existing physical-channel editors.
/// Preparation does not change the profile or the active audio route.
struct RoomCorrectionImportPlan {
    let result: RoomCorrectionResult
    let bands: [Int: [EQBand]]
    let channels: [ConfiguredProcessingChannel]

    init(result: RoomCorrectionResult, profile: DeviceProfile) throws {
        channels = profile.configuredProcessingChannels
        let available = Set(channels.map(\.index))
        guard result.optimizerVersion == RoomCorrectionResult.currentOptimizerVersion,
              result.firGeneratorVersion == RoomCorrectionResult.currentFIRGeneratorVersion,
              result.context.topology.deviceUID == profile.outputDeviceUID,
              result.context.topology.sampleRate == Double(profile.sampleRate),
              result.channelFIR.values.allSatisfy({ $0.asset.sampleRate == profile.sampleRate }),
              Set(result.channelBands.keys).union(result.channelFIR.keys).isSubset(of: available) else {
            throw RoomCorrectionError.stale
        }
        bands = Dictionary(uniqueKeysWithValues: channels.compactMap { channel in
            let value = result.sharedBands + (result.channelBands[channel.index] ?? [])
            return value.isEmpty ? nil : (channel.index, value)
        })
        var physicalResult = result
        physicalResult.sharedBands = []
        physicalResult.channelBands = bands
        physicalResult.isChannelProcessingImport = true
        self.result = physicalResult
    }

    private func replacingFilters(in original: ProcessingProfile) -> ProcessingProfile {
        var processing = original
        processing.removeRoomStages()
        for channel in channels where bands[channel.index] != nil || result.channelFIR[channel.index] != nil {
            if !processing.channels.contains(where: { $0.index == channel.index }) {
                processing.channels.append(.init(index: channel.index, role: channel.role))
            }
            let index = processing.channels.firstIndex { $0.index == channel.index }!
            if let filters = bands[channel.index] {
                let existingID = processing.channels[index].chain.stages.first {
                    if case .equalizer = $0.processor { return true }; return false
                }?.id
                // An ordinary editor identity, distinct from automatic room stages.
                let identity = existingID ?? UUID(uuidString: String(format: "CA117B75-0000-4000-0001-%012X", channel.index))!
                processing.channels[index].chain.setEqualizer(filters, stageID: identity)
            }
            if let fir = result.channelFIR[channel.index] { processing.setConvolution(fir, forChannel: channel.index) }
        }
        processing.channels.sort { $0.index < $1.index }
        return processing
    }

    func matches(profile: DeviceProfile) -> Bool {
        guard let context = try? profile.roomMeasurementContext(), context == result.context,
              let processing = try? profile.resolvedProcessing() else { return false }
        guard !processing.channels.flatMap({ $0.chain.stages }).contains(where: { ProcessingProfile.isRoomStage($0.id) }) else { return false }
        return channels.allSatisfy { channel in
            if let filters = bands[channel.index], processing.settings(forChannel: channel.index)?.bands != filters { return false }
            if let fir = result.channelFIR[channel.index] {
                let imported = processing.convolution(forChannel: channel.index)
                if imported?.isEnabled != true || imported?.processor != fir { return false }
            }
            return true
        }
    }

    func replacementMessage(profile: DeviceProfile) throws -> String? {
        let processing = try profile.resolvedProcessing()
        var replacements: [String] = []
        for channel in channels {
            var types: [String] = []
            let stages = processing.channels.first { $0.index == channel.index }?.chain.stages ?? []
            if bands[channel.index] != nil, stages.contains(where: {
                guard !ProcessingProfile.isRoomStage($0.id) else { return false }
                if case .equalizer(let eq) = $0.processor { return !eq.bands.isEmpty }; return false
            }) { types.append("per-channel EQ") }
            if result.channelFIR[channel.index] != nil, stages.contains(where: {
                guard !ProcessingProfile.isRoomStage($0.id) else { return false }
                if case .convolution = $0.processor { return true }; return false
            }) { types.append("FIR") }
            if !types.isEmpty { replacements.append("\(channel.displayName): \(types.joined(separator: " and "))") }
        }
        return replacements.isEmpty ? nil : "Import will replace the existing values for:\n\n" + replacements.joined(separator: "\n")
    }

    func applying(to profile: DeviceProfile) throws -> DeviceProfile {
        guard try profile.roomMeasurementContext() == result.context else { throw RoomCorrectionError.stale }
        var candidate = profile
        candidate.captureLegacyPhysicalChannels()
        let processing = replacingFilters(in: try profile.roomMeasurementBaseline())
        for channel in channels {
            if let chain = processing.channels.first(where: { $0.index == channel.index })?.chain {
                candidate.physicalChannelProcessing[channel.physicalOutputID] = chain
            }
        }
        candidate.replaceProcessing(processing)
        var seat = candidate.effectiveSpatialSettings.seating ?? .init(outputDeviceUID: candidate.outputDeviceUID)
        seat.roomCorrectionResult = result; seat.roomCorrectionSettings = result.settings
        // Once imported, the channel editors own these filters. Materializing
        // the result again would both hide the controls and double the correction.
        seat.roomCorrectionEnabled = false; seat.roomCorrectionBands = []
        seat.roomCorrectionSessionID = result.sessionID; seat.roomCorrectionTopology = nil
        seat.roomCorrectionRevision += 1
        candidate.spatialSettings.seating = seat
        candidate.synchronizeListeningPositionCorrection()
        return candidate
    }
}

extension AppState {
    func roomCorrectionImportSnapshot(profile: DeviceProfile) throws -> RoomCorrectionImportHistoryState {
        let processing = try profile.resolvedProcessing()
        return .init(channels: Dictionary(uniqueKeysWithValues: profile.configuredProcessingChannels.map { channel in
            (channel.index, processing.channels.first { $0.index == channel.index }?.chain ?? .init())
        }), seat: profile.effectiveSpatialSettings.seating)
    }

    func storeRoomCorrectionImport(_ value: RoomCorrectionImportHistoryState, profileID: UUID) throws {
        var profile = try applyingSessionEQDrafts(to: historyProfile(profileID))
        guard profile.effectiveSpatialSettings.seating?.id == value.seat?.id,
              Set(value.channels.keys).isSubset(of: Set(profile.configuredProcessingChannels.map(\.index))) else {
            throw HistoryRestoreError.invalidStateForTarget
        }
        profile.captureLegacyPhysicalChannels()
        var processing = try profile.resolvedProcessing()
        processing.removeRoomStages()
        for channel in profile.configuredProcessingChannels {
            guard let chain = value.channels[channel.index] else { continue }
            if let index = processing.channels.firstIndex(where: { $0.index == channel.index }) {
                processing.channels[index].chain = chain
            } else { processing.channels.append(.init(index: channel.index, role: channel.role, chain: chain)) }
            profile.physicalChannelProcessing[channel.physicalOutputID] = chain
        }
        profile.replaceProcessing(processing)
        // History owns only correction fields; geometry and alignment stay current.
        if let source = value.seat, var seat = profile.spatialSettings.seating {
            seat.roomCorrectionResult = source.roomCorrectionResult
            seat.roomCorrectionSettings = source.roomCorrectionSettings
            seat.roomCorrectionEnabled = source.roomCorrectionEnabled
            seat.roomCorrectionBands = source.roomCorrectionBands
            seat.roomCorrectionTopology = source.roomCorrectionTopology
            seat.roomCorrectionSessionID = source.roomCorrectionSessionID
            seat.roomCorrectionRevision += 1
            profile.spatialSettings.seating = seat
        }
        profile.synchronizeListeningPositionCorrection()
        profiles.update(profile)
        for channel in value.channels.keys { clearChannelEQDraft(for: profileID, channelIndex: channel) }
    }
}
