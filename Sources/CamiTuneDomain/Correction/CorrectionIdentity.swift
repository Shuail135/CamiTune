import Foundation

package enum DeviceMeasurementOrigin: String, Codable, Hashable, Sendable {
    case local
    case squiglink
    case autoEq
    case independent
}

package struct MeasurementRigIdentity: Codable, Hashable, Sendable {
    package init(
        family: DeviceCorrectionRigFamily,
        fixtureModel: String? = nil,
        couplerModel: String? = nil,
        pinnaModel: String? = nil,
        calibrationVariant: String? = nil
    ) {
        self.family = family
        self.fixtureModel = fixtureModel
        self.couplerModel = couplerModel
        self.pinnaModel = pinnaModel
        self.calibrationVariant = calibrationVariant
    }

    package var family: DeviceCorrectionRigFamily
    package var fixtureModel: String?
    package var couplerModel: String?
    package var pinnaModel: String?
    package var calibrationVariant: String?

    package var stableKey: String {
        [
            family.rawValue,
            normalized(fixtureModel),
            normalized(couplerModel),
            normalized(pinnaModel),
            normalized(calibrationVariant)
        ].joined(separator: "|")
    }

    package static func inferred(fromLegacyName name: String?) -> Self {
        let value = DeviceNameNormalizer.key(for: name ?? "")
        let family: DeviceCorrectionRigFamily
        let fixture: String?
        let coupler: String?
        if value.contains("5128") || value.contains("4620") {
            family = .bk5128
            fixture = "B&K 5128"
            coupler = "B&K Type 4620"
        } else if value.contains("711") || value.contains("60318 4")
            || value.contains("43ac") || value.contains("ra0045")
            || value.contains("kemar") || value.contains("ears") {
            family = .iec711
            fixture = "IEC 60318-4"
            coupler = value.contains("ra0045") ? "GRAS RA0045"
                : (value.contains("43ac") ? "GRAS 43AC" : "711")
        } else {
            family = .unknown
            fixture = value.isEmpty ? nil : value
            coupler = nil
        }

        let pinna: String?
        if value.contains("kb5000") { pinna = "GRAS KB5000" }
        else if value.contains("kemar") { pinna = "KEMAR" }
        else if value.contains("ears") { pinna = "miniDSP EARS" }
        else { pinna = nil }

        // Preserve provider-specific suffixes as a calibration variant instead
        // of collapsing every string containing "711" or "5128" together.
        let structuralTokens: Set<String> = [
            "iec", "60318", "4", "711", "b", "k", "bruel", "kjaer",
            "5128", "4620", "type", "gras", "43ac", "ra0045", "kemar",
            "minidsp", "ears", "kb5000", "anthropometric", "pinna",
            "fixture", "coupler"
        ]
        let residualTokens = value.split(separator: " ").map(String.init).filter { token in
            !structuralTokens.contains(token)
                && token != "iec711"
                && token != "iec603184"
                && token != "bk5128"
        }
        let calibration = residualTokens.isEmpty
            ? nil
            : residualTokens.joined(separator: " ")

        return .init(
            family: family,
            fixtureModel: fixture,
            couplerModel: coupler,
            pinnaModel: pinna,
            calibrationVariant: calibration
        )
    }

    package static func canonical(for family: DeviceCorrectionRigFamily) -> Self {
        switch family {
        case .iec711:
            return .init(
                family: .iec711,
                fixtureModel: "IEC 60318-4",
                couplerModel: "711",
                pinnaModel: nil,
                calibrationVariant: nil
            )
        case .bk5128:
            return .init(
                family: .bk5128,
                fixtureModel: "B&K 5128",
                couplerModel: "B&K Type 4620",
                pinnaModel: "anthropometric pinna",
                calibrationVariant: nil
            )
        case .unknown:
            return .init(
                family: .unknown,
                fixtureModel: nil,
                couplerModel: nil,
                pinnaModel: nil,
                calibrationVariant: nil
            )
        }
    }

    private func normalized(_ value: String?) -> String {
        DeviceNameNormalizer.key(for: value ?? "unspecified")
    }
}

package struct DeviceConfigurationIdentity: Codable, Hashable, Sendable {
    package init(namespace: String, deviceID: String, configurationID: String) {
        self.namespace = namespace
        self.deviceID = deviceID
        self.configurationID = configurationID
    }

    package var namespace: String
    package var deviceID: String
    package var configurationID: String

    package var stableKey: String { "\(namespace)|\(deviceID)|\(configurationID)" }

    package static func inferred(from displayName: String) -> Self {
        let normalized = DeviceNameAliasCatalog.canonicalKey(for: displayName)
        let baseName = displayName.split(separator: "(", maxSplits: 1).first.map(String.init)
            ?? displayName
        return .init(
            namespace: "camitune-device-catalog-v1",
            deviceID: StableContentHash.string(
                DeviceNameAliasCatalog.canonicalKey(for: baseName)
            ),
            configurationID: StableContentHash.string(normalized)
        )
    }
}

package struct MeasurementSnapshot: Codable, Hashable, Sendable {
    package init(
        providerID: String,
        retrievalProviderID: String? = nil,
        datasetID: String,
        datasetVersion: String? = nil,
        measurementID: String,
        contentHash: String,
        retrievedAt: Date
    ) {
        self.providerID = providerID
        self.retrievalProviderID = retrievalProviderID
        self.datasetID = datasetID
        self.datasetVersion = datasetVersion
        self.measurementID = measurementID
        self.contentHash = contentHash
        self.retrievedAt = retrievedAt
    }

    package var providerID: String
    package var retrievalProviderID: String? = nil
    package var datasetID: String
    package var datasetVersion: String?
    package var measurementID: String
    package var contentHash: String
    package var retrievedAt: Date
}

