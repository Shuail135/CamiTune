import CamiTuneDomain
import Foundation

struct DeviceCorrectionTargetResolution: Hashable, Sendable {
    var response: FrequencyResponse
    var rigFamily: DeviceCorrectionRigFamily
    var usedFallbackRig: Bool
    var confidence: MeasurementConfidenceCurve?
}

struct DeviceCorrectionTargetCatalog {
    func resolve(
        selection: DeviceCorrectionTargetSelection,
        sources: [DeviceMeasurementReference],
        customResponse: FrequencyResponse? = nil,
        deviceMatchConsensus: MeasurementConsensus? = nil
    ) throws -> DeviceCorrectionTargetResolution {
        let measuredFamily = DeviceCorrectionRigFamily.identify(from: sources)
        let usesPresetFixture = selection.preset != .flat
            && selection.preset != .custom
            && selection.preset != .deviceMatch
        var family = measuredFamily == .unknown && usesPresetFixture
            ? DeviceCorrectionRigFamily.iec711
            : measuredFamily
        let response: FrequencyResponse
        var confidence: MeasurementConfidenceCurve?

        switch selection.preset {
        case .flat:
            response = .flat()
        case .custom:
            guard let customResponse else { throw TargetError.customTargetMissing }
            guard let targetRig = selection.customTargetRigIdentity,
                  targetRig.family != .unknown else {
                throw TargetError.customTargetFixtureMissing
            }
            if measuredFamily != .unknown, measuredFamily != targetRig.family {
                throw TargetError.incompatibleRig(
                    target: selection.preset.title,
                    required: targetRig.family.title,
                    actual: measuredFamily.title
                )
            }
            family = targetRig.family
            response = customResponse
        case .jm1PopAvgDFTilt:
            response = try jm1(family: family, tiltDBPerOctave: selection.tiltDBPerOctave)
        case .harmanInEar2019V2:
            try require(.iec711, actual: family, preset: selection.preset)
            response = try load(
                "harman-in-ear-2019-v2",
                as: "Harman In-Ear 2019 v2 (711)"
            )
        case .iefPreference2025:
            response = try iefPreference2025(family: family)
        case .iefNeutral2023:
            try require(.iec711, actual: family, preset: selection.preset)
            response = try load("ief-neutral-2023-711", as: "IEF Neutral 2023 (711)")
        case .diffuseFieldReference:
            switch family {
            case .bk5128:
                response = try load("diffuse-field-5128", as: "Diffuse Field (B&K 5128)")
            case .iec711, .unknown:
                response = try load("diffuse-field-kemar", as: "Diffuse Field (KEMAR / 711)")
            }
        case .etymotic:
            try require(.iec711, actual: family, preset: selection.preset)
            response = try load("etymotic-711", as: "Etymotic Target (711)")
        case .deviceMatch:
            guard let metadata = selection.deviceMatchTarget,
                  let deviceMatchConsensus else {
                throw TargetError.deviceMatchTargetMissing
            }
            guard DeviceMatchPlanner.isCompatible(
                sourceReferences: sources,
                targetReferences: metadata.sources
            ) else {
                throw TargetError.incompatibleDeviceMatchRig
            }
            let metadataSourceIDs = Set(metadata.sources.map(\.id))
            let consensusSourceIDs = Set(deviceMatchConsensus.sources.map(\.id))
            let consensusIdentities = deviceMatchConsensus.sources.compactMap(\.deviceIdentity)
            guard metadataSourceIDs == consensusSourceIDs,
                  metadata.measurementConfidence == deviceMatchConsensus.confidence,
                  Set(metadata.measurementSnapshots) == Set(deviceMatchConsensus.snapshots),
                  consensusIdentities.allSatisfy({ $0 == metadata.deviceIdentity }) else {
                throw TargetError.deviceMatchTargetMismatch
            }
            response = FrequencyResponse(
                name: "Device Match · \(metadata.deviceName)",
                points: deviceMatchConsensus.response.points
            )
            confidence = deviceMatchConsensus.confidence
        }

        return DeviceCorrectionTargetResolution(
            response: response,
            rigFamily: family,
            usedFallbackRig: measuredFamily == .unknown && usesPresetFixture,
            confidence: confidence
        )
    }

    func compatibilityMessage(
        for selection: DeviceCorrectionTargetSelection,
        sources: [DeviceMeasurementReference],
        deviceMatchSources: [DeviceMeasurementReference] = []
    ) -> String {
        let family = DeviceCorrectionRigFamily.identify(from: sources)
        let preset = selection.preset
        if preset == .flat {
            return "Flat is a diagnostic curve and does not add a named listening preference."
        }
        if preset == .custom {
            guard let targetFamily = selection.customTargetRigIdentity?.family,
                  targetFamily != .unknown else {
                return "Choose the fixture used to produce the custom target CSV."
            }
            if family == .unknown {
                return "The target is declared as \(targetFamily.title), but the measurement fixture is unknown and cannot be verified."
            }
            if family != targetFamily {
                return "The target is \(targetFamily.title), but the measurement uses \(family.title). Choose matching data."
            }
            return "The custom target and selected measurements both use \(family.title)."
        }
        if preset == .deviceMatch {
            guard selection.deviceMatchTarget != nil else {
                return "Choose a second device measured on the same form and structured fixture."
            }
            return DeviceMatchPlanner.isCompatible(
                sourceReferences: sources,
                targetReferences: deviceMatchSources
            )
                ? "Both devices use the same form, fixture, coupler, pinna, and calibration group."
                : "The two devices do not have compatible measurement fixtures and cannot be matched safely."
        }
        if family == .unknown, preset != .flat, preset != .custom {
            return "The imported measurement does not identify its fixture. CamiTune will assume IEC 711; verify this before generating correction."
        }
        let only711: Set<DeviceCorrectionTargetPreset> = [
            .harmanInEar2019V2, .iefNeutral2023, .etymotic
        ]
        if family == .bk5128, only711.contains(preset) {
            return "This preset is defined for IEC 711 measurements and cannot be safely applied to the selected B&K measurement."
        }
        if preset == .jm1PopAvgDFTilt || preset == .iefPreference2025
            || preset == .diffuseFieldReference {
            return "CamiTune will use the \(family.title) variant for the selected measurements."
        }
        return "Designed for \(family.title) measurements."
    }

