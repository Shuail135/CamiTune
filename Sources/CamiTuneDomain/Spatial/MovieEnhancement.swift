import Foundation

package enum MovieDynamics: String, Codable, CaseIterable, Sendable {
    case original, balanced, night
    package var title: String { rawValue.capitalized }
}

package enum MovieApplicationScope: Codable, Hashable, Sendable {
    case allApplications
    case selectedApplications(Set<String>)
    package func contains(_ applicationID: String) -> Bool {
        switch self {
        case .allApplications: return true
        case .selectedApplications(let ids): return PerAppApplicationIdentityPolicy.isPersistentApplicationID(applicationID) && ids.contains(applicationID)
        }
    }
}

package enum MovieDetector: String, Codable, Hashable, CaseIterable, Sendable {
    case basic, localAI
    package var title: String { self == .basic ? "Basic" : "Local AI" }
}

package struct MovieSettings: Codable, Hashable, Sendable {
    package var enabled = false
    package var scope: MovieApplicationScope = .allApplications
    package var dialogueClarity: Float = 0.5
    package var dynamics: MovieDynamics = .balanced
    package var detector: MovieDetector = .basic
    package var musicPreservation: Float = 0.8
    package var roomReduction: Float = 0.5
    package var adaptation: Float = 0.5
    package var responseSpeed: Float = 0.5
    package var additionalReductionLimitDB: Float = 3
    package init() {}

    package var analyzesContent: Bool { enabled && adaptation > 0 }
    package var attackSeconds: Double { 0.5 - 0.3 * Double(responseSpeed) }
    package var releaseSeconds: Double { 2 - Double(responseSpeed) }

    package func validate() throws {
        guard [dialogueClarity, musicPreservation, roomReduction, adaptation, responseSpeed].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              additionalReductionLimitDB.isFinite, (0...6).contains(additionalReductionLimitDB) else {
            throw PersonalSpatialError.invalidMovieSettings
        }
    }
    private enum CodingKeys: String, CodingKey {
        case enabled, scope, dialogueClarity, dynamics, detector, musicPreservation, roomReduction, adaptation, responseSpeed, additionalReductionLimitDB
    }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        scope = try values.decode(MovieApplicationScope.self, forKey: .scope)
        dialogueClarity = SpatialRenderIntent.unit(try values.decode(Float.self, forKey: .dialogueClarity))
        dynamics = try values.decode(MovieDynamics.self, forKey: .dynamics)
        detector = try values.decodeIfPresent(MovieDetector.self, forKey: .detector) ?? .basic
        musicPreservation = try values.decodeIfPresent(Float.self, forKey: .musicPreservation) ?? 0.8
        roomReduction = try values.decodeIfPresent(Float.self, forKey: .roomReduction) ?? 0.5
        // Old Movie processing was manual; migration must not add boosts.
        adaptation = try values.decodeIfPresent(Float.self, forKey: .adaptation) ?? 0
        responseSpeed = try values.decodeIfPresent(Float.self, forKey: .responseSpeed) ?? 0.5
        additionalReductionLimitDB = try values.decodeIfPresent(Float.self, forKey: .additionalReductionLimitDB) ?? 3
        try validate()
    }
}

/// Independent context scores. Basic estimates are signal heuristics; AI scores
/// come from labels. Neither representation asserts that a movie is playing.
package struct MovieContentScores: Equatable, Sendable {
    package var speech: Float = 0
    package var music: Float = 0
    package var singing: Float = 0
    package var events: Float = 0
    package var impact: Float = 0
    package var active = false
    package init(speech: Float = 0, music: Float = 0, singing: Float = 0, events: Float = 0, impact: Float = 0, active: Bool = false) {
        self.speech = speech; self.music = music; self.singing = singing
        self.events = events; self.impact = impact; self.active = active
    }
    package var label: String {
        if !active { return "Quiet" }
        let musical = max(music, singing)
        if speech >= 0.55 && musical < 0.45 { return "Speech" }
        if musical >= 0.55 && speech < 0.45 { return "Music" }
        return "Mixed"
    }
}

package enum MovieAnalysisStatus: Equatable, Sendable {
    case off, preparing, content(MovieContentScores), unavailable(String)
    package var title: String {
        switch self {
        case .off: return "Manual enhancement"
        case .preparing: return "Preparing"
        case .content(let scores): return scores.label
        case .unavailable: return "Analysis unavailable"
        }
    }
}

/// Offsets to manual processing, not settings mutations or replacement audio.
package struct MovieAutomaticControls: Equatable, Sendable {
    package var presenceDB: Float = 0
    package var centerDB: Float = 0
    package var lateRoomDB: Float = 0
    package var additionalReductionDB: Float = 0
    package init() {}
    package static let neutral = Self()
}

package enum MovieEnhancementPolicy {
    package static func controls(scores: MovieContentScores, settings: MovieSettings) -> MovieAutomaticControls {
        guard settings.analyzesContent, scores.active else { return .neutral }
        let speech = SpatialRenderIntent.unit((scores.speech - 0.5) * 2)
        let music = SpatialRenderIntent.unit((max(scores.music, scores.singing) - 0.4) / 0.6)
        let musicWeight = settings.musicPreservation * music
        let preservation = 1 - musicWeight
        let amount = settings.adaptation * max(speech, musicWeight)
        let manualDB = 20 * log10(1 + 0.2589254 * settings.dialogueClarity)
        var result = MovieAutomaticControls()
        result.presenceDB = amount * (1.5 * settings.dialogueClarity * preservation - manualDB)
        result.centerDB = amount * (3 * settings.dialogueClarity * preservation - manualDB)
        result.lateRoomDB = -3 * settings.adaptation * settings.roomReduction * speech * preservation
        if settings.dynamics != .original {
            result.additionalReductionDB = settings.additionalReductionLimitDB * settings.adaptation
                * SpatialRenderIntent.unit(scores.impact) * preservation
        }
        return result
    }
}

/// Four valid processing classes. Movie is never a public playback-mode choice.
