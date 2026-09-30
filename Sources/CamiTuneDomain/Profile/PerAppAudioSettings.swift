import Foundation

package struct PerAppAudioSettings: Codable, Hashable, Sendable {
    package init(volume: Double = 1, isMuted: Bool = false, eqBypassed: Bool = true, equalizerBands: [EQBand] = [], playbackModeOverride: PlaybackMode? = nil, simpleTone: SimpleToneSettings = SimpleToneSettings()) {
        self.volume = volume
        self.isMuted = isMuted
        self.eqBypassed = eqBypassed
        self.equalizerBands = equalizerBands
        self.playbackModeOverride = playbackModeOverride
        self.simpleTone = simpleTone
    }

    package var volume: Double = 1
    package var isMuted = false
    package var eqBypassed = true
    package var equalizerBands: [EQBand] = []
    package var playbackModeOverride: PlaybackMode?
    package var simpleTone = SimpleToneSettings()
    /// Flat gain bands and disabled filters do not light the per-app EQ indicator.
    package var isEqualizerActive: Bool {
        !eqBypassed && (!simpleTone.isNeutral
            || (ParsedEQ(bands: equalizerBands)).hasMeaningfulProcessing)
    }
    package var hasEqualizerProcessing: Bool { !equalizerBands.isEmpty || !simpleTone.isNeutral }
    package func processingBands(sampleRate: Double) -> [EQBand] {
        equalizerBands + (simpleTone.isNeutral ? [] : ((try? SimpleToneFilterFactory.filters(for: simpleTone, sampleRate: sampleRate)) ?? []))
    }
    package enum CodingKeys: String, CodingKey { case volume, isMuted, eqBypassed, equalizerBands, playbackModeOverride, simpleTone }
}

extension PerAppAudioSettings {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        eqBypassed = try c.decodeIfPresent(Bool.self, forKey: .eqBypassed) ?? true
        equalizerBands = try c.decodeIfPresent([EQBand].self, forKey: .equalizerBands) ?? []
        playbackModeOverride = try c.decodeIfPresent(PlaybackMode.self, forKey: .playbackModeOverride)
        simpleTone = try c.decodeIfPresent(SimpleToneSettings.self, forKey: .simpleTone) ?? SimpleToneSettings()
        try simpleTone.validate()
    }
}

package struct PerAppAudioDocument: Codable {
    package init(schemaVersion: Int = currentVersion, settings: [String: PerAppAudioSettings]) {
        self.schemaVersion = schemaVersion
        self.settings = settings
    }

    package static let currentVersion = 1
    package var schemaVersion: Int = currentVersion
    package var settings: [String: PerAppAudioSettings]

    package static func decode(_ data: Data) throws -> [String: PerAppAudioSettings] {
        struct Header: Decodable { var schemaVersion: Int? }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        if let version = header.schemaVersion {
            guard version == currentVersion else {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                    debugDescription: "Unsupported per-app settings version."))
            }
            return try decoder.decode(Self.self, from: data).settings
        }
        return try decoder.decode([String: PerAppAudioSettings].self, from: data)
    }
}

extension PerAppAudioSettings {
    package func automaticHeadroomDB(sampleRate: Double) -> Double {
        guard !eqBypassed, hasEqualizerProcessing else { return 0 }
        let response = EQResponseCalculator().calculate(
            parsed: ParsedEQ(bands: processingBands(sampleRate: sampleRate)),
            sampleRate: sampleRate,
            count: 600
        )
        let boost = max(0, response.map(\.gainDB).max() ?? 0)
        return boost > 0 ? -boost : 0
    }
}
