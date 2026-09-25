import Foundation

/// The transducer connected to an output, independent of the signal's channel role.
package enum SpeakerFunction: String, Codable, Hashable, Sendable, CaseIterable {
    case fullRange, subwoofer, woofer, midrange, tweeter, custom

    package var displayName: String {
        switch self {
        case .fullRange: return "Full range"
        case .subwoofer: return "Subwoofer"
        case .woofer: return "Woofer"
        case .midrange: return "Midrange"
        case .tweeter: return "Tweeter"
        case .custom: return "Custom"
        }
    }
}

package enum SpeakerAssignmentOrigin: String, Codable, Hashable, Sendable {
    case hardware, template, user
}

package struct SpeakerGroupID: RawRepresentable, Codable, Hashable, Sendable {
    package init(rawValue: String) { self.rawValue = rawValue }

    package let rawValue: String
}

package enum SpeakerGroupKind: String, Codable, Hashable, Sendable, CaseIterable {
    case front, surround, rear, height, subwoofers, custom

    package var displayName: String {
        switch self {
        case .front: return "Front"
        case .surround: return "Surround"
        case .rear: return "Rear"
        case .height: return "Height"
        case .subwoofers: return "Subwoofers"
        case .custom: return "Custom"
        }
    }
}

package struct SpeakerGroup: Codable, Hashable, Sendable, Identifiable {
    package init(id: SpeakerGroupID, name: String, kind: SpeakerGroupKind, members: [PhysicalOutputID]) {
        self.id = id; self.name = name; self.kind = kind; self.members = members
    }

    package var id: SpeakerGroupID
    package var name: String
    package var kind: SpeakerGroupKind
    package var members: [PhysicalOutputID]

    package static func standardGroups(for endpoints: [SpeakerEndpoint]) -> [Self] {
        SpeakerGroupKind.allCases.filter { $0 != .custom }.compactMap { kind in
            let members = endpoints.filter {
                $0.connectionState != .disabledByUser && $0.connectionState != .silent && groupKind(for: $0) == kind
            }.map(\.id)
            guard !members.isEmpty else { return nil }
            return Self(id: SpeakerGroupID(rawValue: "standard:\(kind.rawValue)"), name: kind.displayName,
                        kind: kind, members: members)
        }
    }

    private static func groupKind(for endpoint: SpeakerEndpoint) -> SpeakerGroupKind? {
        if endpoint.function == .subwoofer { return .subwoofers }
        switch endpoint.role {
        case .left, .right, .center, .frontLeftCenter, .frontRightCenter, .wideLeft, .wideRight: return .front
        case .leftSurround, .rightSurround: return .surround
        case .leftRearSurround, .rightRearSurround: return .rear
        case .topFrontLeft, .topFrontRight, .topMiddleLeft, .topMiddleRight, .topRearLeft, .topRearRight, .topCenter: return .height
        case .lowFrequencyEffects, .unknown: return nil
        }
    }
}

extension SpeakerTopology {
    package mutating func refreshStandardGroups() {
        groups = groups.filter { $0.kind == .custom } + SpeakerGroup.standardGroups(for: endpoints)
    }
}
