import Foundation

enum SpatialRenderingMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case standard
    case frontStage
    case virtualSurround

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .frontStage: return "Front Stage"
        case .virtualSurround: return "Virtual 7.1"
        }
    }
}

/// A normalized, backend-independent description of the spatial result the
/// renderer should approach. Values are intentionally bounded to 0...1 so a
/// future calibration or content classifier cannot request unsafe DSP gains.
struct SpatialRenderIntent: Hashable, Sendable {
    var frontStageStrength: Float
    var stageWidth: Float
    var stageDepth: Float
    var centerAnchor: Float
    var envelopment: Float
    var localizationPrecision: Float
    var centerExternalization: Float
    var crosstalkControl: Float
    var timbreCompensation: Float
    var centerBalance: Float

    init(
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

    static let neutral = SpatialRenderIntent(
        frontStageStrength: 0,
        stageWidth: 0,
        stageDepth: 0,
        centerAnchor: 0,
        envelopment: 0,
        localizationPrecision: 0
    )

    /// Fixed calibration/reference policy. Prototype 6 applies bounded
    /// content adjustments separately on the PCM writer worker.
    static let frontStageStereo = SpatialRenderIntent(
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

    static let frontStageMovie = SpatialRenderIntent(
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

    var clamped: SpatialRenderIntent {
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

    private static func unit(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// Front Stage source selection. The virtual endpoint can be physically 7.1
/// even when an application supplies only its first stereo pair, so the
/// decision also checks which semantic channels contain energy. Meaningful
/// center/surround/LFE energy selects the Prototype-3 semantic movie renderer;
/// Standard mode retains the neutral Prototype-1 fallback.
struct SpatialPolicy {
    var stereoIntent: SpatialRenderIntent = .frontStageStereo
    var movieIntent: SpatialRenderIntent = .frontStageMovie

    enum Decision: Hashable, Sendable {
        case standard
        case stereo(SpatialRenderIntent)
        case multichannelMovie(SpatialRenderIntent)
    }

    func decision(
        for frame: PCMFrame,
        mode: SpatialRenderingMode
    ) -> Decision {
        guard mode == .frontStage else { return .standard }
        guard frame.channelCount > 0,
              frame.channelLayout.roles.count == frame.channelCount,
              frame.interleaved.count.isMultiple(of: frame.channelCount) else {
            return .standard
        }

        if frame.channelLayout.roles == LPCMChannelLayout.stereo.roles {
            return .stereo(stereoIntent.clamped)
        }

        let leftIndex = frame.channelLayout.roles.firstIndex(of: .left)
        let rightIndex = frame.channelLayout.roles.firstIndex(of: .right)
        guard let leftIndex, let rightIndex else { return .standard }

        var stereoEnergy = Double.zero
        var discreteEnergy = Double.zero
        for frameIndex in 0..<frame.frameCount {
            let offset = frameIndex * frame.channelCount
            for channel in 0..<frame.channelCount {
                let sample = frame.interleaved[offset + channel]
                guard sample.isFinite else { continue }
                let energy = Double(sample) * Double(sample)
                if channel == leftIndex || channel == rightIndex {
                    stereoEnergy += energy
                } else {
                    discreteEnergy += energy
                }
            }
        }

        // -60 dB relative energy prevents floating-point residue in nominally
        // silent endpoint channels from disabling Front Stage.
        let silenceFloor = Double(max(1, frame.frameCount)) * 1e-12
        let isStereoPayload = discreteEnergy <= max(silenceFloor, stereoEnergy * 1e-6)
        return isStereoPayload
            ? .stereo(stereoIntent.clamped)
            : .multichannelMovie(movieIntent.clamped)
    }

    func renderIntent(
        for frame: PCMFrame,
        mode: SpatialRenderingMode = .frontStage
    ) -> SpatialRenderIntent {
        switch decision(for: frame, mode: mode) {
        case .standard: return .neutral
        case .stereo(let intent), .multichannelMovie(let intent): return intent
        }
    }
}