package enum StableContentHash {
    /// Deterministic FNV-1a identifier used for local cache keys and snapshots.
    /// This detects dataset changes; it is not intended as a security primitive.
    package static func data(_ data: Data) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return String(
            format: "%016llx",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    package static func string(_ value: String) -> String { data(Data(value.utf8)) }
}

package struct DeviceMeasurementReference: Codable, Hashable, Sendable, Identifiable {
    package init(
        providerID: String,
        retrievalProviderID: String? = nil,
        catalogName: String,
        sourceName: String,
        form: String? = nil,
        rig: String? = nil,
        origin: DeviceMeasurementOrigin,
        reliability: Double,
        deviceIdentity: DeviceConfigurationIdentity? = nil,
        laboratoryID: String? = nil,
        unitID: String? = nil,
        measurementID: String? = nil,
        datasetID: String? = nil,
        datasetVersion: String? = nil,
        rigIdentity: MeasurementRigIdentity? = nil
    ) {
        self.providerID = providerID
        self.retrievalProviderID = retrievalProviderID
        self.catalogName = catalogName
        self.sourceName = sourceName
        self.form = form
        self.rig = rig
        self.origin = origin
        self.reliability = reliability
        self.deviceIdentity = deviceIdentity
        self.laboratoryID = laboratoryID
        self.unitID = unitID
        self.measurementID = measurementID
        self.datasetID = datasetID
        self.datasetVersion = datasetVersion
        self.rigIdentity = rigIdentity
    }

    package var providerID: String
    /// Service used to retrieve the response when it differs from the actual
    /// measurement provider. For example, AutoEQ can transport Squiglink data
    /// without becoming its provenance provider.
    package var retrievalProviderID: String? = nil
    package var catalogName: String
    package var sourceName: String
    package var form: String?
    package var rig: String?
    package var origin: DeviceMeasurementOrigin
    package var reliability: Double
    package var deviceIdentity: DeviceConfigurationIdentity? = nil
    package var laboratoryID: String? = nil
    package var unitID: String? = nil
    package var measurementID: String? = nil
    package var datasetID: String? = nil
    package var datasetVersion: String? = nil
    package var rigIdentity: MeasurementRigIdentity? = nil

    package var id: String {
        if let measurementID, !measurementID.isEmpty {
            return "\(providerID)|\(measurementID)"
        }
        return [providerID, catalogName, sourceName, form ?? "", rig ?? ""]
            .joined(separator: "\u{1f}")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    package var compatibilityKey: String {
        let normalizedForm = DeviceNameNormalizer.key(for: form ?? "unknown-form")
        return "\(normalizedForm)|\(resolvedRigIdentity.stableKey)"
    }

    package var resolvedRigIdentity: MeasurementRigIdentity {
        rigIdentity ?? .inferred(fromLegacyName: rig)
    }

    package var resolvedRetrievalProviderID: String {
        retrievalProviderID ?? providerID
    }

    /// Multiple files or exports from the same physical unit are one piece of
    /// independent evidence, not multiple votes.
    package var independentEvidenceKey: String {
        let laboratory = laboratoryID ?? DeviceNameNormalizer.key(for: sourceName)
        let unit = unitID ?? "unspecified-unit"
        return "\(laboratory)|\(unit)"
    }

    /// Units from one laboratory share fixture/calibration error and therefore
    /// are correlated evidence even when their physical unit IDs differ.
    package var laboratoryCorrelationKey: String {
        laboratoryID ?? DeviceNameNormalizer.key(for: sourceName)
    }

    package static func local(name: String) -> DeviceMeasurementReference {
        DeviceMeasurementReference(
            providerID: "local",
            catalogName: name,
            sourceName: "Local file",
            form: nil,
            rig: nil,
            origin: .local,
            reliability: 1
        )
    }
}

package enum DeviceNameNormalizer {
    /// Normalizes spelling mechanics only. Parenthetical text, switch positions, nozzles,
    /// pads, ANC states, and other configuration words remain part of the identity.
    package static func key(for name: String) -> String {
        let folded = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let words = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
        return words
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
    }
}

package enum DeviceNameAliasCatalog {
    private static let curatedRules: [(alias: String, canonical: String)] = [
        ("thieaudio monarch mkii", "thieaudio monarch mk ii"),
        ("thieaudio monarch mk2", "thieaudio monarch mk ii"),
        ("unique melody mest mkii", "unique melody mest mk ii"),
        ("unique melody mest mk2", "unique melody mest mk ii"),
        ("moondrop blessing2", "moondrop blessing 2"),
        ("sony ier m 9", "sony ier m9"),
        ("sony ier z 1 r", "sony ier z1r"),
        ("seven hertz", "7hz"),
        ("thie audio", "thieaudio"),
        ("moon drop", "moondrop"),
        ("7 hz", "7hz")
    ].sorted { $0.alias.count > $1.alias.count }

    package static func canonicalKey(for name: String) -> String {
        var value = DeviceNameNormalizer.key(for: name)
        for _ in 0..<4 {
            guard let rule = curatedRules.first(where: {
                value == $0.alias || value.hasPrefix($0.alias + " ")
            }) else { break }
            value = rule.canonical + String(value.dropFirst(rule.alias.count))
        }
        return value
    }
}
