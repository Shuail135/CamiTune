import Foundation

package enum SpatialRenderingMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case standard
    case spatialAudio
    case frontStage
    case virtualSurround

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .spatialAudio: return "Spatial Audio"
        case .standard: return "Standard"
        case .frontStage: return "Front Stage"
        case .virtualSurround: return "Virtual 7.1"
        }
    }
}

package struct SpatialRenderIntent: Hashable, Sendable {
    package var frontStageStrength: Float
    package var stageWidth: Float
    package var stageDepth: Float
    package var centerAnchor: Float
    package var envelopment: Float
    package var localizationPrecision: Float
    package var centerExternalization: Float
    package var crosstalkControl: Float
    package var timbreCompensation: Float
    package var centerBalance: Float

    package init(
        frontStageStrength: Float,
        stageWidth: Float,
        stageDepth: Float,
        centerAnchor: Float,
        envelopment: Float,
        localizationPrecision: Float,
        centerExternalization: Float = 0,
        crosstalkControl: Float = 0,
        timbreCompensation: Float = 0,
        centerBalance: Float = 0
    ) {
        self.frontStageStrength = frontStageStrength
        self.stageWidth = stageWidth
        self.stageDepth = stageDepth
        self.centerAnchor = centerAnchor
        self.envelopment = envelopment
        self.localizationPrecision = localizationPrecision
        self.centerExternalization = centerExternalization
        self.crosstalkControl = crosstalkControl
        self.timbreCompensation = timbreCompensation
        self.centerBalance = centerBalance
    }

    package static let neutral = SpatialRenderIntent(
        frontStageStrength: 0,
        stageWidth: 0,
        stageDepth: 0,
        centerAnchor: 0,
        envelopment: 0,
        localizationPrecision: 0
    )

    /// Fixed calibration/reference policy. Prototype 6 applies bounded
    /// content adjustments separately on the PCM writer worker.
    package static let frontStageStereo = SpatialRenderIntent(
        frontStageStrength: 0.72,
        stageWidth: 0.48,
        stageDepth: 0.30,
        centerAnchor: 0.72,
        envelopment: 0.18,
        localizationPrecision: 0.68,
        centerExternalization: 0.58,
        crosstalkControl: 0.42,
        timbreCompensation: 0.50
    )

    package static let frontStageMovie = SpatialRenderIntent(
        frontStageStrength: 0.78,
        stageWidth: 0.62,
        stageDepth: 0.55,
        centerAnchor: 0.82,
        envelopment: 0.68,
        localizationPrecision: 0.78,
        centerExternalization: 0.65,
        crosstalkControl: 0.45,
        timbreCompensation: 0.50
    )

    package var clamped: SpatialRenderIntent {
        SpatialRenderIntent(
            frontStageStrength: Self.unit(frontStageStrength),
            stageWidth: Self.unit(stageWidth),
            stageDepth: Self.unit(stageDepth),
            centerAnchor: Self.unit(centerAnchor),
            envelopment: Self.unit(envelopment),
            localizationPrecision: Self.unit(localizationPrecision),
            centerExternalization: Self.unit(centerExternalization),
            crosstalkControl: Self.unit(crosstalkControl),
            timbreCompensation: Self.unit(timbreCompensation),
            centerBalance: centerBalance.isFinite ? max(-0.18, min(0.18, centerBalance)) : 0
        )
    }

    package static func unit(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
