import Foundation

enum PerceivedVoiceDepth: String, Codable, CaseIterable, Identifiable, Sendable {
    case behindLaptop, laptop, screen, inFrontOfScreen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .behindLaptop: return "Behind the speakers"
        case .laptop: return "At the speakers"
        case .screen: return "At the screen"
        case .inFrontOfScreen: return "In front of the screen"
        }
    }
}

struct SpatialPositionFeedback: Codable, Hashable, Sendable {
    var depth: PerceivedVoiceDepth = .screen
    /// Perceived position: -1 is left, +1 is right, 0 is centered.
    var horizontalPosition: Float = 0
}

/// Perceptual preferences adjust intent, never measured delays or safety
/// ceilings. Bounded deltas keep stereo and movie policies distinct.
struct SpatialListenerTuning: Codable, Hashable, Sendable {
    var externalization: Float = 0
    var crosstalk: Float = 0
    var width: Float = 0
    var depth: Float = 0
    var timbre: Float = 0
    var centerAnchor: Float = 0
    var centerBalance: Float = 0

    static let neutral = SpatialListenerTuning()

    var validated: Self {
        Self(
            externalization: Self.bound(externalization, limit: 0.25),
            crosstalk: Self.bound(crosstalk, limit: 0.20),
            width: Self.bound(width, limit: 0.20),
            depth: Self.bound(depth, limit: 0.20),
            timbre: Self.bound(timbre, limit: 0.20),
            centerAnchor: Self.bound(centerAnchor, limit: 0.15),
            centerBalance: Self.bound(centerBalance, limit: 0.18)
        )
    }

    func applying(to intent: SpatialRenderIntent) -> SpatialRenderIntent {
        guard intent.frontStageStrength > 0 else { return intent.clamped }
        let tuning = validated
        var result = intent
        result.centerExternalization += tuning.externalization
        result.crosstalkControl += tuning.crosstalk
        result.stageWidth += tuning.width
        result.stageDepth += tuning.depth
        result.timbreCompensation += tuning.timbre
        result.centerAnchor += tuning.centerAnchor
        result.centerBalance = tuning.centerBalance
        return result.clamped
    }

    private static func bound(_ value: Float, limit: Float) -> Float {
        value.isFinite ? max(-limit, min(limit, value)) : 0
    }
}

struct SpatialListenerProfile: Codable, Hashable, Sendable {
    var version = 1
    var name: String
    var outputDeviceUID: String
    var savedAt: Date
    var position: SpatialPositionFeedback
    var tuning: SpatialListenerTuning
    var completedComparisons: Int

    func tuning(for outputUID: String) -> SpatialListenerTuning {
        guard version == 1, outputDeviceUID == outputUID else { return .neutral }
        return tuning.validated
    }
}

/// Four bounded coordinate comparisons. A/B order alternates so a repeated
/// preference for the first button does not always mean stronger processing.
struct SpatialPerceptualCalibration: Sendable {
    enum Choice { case a, b, noDifference }
    static let comparisonCount = 4
    private(set) var tuning: SpatialListenerTuning
    private(set) var position = SpatialPositionFeedback()
    private(set) var comparisonIndex = 0
    private(set) var hasPositionFeedback = false

    init(tuning: SpatialListenerTuning = .neutral) { self.tuning = tuning.validated }

    var isComplete: Bool { hasPositionFeedback && comparisonIndex == Self.comparisonCount }

    mutating func setPosition(_ feedback: SpatialPositionFeedback) {
        guard !hasPositionFeedback else { return }
        position = feedback
        position.horizontalPosition = feedback.horizontalPosition.isFinite
            ? min(1, max(-1, feedback.horizontalPosition)) : 0
        switch feedback.depth {
        case .behindLaptop: tuning.externalization += 0.12
        case .laptop: tuning.externalization += 0.06
        case .screen: break
        case .inFrontOfScreen: tuning.externalization -= 0.06
        }
        // Attenuate the dominant side of the common/center signal only.
        tuning.centerBalance -= position.horizontalPosition * 0.18
        tuning = tuning.validated
        hasPositionFeedback = true
    }

    var candidates: (a: SpatialListenerTuning, b: SpatialListenerTuning) {
        var lower = tuning
        var upper = tuning
        switch comparisonIndex {
        case 0:
            lower.externalization -= 0.08; upper.externalization += 0.08
        case 1:
            lower.crosstalk -= 0.08; upper.crosstalk += 0.08
        case 2:
            lower.width -= 0.08; upper.width += 0.08
            lower.depth -= 0.06; upper.depth += 0.06
        case 3:
            lower.timbre -= 0.10; upper.timbre += 0.10
        default: return (tuning, tuning)
        }
        return comparisonIndex.isMultiple(of: 2)
            ? (lower.validated, upper.validated) : (upper.validated, lower.validated)
    }

    mutating func choose(_ choice: Choice) {
        guard hasPositionFeedback, !isComplete else { return }
        switch choice {
        case .a: tuning = candidates.a
        case .b: tuning = candidates.b
        case .noDifference: break
        }
        comparisonIndex += 1
    }
}

struct SpatialCalibrationContext: Identifiable, Equatable, Sendable {
    let id: UUID
    let runtimeSessionID: UUID
    let profileID: UUID
    let outputDeviceUID: String
    let sampleRate: Double
}
