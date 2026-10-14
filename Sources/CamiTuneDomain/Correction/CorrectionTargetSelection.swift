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
        case .neutral: return "A balanced starting point, matched to your device's measurements, with no extra bass boost."
        case .autoEqInEar: return "An earphone listening target with added bass."
        case .jm1Harman: return "The JM-1 reference with fuller bass and Harman treble adjustments."
        case .lmg5128: return "LMG's alternative listening target for devices measured on a B&K 5128."
        case .optimumHiFi: return "A neutral-leaning headphone target with restrained bass."
        case .flat:
            return "A straight measurement line for testing; it may not sound neutral."
        case .jm1PopAvgDFTilt:
            return "Lets you adjust the overall balance from warmer to brighter with the Tilt slider."
        case .harmanOverEar2018:
            return "A headphone target based on listener preferences, with added bass."
        case .harmanInEar2019V2:
            return "A lively earphone target with strong bass and more prominent vocals."
        case .iefPreference2025:
            return "Deep bass with gentler high treble than the JM-1 reference."
        case .iefNeutral2023:
            return "Restrained bass and a smoother vocal range for a neutral-leaning sound."
        case .diffuseFieldReference:
            return "Models sound arriving from all directions; can sound leaner or brighter."
        case .etymotic:
            return "A clear, vocal-focused earphone balance with restrained bass."
        case .deviceMatch:
            return "Aims for the sound balance of another headphone or earphone with compatible measurements."
        case .custom:
            return "Uses your own target CSV. Choose the same measurement setup as the source device."
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
