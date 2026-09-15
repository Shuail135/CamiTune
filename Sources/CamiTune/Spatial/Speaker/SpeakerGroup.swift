import Foundation

/// The transducer connected to an output, independent of the signal's channel role.
enum SpeakerFunction: String, Codable, Hashable, Sendable, CaseIterable {
    case fullRange, subwoofer, woofer, midrange, tweeter, custom

    var displayName: String {
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

enum SpeakerAssignmentOrigin: String, Codable, Hashable, Sendable {
    case hardware, template, user
}

struct SpeakerGroupID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

enum SpeakerGroupKind: String, Codable, Hashable, Sendable, CaseIterable {
    case front, surround, rear, height, subwoofers, custom

    var displayName: String {
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

struct SpeakerGroup: Codable, Hashable, Sendable, Identifiable {
    var id: SpeakerGroupID
    var name: String
    var kind: SpeakerGroupKind
    var members: [PhysicalOutputID]

    static func standardGroups(for endpoints: [SpeakerEndpoint]) -> [Self] {
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
    mutating func refreshStandardGroups() {
        groups = groups.filter { $0.kind == .custom } + SpeakerGroup.standardGroups(for: endpoints)
    }
}
