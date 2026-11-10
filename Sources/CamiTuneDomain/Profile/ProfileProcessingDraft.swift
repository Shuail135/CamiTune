import Foundation

/// Internal edits retain band identity and precision. Text parsing belongs to
/// import boundaries; reparsing a draft renames and reorders compiled filters.
package struct ProfileProcessingDraft: Equatable, Sendable {
    package struct Equalizer: Equatable, Sendable {
        package var parameters: ParsedEQ?
        package var tone: SimpleToneSettings?
        package var limiter: Bool?
        package var replacesDeviceCorrection = false
        package var provenance = Provenance.unchanged
        package init() {}
    }

    package enum Provenance: Equatable, Sendable {
        case unchanged, replace(DeviceCorrectionProfile?)

        package func resolve(_ persisted: DeviceCorrectionProfile?) -> DeviceCorrectionProfile? {
            switch self {
            case .unchanged: return persisted
            case .replace(let value): return value
            }
        }
    }

    package struct Channel: Equatable, Sendable {
        package var parameters: ParsedEQ?
        package var tone: SimpleToneSettings?
        package var limiter: Bool?
        package var delay: Double?
        package init() {}
    }

    package var equalizer = Equalizer()
    package var channels: [Int: Channel] = [:]
    package var groups: [SpeakerGroupID: ChannelProcessingSettings] = [:]
    package init() {}

    package func applying(to profile: DeviceProfile, replacingGlobalEqualizer: Bool = false) throws -> DeviceProfile {
        var updated = profile
        if let tone = equalizer.tone { updated.processing.simpleTone = tone }
        if !replacingGlobalEqualizer, let parsed = equalizer.parameters {
            updated.setGlobalEqualizer(preampDB: parsed.preampDB, bands: parsed.bands)
            if equalizer.replacesDeviceCorrection { updated.processing.setDeviceCorrection(nil) }
        }
        if let limiter = equalizer.limiter { updated.processing.setLimiterEnabled(limiter) }
        if !replacingGlobalEqualizer {
            updated.processing.globalEqualizerProvenance = equalizer.provenance.resolve(updated.processing.globalEqualizerProvenance)
        }
        for (id, settings) in groups where updated.configuredSpeakerGroups.contains(where: { $0.id == id }) {
            try updated.setGroupProcessing(id: id, settings: settings)
        }
        for (index, draft) in channels {
            let current = try updated.resolvedProcessing().settings(forChannel: index) ?? .identity
            let parsed = draft.parameters
                ?? ParsedEQ(preampDB: current.gainDB, bands: current.bands, warnings: [])
            let role = updated.processing.channels.first(where: { $0.index == index })?.role
                ?? (index == 0 ? .left : (index == 1 ? .right : .unknown))
            try updated.setChannelProcessing(index: index, role: role,
                gainDB: parsed.preampDB, bands: parsed.bands,
                delayMilliseconds: draft.delay ?? current.delayMilliseconds,
                limiterEnabled: draft.limiter ?? current.limiterEnabled,
                simpleTone: draft.tone ?? current.simpleTone)
        }
        return updated
    }
}
