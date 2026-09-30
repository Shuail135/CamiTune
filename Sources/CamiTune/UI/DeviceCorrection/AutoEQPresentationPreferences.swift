import Foundation

struct AutoEQPresentationPreferences: Codable, Equatable, Sendable {
    var resultsExpanded = true
    var advancedExpanded = false
    var detailsExpanded = false
    var visibleCurves: Set<CorrectionGraphCurve> = [.measurement, .target, .corrected]
    var showControlPoints = true
}

extension AutoEQPresentationPreferences {
    private enum CodingKeys: String, CodingKey {
        case resultsExpanded, advancedExpanded, detailsExpanded, visibleCurves, showControlPoints
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        resultsExpanded = try values.decodeIfPresent(Bool.self, forKey: .resultsExpanded) ?? resultsExpanded
        advancedExpanded = try values.decodeIfPresent(Bool.self, forKey: .advancedExpanded) ?? advancedExpanded
        detailsExpanded = try values.decodeIfPresent(Bool.self, forKey: .detailsExpanded) ?? detailsExpanded
        visibleCurves = try values.decodeIfPresent(Set<CorrectionGraphCurve>.self, forKey: .visibleCurves) ?? visibleCurves
        showControlPoints = try values.decodeIfPresent(Bool.self, forKey: .showControlPoints) ?? showControlPoints
    }
}

enum CorrectionGraphCurve: String, Codable, CaseIterable, Sendable {
    case measurement = "Measurement"
    case target = "Target"
    case corrected = "Corrected"
    case equalizer = "EQ"
    case desired = "Desired"
    case residual = "Residual"
}
