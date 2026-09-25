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
    package static let currentSchemaVersion = 7

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
