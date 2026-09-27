import Foundation

package enum DeviceCorrectionTargetPreset: String, Codable, Hashable, Sendable, CaseIterable {
    case flat
    case neutral
    case autoEqInEar
    case jm1Harman
    case lmg5128
    case optimumHiFi
    case jm1PopAvgDFTilt
    case harmanOverEar2018
    case harmanInEar2019V2
    case iefPreference2025
    case iefNeutral2023
    case diffuseFieldReference
    case etymotic
    case deviceMatch
    case custom

    package var title: String {
        switch self {
        case .neutral: return "Neutral"
        case .autoEqInEar: return "AutoEq In-Ear"
        case .jm1Harman: return "JM-1 with Harman Filters"
        case .lmg5128: return "LMG 5128 (0.6)"
        case .optimumHiFi: return "oratory1990 Optimum HiFi"
        case .flat: return "Flat (no target compensation)"
        case .jm1PopAvgDFTilt: return "JM-1 / PopAvg-DF + Tilt"
        case .harmanOverEar2018: return "Harman Over-Ear 2018"
        case .harmanInEar2019V2: return "Harman In-Ear 2019 v2"
        case .iefPreference2025: return "IEF Preference 2025"
        case .iefNeutral2023: return "IEF Neutral 2023"
        case .diffuseFieldReference: return "Diffuse Field Reference"
        case .etymotic: return "Etymotic Target"
        case .deviceMatch: return "Device Match"
        case .custom: return "Custom CSV"
        }
    }

    package var shortDescription: String {
        switch self {
        case .neutral: return "A fixture-matched neutral baseline without an additional preference bass shelf."
        case .autoEqInEar: return "AutoEq in-ear preference target with fixture-specific compensation."
        case .jm1Harman: return "JM-1 with published Harman bass and treble shelves for B&K 5128."
        case .lmg5128: return "LMG 0.6 preference target for B&K 5128."
        case .optimumHiFi: return "oratory1990 Optimum HiFi over-ear target for GRAS-compatible measurements."
        case .flat:
            return "Corrects the measurement toward a mathematically flat coupler response. This is mainly a diagnostic option, not a perceptual listening target."
        case .jm1PopAvgDFTilt:
            return "A population-average diffuse-field reference. The adjustable tilt changes the overall warm-to-bright balance; −1.0 dB per octave is a useful neutral starting point."
        case .harmanOverEar2018:
            return "Harman over-ear preference target for GRAS measurements."
        case .harmanInEar2019V2:
            return "A listener-preference target with strong bass and forward upper mids. It is a familiar, energetic consumer reference rather than a universal definition of neutral."
        case .iefPreference2025:
            return "Crinacle's 2025 preference tuning: elevated sub-bass and less upper-treble energy than the JM-1 baseline. It aims for balanced, enjoyable listening."
        case .iefNeutral2023:
            return "A neutral-focused 711 target with restrained bass and a smoother ear-gain region. Choose it when you want the recording, not added bass preference, to lead."
        case .diffuseFieldReference:
            return "The acoustic response associated with sound arriving evenly from all directions. It has no added preference bass shelf and can sound leaner or brighter."
        case .etymotic:
            return "Etymotic's classic perceptually-flat in-ear reference, emphasizing the ear-canal compensation region around 2–5 kHz with comparatively restrained bass."
        case .deviceMatch:
            return "Matches the selected device's measured tonal balance to another headphone or earphone measured on the same fixture and configuration type."
        case .custom:
            return "Uses a frequency-response CSV that you provide. Its measurement fixture must match the source measurement fixture."
        }
    }
}

package struct DeviceMatchTargetMetadata: Codable, Hashable, Sendable {
    package init(
        deviceName: String,
        deviceIdentity: DeviceConfigurationIdentity,
        measurementConfidence: MeasurementConfidenceCurve,
        sources: [DeviceMeasurementReference],
        measurementSnapshots: [MeasurementSnapshot]
    ) {
        self.deviceName = deviceName
        self.deviceIdentity = deviceIdentity
        self.measurementConfidence = measurementConfidence
        self.sources = sources
        self.measurementSnapshots = measurementSnapshots
    }

    package var deviceName: String
    package var deviceIdentity: DeviceConfigurationIdentity
    package var measurementConfidence: MeasurementConfidenceCurve
    package var sources: [DeviceMeasurementReference]
    package var measurementSnapshots: [MeasurementSnapshot]
}

package struct DeviceCorrectionTargetSelection: Codable, Hashable, Sendable {
    package var modifiers: TargetModifiers? = nil
    package var preset: DeviceCorrectionTargetPreset
    package var tiltDBPerOctave: Double
    /// Custom target files contain only frequency and magnitude columns, so
    /// their acoustic fixture must be declared separately and persisted.
    package var customTargetRigIdentity: MeasurementRigIdentity?
    /// Persisted independently from the source device so Device Match can be
    /// reopened, recalculated, and refreshed without searching again.
    package var deviceMatchTarget: DeviceMatchTargetMetadata?

    package init(
        preset: DeviceCorrectionTargetPreset,
        tiltDBPerOctave: Double = -1,
        customTargetRigIdentity: MeasurementRigIdentity? = nil,
        deviceMatchTarget: DeviceMatchTargetMetadata? = nil
    ) {
        self.preset = preset
        self.tiltDBPerOctave = min(1, max(-2, tiltDBPerOctave))
        self.customTargetRigIdentity = customTargetRigIdentity
        self.deviceMatchTarget = deviceMatchTarget
    }

    package static let flat = DeviceCorrectionTargetSelection(preset: .flat)
    package static let custom = DeviceCorrectionTargetSelection(preset: .custom)
}

package enum DeviceCorrectionRigFamily: String, Codable, Hashable, Sendable {
    case iec711
    case bk5128
    case unknown

    package var title: String {
        switch self {
        case .iec711: return "IEC 60318-4 / 711"
        case .bk5128: return "B&K 5128 / 4620"
        case .unknown: return "unknown fixture"
        }
    }

    package static func identify(from sources: [DeviceMeasurementReference]) -> Self {
        let families = Set(sources.map { $0.resolvedRigIdentity.family })
        if families.count == 1 { return families.first ?? .unknown }
        return families.subtracting([.unknown]).count == 1
            ? families.subtracting([.unknown]).first ?? .unknown
            : .unknown
    }
}

package struct TargetModifiers: Codable, Hashable, Sendable {
    package var bassGainDB: Double = 0
    package var trebleGainDB: Double = 0
    package var tiltDBPerOctave: Double = 0
    package init() {}
}
