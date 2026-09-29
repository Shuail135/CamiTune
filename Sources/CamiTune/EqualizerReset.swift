import CamiTuneDomain

extension EqualizerPresentation {
    var resetTitle: String {
        switch self {
        case .simpleTone: return "Reset Simple EQ"
        case .bands: return "Reset EQ Bands"
        case .both: return "Reset All EQ Controls"
        }
    }
}

enum EqualizerReset {
    static func bands(_ current: [EQBand]) -> [EQBand] {
        let defaults = EQEditorSupport.resizedBands([], count: current.count)
        return current.enumerated().map { index, original in
            let value = index < defaults.count ? defaults[index]
                : EQBand(kind: .peaking, frequency: original.frequency, gain: 0, q: 1)
            return EQBand(id: original.id, enabled: value.enabled, kind: value.kind,
                frequency: value.frequency, gain: value.gain, q: value.q, bandwidth: value.bandwidth)
        }
    }

    static func global(_ current: GlobalEQHistoryState, presentation: EqualizerPresentation) -> GlobalEQHistoryState {
        var reset = current
        if presentation != .bands { reset.simpleTone = .init() }
        if presentation != .simpleTone {
            reset.bands = bands(current.bands)
            reset.deviceCorrectionProvenance = nil
        }
        if presentation == .both {
            reset.preampDB = 0
            reset.limiterEnabled = false
        }
        return reset
    }

    static func channel(_ current: PerChannelEditorSnapshot, presentation: EqualizerPresentation) -> PerChannelEditorSnapshot {
        .init(gainDB: presentation == .both ? 0 : current.gainDB,
            delayMilliseconds: presentation == .both ? 0 : current.delayMilliseconds,
            limiterEnabled: presentation == .both ? false : current.limiterEnabled,
            bands: presentation == .simpleTone ? current.bands : bands(current.bands),
            simpleTone: presentation == .bands ? current.simpleTone : .init())
    }
}
