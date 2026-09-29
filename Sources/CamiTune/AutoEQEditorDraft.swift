import CamiTuneDomain
import Foundation

struct AutoEQEditorDraft: Codable, Equatable, Sendable {
    var schemaVersion = 2
    var sampleRate: Double
    var reference: DeviceCorrectionProfile?
    var deviceName: String
    var searchText: String
    var selectedCatalogID: String?
    var sourceMeasurements: [DeviceCorrectionMeasurement]
    var measurement: FrequencyResponse?
    var policy: DeviceCorrectionPolicyKind
    var settings: AutoEQSettings
    var targetChosen: Bool
    var targetSelection: DeviceCorrectionTargetSelection
    var customTarget: FrequencyResponse?
    var deviceMatchSearchText: String
    var selectedDeviceMatchCatalogID: String?
    var deviceMatchConsensus: MeasurementConsensus?
    var generated: DeviceCorrectionProfile?
    var automaticHeadroomDB: Double
    var presentation: AutoEQPresentationPreferences

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sampleRate
        case reference
        case deviceName
        case searchText
        case selectedCatalogID
        case sourceMeasurements
        case measurement
        case policy
        case settings
        case targetChosen
        case targetSelection
        case customTarget
        case deviceMatchSearchText
        case selectedDeviceMatchCatalogID
        case deviceMatchConsensus
        case generated
        case automaticHeadroomDB
        case presentation
    }

    func restored(for sampleRate: Double) -> Self {
        var value = self
        if value.sampleRate != sampleRate {
            value.generated = nil
            value.automaticHeadroomDB = 0
            value.sampleRate = sampleRate
        }
        return value
    }
}

extension AutoEQEditorDraft {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        reference = try values.decodeIfPresent(DeviceCorrectionProfile.self, forKey: .reference)
        deviceName = try values.decode(String.self, forKey: .deviceName)
        searchText = try values.decode(String.self, forKey: .searchText)
        selectedCatalogID = try values.decodeIfPresent(String.self, forKey: .selectedCatalogID)
        sourceMeasurements = try values.decode([DeviceCorrectionMeasurement].self, forKey: .sourceMeasurements)
        measurement = try values.decodeIfPresent(FrequencyResponse.self, forKey: .measurement)
        policy = try values.decode(DeviceCorrectionPolicyKind.self, forKey: .policy)
        settings = try values.decode(AutoEQSettings.self, forKey: .settings)
        targetChosen = try values.decode(Bool.self, forKey: .targetChosen)
        targetSelection = try values.decode(DeviceCorrectionTargetSelection.self, forKey: .targetSelection)
        customTarget = try values.decodeIfPresent(FrequencyResponse.self, forKey: .customTarget)
        deviceMatchSearchText = try values.decode(String.self, forKey: .deviceMatchSearchText)
        selectedDeviceMatchCatalogID = try values.decodeIfPresent(String.self, forKey: .selectedDeviceMatchCatalogID)
        deviceMatchConsensus = try values.decodeIfPresent(MeasurementConsensus.self, forKey: .deviceMatchConsensus)
        generated = try values.decodeIfPresent(DeviceCorrectionProfile.self, forKey: .generated)
        automaticHeadroomDB = try values.decode(Double.self, forKey: .automaticHeadroomDB)
        presentation = try values.decodeIfPresent(AutoEQPresentationPreferences.self, forKey: .presentation)
            ?? Self.decodeLegacyPresentation(from: decoder)
    }

    private enum LegacyPresentationKeys: String, CodingKey {
        case resultsExpanded, advancedExpanded, detailsExpanded
    }

    private static func decodeLegacyPresentation(from decoder: Decoder) throws -> AutoEQPresentationPreferences {
        let values = try decoder.container(keyedBy: LegacyPresentationKeys.self)
        return AutoEQPresentationPreferences(
            resultsExpanded: try values.decodeIfPresent(Bool.self, forKey: .resultsExpanded) ?? true,
            advancedExpanded: try values.decodeIfPresent(Bool.self, forKey: .advancedExpanded) ?? false,
            detailsExpanded: try values.decodeIfPresent(Bool.self, forKey: .detailsExpanded) ?? false)
    }
}