    private func jm1(
        family: DeviceCorrectionRigFamily,
        tiltDBPerOctave: Double
    ) throws -> FrequencyResponse {
        let base: FrequencyResponse
        switch family {
        case .bk5128:
            // AutoEq publishes JM-1 after the standard −4 dB treble shelf. Undo it
            // to recover the PopAvg-DF baseline before applying the user's tilt.
            base = try applying(
                filters: [EQBand(kind: .highShelf, frequency: 2_500, gain: 4, q: 0.4)],
                to: load("jm1-harman-treble-5128", as: "JM-1 / PopAvg-DF (B&K 5128)")
            )
        case .iec711, .unknown:
            base = try load("jm1-transfer-711", as: "JM-1 / PopAvg-DF transfer (711)")
        }
        return FrequencyResponse(
            name: "JM-1 / PopAvg-DF \(tiltDBPerOctave.formatted(.number.precision(.fractionLength(1)))) dB/oct (\(family.title))",
            points: base.points.map {
                .init(
                    frequency: $0.frequency,
                    magnitudeDB: $0.magnitudeDB
                        + tiltDBPerOctave * log2($0.frequency / 1_000)
                )
            }
        )
    }

    private func iefPreference2025(
        family: DeviceCorrectionRigFamily
    ) throws -> FrequencyResponse {
        switch family {
        case .bk5128:
            // The source already contains the published −4 dB / 2.5 kHz / Q 0.4 shelf.
            return try applying(
                filters: [EQBand(kind: .lowShelf, frequency: 80, gain: 10, q: 0.71)],
                to: load("jm1-harman-treble-5128", as: "IEF Preference 2025 (B&K 5128)"),
                name: "IEF Preference 2025 (B&K 5128)"
            )
        case .iec711, .unknown:
            return try applying(
                filters: [
                    EQBand(kind: .highShelf, frequency: 2_500, gain: -4, q: 0.4),
                    EQBand(kind: .lowShelf, frequency: 105, gain: 8, q: 0.71)
                ],
                to: load("jm1-transfer-711", as: "IEF Preference 2025 (711)"),
                name: "IEF Preference 2025 (711)"
            )
        }
    }

    private func applying(
        filters: [EQBand],
        to response: FrequencyResponse,
        name: String? = nil
    ) throws -> FrequencyResponse {
        let parsed = ParsedEQ(preampDB: 0, bands: filters, warnings: [])
        let calculator = EQResponseCalculator()
        return FrequencyResponse(
            name: name ?? response.name,
            points: response.points.map {
                .init(
                    frequency: $0.frequency,
                    magnitudeDB: $0.magnitudeDB + calculator.gainDB(
                        at: $0.frequency,
                        parsed: parsed,
                        sampleRate: 96_000
                    )
                )
            }
        )
    }

    private func load(_ fileName: String, as name: String) throws -> FrequencyResponse {
        guard let url = targetResourceURL(fileName) else {
            throw TargetError.resourceMissing(fileName)
        }
        return try FrequencyResponseCSVImporter().parse(
            String(contentsOf: url, encoding: .utf8),
            name: name
        )
    }

    private func targetResourceURL(_ fileName: String) -> URL? {
#if SWIFT_PACKAGE
        if let url = Bundle.module.url(
            forResource: fileName,
            withExtension: "csv",
            subdirectory: "DeviceCorrectionTargets"
        ) {
            return url
        }
#endif
        return Bundle.main.url(
            forResource: fileName,
            withExtension: "csv",
            subdirectory: "DeviceCorrectionTargets"
        )
    }

    private func require(
        _ required: DeviceCorrectionRigFamily,
        actual: DeviceCorrectionRigFamily,
        preset: DeviceCorrectionTargetPreset
    ) throws {
        guard required == actual else {
            throw TargetError.incompatibleRig(
                target: preset.title,
                required: required.title,
                actual: actual.title
            )
        }
    }

    enum TargetError: LocalizedError, Equatable {
        case customTargetMissing
        case customTargetFixtureMissing
        case deviceMatchTargetMissing
        case incompatibleDeviceMatchRig
        case deviceMatchTargetMismatch
        case resourceMissing(String)
        case incompatibleRig(target: String, required: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .customTargetMissing:
                return "Import a custom target CSV before generating correction."
            case .customTargetFixtureMissing:
                return "Choose the fixture used by the custom target CSV before generating correction."
            case .deviceMatchTargetMissing:
                return "Choose a target device for Device Match before generating correction."
            case .incompatibleDeviceMatchRig:
                return "Device Match requires both devices to use the same measurement form and structured fixture calibration."
            case .deviceMatchTargetMismatch:
                return "The Device Match response no longer matches its saved device identity and measurement snapshot. Refresh the target measurements."
            case let .resourceMissing(name):
                return "The bundled target data ‘\(name)’ could not be loaded."
            case let .incompatibleRig(target, required, actual):
                return "\(target) requires \(required) data, but the selected measurements use \(actual)."
            }
        }
    }
}
