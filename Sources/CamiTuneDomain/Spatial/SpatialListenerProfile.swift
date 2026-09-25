import Foundation

package enum PerceivedVoiceDepth: String, Codable, CaseIterable, Identifiable, Sendable {
    case behindLaptop, laptop, screen, inFrontOfScreen
    package var id: String { rawValue }
    package var label: String {
        switch self {
        case .behindLaptop: return "Behind the speakers"
        case .laptop: return "At the speakers"
        case .screen: return "At the screen"
        case .inFrontOfScreen: return "In front of the screen"
        }
    }
}

package struct SpatialPositionFeedback: Codable, Hashable, Sendable {
    package init(depth: PerceivedVoiceDepth = .screen, horizontalPosition: Float = 0) {
        self.depth = depth
        self.horizontalPosition = horizontalPosition
    }

    package var depth: PerceivedVoiceDepth = .screen
    /// Perceived position: -1 is left, +1 is right, 0 is centered.
    package var horizontalPosition: Float = 0
}

package struct SpatialListenerTuning: Codable, Hashable, Sendable {
    package init(
        externalization: Float = 0,
        crosstalk: Float = 0,
        width: Float = 0,
        depth: Float = 0,
        timbre: Float = 0,
        centerAnchor: Float = 0,
        centerBalance: Float = 0
    ) {
        self.externalization = externalization
        self.crosstalk = crosstalk
        self.width = width
        self.depth = depth
        self.timbre = timbre
        self.centerAnchor = centerAnchor
        self.centerBalance = centerBalance
    }

    package var externalization: Float = 0
    package var crosstalk: Float = 0
    package var width: Float = 0
    package var depth: Float = 0
    package var timbre: Float = 0
    package var centerAnchor: Float = 0
    package var centerBalance: Float = 0

    package static let neutral = SpatialListenerTuning()

    package var validated: Self {
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

    package func applying(to intent: SpatialRenderIntent) -> SpatialRenderIntent {
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

package struct SpatialListenerProfile: Codable, Hashable, Sendable {
    package init(
        version: Int = 1,
        name: String,
        outputDeviceUID: String,
        savedAt: Date,
        position: SpatialPositionFeedback,
        tuning: SpatialListenerTuning,
        completedComparisons: Int
    ) {
        self.version = version
        self.name = name
        self.outputDeviceUID = outputDeviceUID
        self.savedAt = savedAt
        self.position = position
        self.tuning = tuning
        self.completedComparisons = completedComparisons
    }

    package var version = 1
    package var name: String
    package var outputDeviceUID: String
    package var savedAt: Date
    package var position: SpatialPositionFeedback
    package var tuning: SpatialListenerTuning
    package var completedComparisons: Int

    package func tuning(for outputUID: String) -> SpatialListenerTuning {
        guard version == 1, outputDeviceUID == outputUID else { return .neutral }
        return tuning.validated
    }
}
