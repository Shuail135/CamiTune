import CamiTuneDomain
import Foundation

/// Perceptual preferences adjust intent, never measured delays or safety
/// ceilings. Bounded deltas keep stereo and movie policies distinct.

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
