import Foundation

package enum DeviceCorrectionPolicyKind: String, Codable, Hashable, Sendable, CaseIterable {
    case recommended
    case exactTarget

    package var title: String {
        switch self {
        case .recommended: return "Recommended"
        case .exactTarget: return "Exact target"
        }
    }
}

package struct DeviceCorrectionProfile: Codable, Hashable, Sendable, Identifiable {
    package static let currentSchemaVersion = 8

    package var targetRegistryVersion: Int = 3
    package var autoEQSettings: AutoEQSettings = .init()
    package var correctionEngineVersion: Int = 3
    package var schemaVersion: Int
    package var id: UUID
    package var deviceName: String
    package var deviceIdentity: DeviceConfigurationIdentity
    package var isEnabled: Bool
    package var policy: DeviceCorrectionPolicyKind
    package var measurement: FrequencyResponse
    package var measurementConfidence: MeasurementConfidenceCurve
    package var sources: [DeviceMeasurementReference]
    package var measurementSnapshots: [MeasurementSnapshot]
    package var targetSelection: DeviceCorrectionTargetSelection
    package var target: FrequencyResponse
    package var curve: CorrectionCurve
    package var filters: [EQBand]
    package var preampDB: Double
    package var createdAt: Date
    package var importedAPOText = false

    package init(
        schemaVersion: Int = DeviceCorrectionProfile.currentSchemaVersion,
        id: UUID = UUID(),
        deviceName: String,
        deviceIdentity: DeviceConfigurationIdentity? = nil,
        isEnabled: Bool = true,
        policy: DeviceCorrectionPolicyKind,
        measurement: FrequencyResponse,
        measurementConfidence: MeasurementConfidenceCurve = .init(points: []),
        sources: [DeviceMeasurementReference] = [],
        measurementSnapshots: [MeasurementSnapshot] = [],
        targetSelection: DeviceCorrectionTargetSelection = .custom,
        target: FrequencyResponse,
        curve: CorrectionCurve,
        filters: [EQBand],
        preampDB: Double,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.deviceName = deviceName
        self.deviceIdentity = deviceIdentity ?? .inferred(from: deviceName)
        self.isEnabled = isEnabled
        self.policy = policy
        self.measurement = measurement
        self.measurementConfidence = measurementConfidence
        self.sources = sources
        self.measurementSnapshots = measurementSnapshots
        self.targetSelection = targetSelection
        self.target = target
        self.curve = curve
        self.filters = filters
        _ = preampDB
        self.preampDB = 0
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case autoEQSettings, correctionEngineVersion, targetRegistryVersion
        case schemaVersion
        case id
        case deviceName
        case deviceIdentity
        case isEnabled
        case policy
        case measurement
        case measurementConfidence
        case sources
        case measurementSnapshots
        case targetSelection
        case target
        case curve
        case filters
        case preampDB
        case createdAt
        case importedAPOText
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchemaVersion = try values.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? 1
        guard storedSchemaVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported Device Correction schema version \(storedSchemaVersion)."
            )
        }
        targetRegistryVersion = try values.decodeIfPresent(Int.self, forKey: .targetRegistryVersion) ?? 1
        autoEQSettings = try values.decodeIfPresent(AutoEQSettings.self, forKey: .autoEQSettings) ?? .init()
        correctionEngineVersion = try values.decodeIfPresent(Int.self, forKey: .correctionEngineVersion) ?? 1
        id = try values.decode(UUID.self, forKey: .id)
        deviceName = try values.decode(String.self, forKey: .deviceName)
        deviceIdentity = try values.decodeIfPresent(
            DeviceConfigurationIdentity.self,
            forKey: .deviceIdentity
        ) ?? .inferred(from: deviceName)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        policy = try values.decode(DeviceCorrectionPolicyKind.self, forKey: .policy)
        measurement = try values.decode(FrequencyResponse.self, forKey: .measurement)
        measurementConfidence = try values.decodeIfPresent(
            MeasurementConfidenceCurve.self,
            forKey: .measurementConfidence
        ) ?? .init(points: [])
        sources = try values.decodeIfPresent(
            [DeviceMeasurementReference].self,
            forKey: .sources
        ) ?? [.local(name: measurement.name)]
        measurementSnapshots = try values.decodeIfPresent(
            [MeasurementSnapshot].self,
            forKey: .measurementSnapshots
        ) ?? []
        target = try values.decode(FrequencyResponse.self, forKey: .target)
        targetSelection = try values.decodeIfPresent(
            DeviceCorrectionTargetSelection.self,
            forKey: .targetSelection
        ) ?? (target.name == FrequencyResponse.flat().name ? .flat : .custom)
        curve = try values.decode(CorrectionCurve.self, forKey: .curve)
        filters = try values.decode([EQBand].self, forKey: .filters)
        // This field was automatic headroom in schemas 1...3. Preserve wire
        // compatibility but migrate it to the runtime graph-wide calculation.
        _ = try values.decodeIfPresent(Double.self, forKey: .preampDB)
        preampDB = 0
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        importedAPOText = try values.decodeIfPresent(Bool.self, forKey: .importedAPOText) ?? false

        // Version-one profiles contained an already calculated response and remain valid.
        // Decoding upgrades the envelope so the runtime compiler can safely accept it.
        schemaVersion = Self.currentSchemaVersion
    }

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(targetRegistryVersion, forKey: .targetRegistryVersion)
        try values.encode(autoEQSettings, forKey: .autoEQSettings)
        try values.encode(correctionEngineVersion, forKey: .correctionEngineVersion)
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try values.encode(id, forKey: .id)
        try values.encode(deviceName, forKey: .deviceName)
        try values.encode(deviceIdentity, forKey: .deviceIdentity)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(policy, forKey: .policy)
        try values.encode(measurement, forKey: .measurement)
        try values.encode(measurementConfidence, forKey: .measurementConfidence)
        try values.encode(sources, forKey: .sources)
        try values.encode(measurementSnapshots, forKey: .measurementSnapshots)
        try values.encode(targetSelection, forKey: .targetSelection)
        try values.encode(target, forKey: .target)
        try values.encode(curve, forKey: .curve)
        try values.encode(filters, forKey: .filters)
        try values.encode(preampDB, forKey: .preampDB)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(importedAPOText, forKey: .importedAPOText)
    }
}

