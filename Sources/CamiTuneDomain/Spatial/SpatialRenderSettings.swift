import Foundation

package enum SpatialOutputKind: String, Codable, Sendable { case headphones, speakers }
package enum SpatialContentKind: String, Codable, Sendable { case music, cinema }
package enum SpatialOutputSelection: String, Codable, CaseIterable, Sendable { case automatic, headphones, speakers }
package enum SpatialContentSelection: String, Codable, CaseIterable, Sendable { case automatic, music, cinema }

package struct MusicSpatialIntent: Codable, Hashable, Sendable {
    package init(amount: Float = 0.5) {
        self.amount = amount
    }

    package var amount: Float = 0.5
}

package struct CinemaSpatialIntent: Codable, Hashable, Sendable {
    package init(amount: Float = 0.5, dialogueFocus: Float = 0) {
        self.amount = amount
        self.dialogueFocus = dialogueFocus
    }

    package var amount: Float = 0.5
    package var dialogueFocus: Float = 0
}

/// Version 2 adds named listening positions; version 1 migrates its single seat.
package struct SpatialRenderSettings: Codable, Hashable, Sendable {
    package var version = 2
    package var enabled = false
    package var outputSelection: SpatialOutputSelection = .automatic
    package var contentSelection: SpatialContentSelection = .automatic
    package var music = MusicSpatialIntent()
    package var cinema = CinemaSpatialIntent()
    package var listeningPositions: [SpatialSeatingCalibration] = []
    package var primaryPositionID: UUID?
    package var selectedPositionID: UUID?
    package var seating: SpatialSeatingCalibration? {
        get { listeningPositions.first { $0.id == selectedPositionID } }
        set {
            guard let seat = newValue else { selectedPositionID = nil; return }
            if let index = listeningPositions.firstIndex(where: { $0.id == seat.id }) { listeningPositions[index] = seat }
            else { listeningPositions.append(seat) }
            selectedPositionID = seat.id
            if primaryPositionID == nil { primaryPositionID = seat.id }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, enabled, outputSelection, contentSelection, music, cinema, seating, listeningPositions, selectedPositionID, primaryPositionID
    }

    package init() {}

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...2).contains(storedVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values,
                debugDescription: "Unsupported spatial settings version")
        }
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        outputSelection = try values.decodeIfPresent(SpatialOutputSelection.self, forKey: .outputSelection) ?? .automatic
        contentSelection = try values.decodeIfPresent(SpatialContentSelection.self, forKey: .contentSelection) ?? .automatic
        music = try values.decodeIfPresent(MusicSpatialIntent.self, forKey: .music) ?? MusicSpatialIntent()
        cinema = try values.decodeIfPresent(CinemaSpatialIntent.self, forKey: .cinema) ?? CinemaSpatialIntent()
        if storedVersion == 1 {
            seating = try values.decodeIfPresent(SpatialSeatingCalibration.self, forKey: .seating)
        } else {
            listeningPositions = try values.decodeIfPresent([SpatialSeatingCalibration].self, forKey: .listeningPositions) ?? []
            selectedPositionID = try values.decodeIfPresent(UUID.self, forKey: .selectedPositionID)
            guard Set(listeningPositions.map(\.id)).count == listeningPositions.count else {
                throw DecodingError.dataCorruptedError(forKey: .listeningPositions, in: values, debugDescription: "Duplicate listening-position IDs")
            }
            if !listeningPositions.contains(where: { $0.id == selectedPositionID }) { selectedPositionID = nil }
        }
        primaryPositionID = try values.decodeIfPresent(UUID.self, forKey: .primaryPositionID) ?? listeningPositions.first?.id
        if !listeningPositions.contains(where: { $0.id == primaryPositionID }) { primaryPositionID = listeningPositions.first?.id }
        music.amount = SpatialRenderIntent.unit(music.amount)
        cinema.amount = SpatialRenderIntent.unit(cinema.amount)
        cinema.dialogueFocus = SpatialRenderIntent.unit(cinema.dialogueFocus)
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .version)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(outputSelection, forKey: .outputSelection)
        try c.encode(contentSelection, forKey: .contentSelection)
        try c.encode(music, forKey: .music); try c.encode(cinema, forKey: .cinema)
        try c.encode(listeningPositions, forKey: .listeningPositions)
        try c.encodeIfPresent(selectedPositionID, forKey: .selectedPositionID)
        try c.encodeIfPresent(primaryPositionID, forKey: .primaryPositionID)
    }

    package static func migrated(from mode: SpatialRenderingMode) -> Self {
        var settings = Self()
        settings.enabled = mode != .standard
        return settings
    }

    package func resolvedOutput(deviceName: String) -> SpatialOutputKind {
        switch outputSelection {
        case .headphones: return .headphones
        case .speakers: return .speakers
        case .automatic:
            // Transport alone is insufficient: Bluetooth and USB also carry speakers.
            let name = deviceName.lowercased()
            return ["headphone", "headset", "airpods", "earbuds"].contains(where: name.contains)
                ? .headphones : .speakers
        }
    }
}
