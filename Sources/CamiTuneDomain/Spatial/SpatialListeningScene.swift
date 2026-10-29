import Foundation

package enum PersonalSpatialExperience: String, Codable, Hashable, CaseIterable, Sendable {
    case spatialListening, speakerMimic
    package var title: String { self == .spatialListening ? "Spatial listening" : "Speaker mimic" }
}

/// Only the selected scene is prepared. Source coordinates are part of the
/// identity so a format change cannot reuse filters for different directions.
package enum PersonalSpatialSceneIntent: Hashable, Sendable {
    case spatialListening(SpatialListeningScene, LPCMChannelLayout)
    case speakerMimic(VirtualSpeakerScene)

    package var experience: PersonalSpatialExperience {
        switch self {
        case .spatialListening: return .spatialListening
        case .speakerMimic: return .speakerMimic
        }
    }
    package var acoustics: PersonalSpatialRoom {
        switch self {
        case .spatialListening(let scene, _): return scene.acoustics
        case .speakerMimic(let scene): return scene.acoustics
        }
    }
    package var isMeasured: Bool {
        if case .speakerMimic(let scene) = self { return scene.roomModel == .sadieStudio }
        return false
    }
}

package enum SpatialSourcePositionOrigin: String, Sendable {
    case supplied, nominal, custom
    package var title: String {
        switch self {
        case .supplied: return "Supplied position"
        case .nominal: return "Layout direction"
        case .custom: return "Custom placement"
        }
    }
}

/// Identity is the actual channel slot within its ordered layout, not a role
/// dictionary that could collapse repeated roles or unrelated custom sources.
package struct SpatialListeningSource: Identifiable, Sendable {
    package let id: AudioChannelID
    package let inputIndex: Int
    package let role: ChannelRole
    package let position: SpatialVector3?
    package let origin: SpatialSourcePositionOrigin
    package let name: String
}

package struct SpatialListeningPlacement: Codable, Hashable, Sendable {
    package var layout: LPCMChannelLayout
    package var distance: ListeningDistance?
    package var listener = SpatialVector3(x: 0, y: 0, z: 0)
    package var positions: [AudioChannelID: SpatialVector3] = [:]
    package init(layout: LPCMChannelLayout) { self.layout = layout.signalSignature }
}

/// One room with layout-scoped placement edits. Unedited sources retain the
/// supplied coordinates, or the existing nominal role directions when absent.
package struct SpatialListeningScene: Codable, Hashable, Sendable {
    package var acoustics = PersonalSpatialRoom()
    package var placements: [SpatialListeningPlacement] = []
    package init() {
        // A generic surrounding space permits the full sphere. This is not
        // a measurement of the listener's physical room or seated ear height.
        acoustics.minimum.z = -4.5
        acoustics.maximum.z = 4.5
    }

    package func placement(for layout: LPCMChannelLayout) -> SpatialListeningPlacement {
        placements.first { $0.layout.signalSignature == layout.signalSignature } ?? .init(layout: layout)
    }

    package func sources(for layout: LPCMChannelLayout) throws -> [SpatialListeningSource] {
        try layout.validate()
        let edit = placement(for: layout)
        let suppliedDistances = layout.roles.indices.compactMap { index -> Float? in
            guard layout.roles[index] != .lowFrequencyEffects else { return nil }
            return layout.positions?[index]?.distanceMeters
        }
        let scale: Float
        if let preset = edit.distance, !suppliedDistances.isEmpty {
            scale = preset.meters / (suppliedDistances.reduce(0, +) / Float(suppliedDistances.count))
        } else { scale = 1 }
        return try layout.roles.enumerated().map { index, role in
            let id = AudioChannelID.source(index)
            let name = role == .unknown ? "Source \(index + 1)" : role.displayName
                + (layout.roles.filter { $0 == role }.count > 1 ? " · \(index + 1)" : "")
            if role == .lowFrequencyEffects {
                return .init(id: id, inputIndex: index, role: role, position: nil, origin: .supplied, name: name)
            }
            let point: SpatialVector3
            let origin: SpatialSourcePositionOrigin
            if let custom = edit.positions[id] {
                point = custom; origin = .custom
            } else if var supplied = layout.positions?[index] {
                supplied.distanceMeters = supplied.distanceMeters.map { $0 * scale } ?? (edit.distance ?? .near).meters
                point = SpeakerLayoutGeometry.vector(supplied)
                origin = edit.distance == nil ? .supplied : .custom
            } else if var nominal = StandardSpeakerPositions.position(for: role) {
                nominal.distanceMeters = (edit.distance ?? .near).meters
                point = SpeakerLayoutGeometry.vector(nominal); origin = .nominal
            } else {
                throw PersonalSpatialError.unsupportedSourceLayout
            }
            guard acoustics.contains(point), SpatialVector3.distance(point, edit.listener) >= 1 else {
                throw PersonalSpatialError.invalidGeometry
            }
            return .init(id: id, inputIndex: index, role: role, position: point, origin: origin, name: name)
        }
    }

    package func validate() throws {
        try acoustics.validate()
        guard placements.count <= 16,
              Set(placements.map { $0.layout.signalSignature }).count == placements.count else {
            throw PersonalSpatialError.invalidSourcePlacement
        }
        for edit in placements {
            try edit.layout.validate()
            let ids = Set(edit.layout.roles.indices.filter { edit.layout.roles[$0] != .lowFrequencyEffects }.map(AudioChannelID.source))
            guard Set(edit.positions.keys).isSubset(of: ids), acoustics.contains(edit.listener) else {
                throw PersonalSpatialError.invalidSourcePlacement
            }
            _ = try sources(for: edit.layout)
        }
    }

    @discardableResult
    package mutating func move(_ id: AudioChannelID?, to point: SpatialVector3, layout: LPCMChannelLayout) -> Bool {
        var edit = placement(for: layout)
        if let id { edit.positions[id] = point } else { edit.listener = point }
        return replace(edit)
    }

    @discardableResult
    package mutating func load(_ distance: ListeningDistance, layout: LPCMChannelLayout) -> Bool {
        var edit = SpatialListeningPlacement(layout: layout)
        edit.distance = distance
        return replace(edit)
    }

    package mutating func resetPlacement(for layout: LPCMChannelLayout) {
        placements.removeAll { $0.layout.signalSignature == layout.signalSignature }
    }

    private mutating func replace(_ edit: SpatialListeningPlacement) -> Bool {
        var candidate = self
        if let index = placements.firstIndex(where: { $0.layout.signalSignature == edit.layout.signalSignature }) {
            candidate.placements[index] = edit
        } else { candidate.placements.append(edit) }
        guard (try? candidate.validate()) != nil else { return false }
        self = candidate
        return true
    }

}