/// Requested bounds are persisted independently of the policy's effective bounds.
package struct AutoEQSettings: Codable, Hashable, Sendable {
    package var minimumFrequency: Double = 20
    package var maximumFrequency: Double = 10_000
    package var minimumGain: Double = -12
    package var maximumGain: Double = 6
    package var minimumQ: Double = 0.3
    package var maximumQ: Double = 6
    package init() {}
    package var isValid: Bool {
        [minimumFrequency, maximumFrequency, minimumGain, maximumGain, minimumQ, maximumQ].allSatisfy(\.isFinite)
        && minimumFrequency >= 20 && maximumFrequency <= 20_000 && minimumFrequency < maximumFrequency
        && minimumGain >= -24 && maximumGain <= 12 && minimumGain <= 0 && maximumGain >= 0
        && minimumGain < maximumGain && minimumQ >= 0.1 && maximumQ <= 12 && minimumQ <= maximumQ
    }
}

package enum DeviceForm: String, Codable, Sendable {
    case overEar, onEar, inEar, earbud
    package init?(catalogValue: String?) {
        switch DeviceNameNormalizer.key(for: catalogValue ?? "") {
        case "over ear", "overear", "headphone", "headphones": self = .overEar
        case "on ear", "onear": self = .onEar
        case "in ear", "inear", "iem": self = .inEar
        case "earbud", "earbuds": self = .earbud
        default: return nil
        }
    }
    package var isIEM: Bool { self == .inEar || self == .earbud }
}
