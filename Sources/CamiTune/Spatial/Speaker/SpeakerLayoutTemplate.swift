import Foundation

/// A persisted setup choice, never a DSP mode or a hardware identity.
struct SpeakerLayoutTemplateID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    static let custom = Self(rawValue: "custom")
}

struct SpeakerLayoutTemplate: Identifiable, Hashable, Sendable {
    let id: SpeakerLayoutTemplateID
    let displayName: String
    let sourceLayout: LPCMChannelLayout?
    let endpointRoles: [ChannelRole]

    static let stereo = Self("stereo", "Stereo", layout: .stereo)
    static let fivePointOne = Self("5.1", "5.1", layout: .fivePointOne)
    static let sevenPointOne = Self("7.1", "7.1", layout: .sevenPointOne)
    static let fivePointOnePointFour = Self("5.1.4", "5.1.4", layout: .fivePointOnePointFour)
    static let sevenPointOnePointFour = Self("7.1.4", "7.1.4", layout: .sevenPointOnePointFour)

    // Only passive setups are offered until bass management/crossover protection exists.
    static let all: [Self] = [
        stereo,
        Self(id: SpeakerLayoutTemplateID(rawValue: "quad"), displayName: "Quad", sourceLayout: .quad,
             endpointRoles: [.left, .right, .leftSurround, .rightSurround]),
        fivePointOne, sevenPointOne,
        Self("5.1.2", "5.1.2", layout: .fivePointOnePointTwo),
        fivePointOnePointFour,
        Self("7.1.2", "7.1.2", layout: .sevenPointOnePointTwo),
        sevenPointOnePointFour,
        Self("9.1.6", "9.1.6", layout: .ninePointOnePointSix)
    ]

    private init(_ id: String, _ name: String, layout: LPCMChannelLayout) {
        self.id = SpeakerLayoutTemplateID(rawValue: id)
        displayName = name; sourceLayout = layout; endpointRoles = layout.roles
    }

    init(id: SpeakerLayoutTemplateID, displayName: String, sourceLayout: LPCMChannelLayout?, endpointRoles: [ChannelRole]) {
        self.id = id; self.displayName = displayName; self.sourceLayout = sourceLayout; self.endpointRoles = endpointRoles
    }

    static func available(outputCount: Int) -> [Self] { all.filter { $0.endpointRoles.count <= outputCount } }

    /// Metadata can suggest a setup only when every reported role matches.
    /// A discrete 12-channel device does not implicitly become 7.1.4.
    static func detected(in topology: SpeakerTopology) -> Self? {
        guard let roles = topology.hardwareRoles, !roles.contains(.unknown) else { return nil }
        return all.first { $0.endpointRoles.count == roles.count && Set($0.endpointRoles) == Set(roles) }
    }

    /// A default for the enabled speakers, without turning an estimate into
    /// hardware metadata. Explicit Custom and preset choices survive reopening.
    static func selected(in topology: SpeakerTopology, allowedOutputs: Set<Int>? = nil) -> Self? {
        if let id = topology.layoutTemplateID { return all.first { $0.id == id } }
        let roles = zip(topology.endpoints, SpeakerLayoutGeometry.layoutRoles(topology)).filter {
            $0.0.connectionState != .disabledByUser && (allowedOutputs?.contains($0.0.id.channelIndex) ?? true)
        }.map { $0.1 }
        return all.first { $0.endpointRoles.count == roles.count && Set($0.endpointRoles) == Set(roles) }
    }

    static func defaultRoles(count: Int, known: Set<ChannelRole>) -> [ChannelRole]? {
        all.first { $0.endpointRoles.count == count && known.isSubset(of: Set($0.endpointRoles)) }?.endpointRoles
    }

    /// Assign by existing semantic role first, then use free physical outputs in
    /// index order. User/acoustic placements and all physical IDs remain intact.
    func applying(to topology: SpeakerTopology, allowedOutputs: Set<Int>? = nil) throws -> SpeakerTopology {
        try topology.validate()
        let available = topology.endpoints.filter { allowedOutputs?.contains($0.id.channelIndex) ?? true }
            .sorted { $0.id.channelIndex < $1.id.channelIndex }
        guard endpointRoles.count <= available.count else {
            throw ProfileSettingsError.runtime("This setup needs \(endpointRoles.count) enabled outputs.")
        }
        var assigned: [ChannelRole: PhysicalOutputID] = [:]
        var remaining = available
        // Reserve all known matches before using otherwise free outputs.
        for role in endpointRoles {
            if let index = remaining.firstIndex(where: { $0.role == role }) {
                assigned[role] = remaining.remove(at: index).id
            }
        }
        for role in endpointRoles where assigned[role] == nil {
            assigned[role] = remaining.removeFirst().id
        }
        var result = topology
        for index in result.endpoints.indices {
            let output = result.endpoints[index].id
            guard let role = endpointRoles.first(where: { assigned[$0] == output }) else {
                result.endpoints[index].connectionState = .disabledByUser
                continue
            }
            var endpoint = result.endpoints[index]
            let defaultName = endpoint.displayName == endpoint.role.displayName
                || endpoint.displayName == "Channel \(output.channelIndex + 1)"
            endpoint.role = role
            endpoint.roleOrigin = .template
            endpoint.layer = role.speakerLayer
            // A template explicitly chooses both role and connected speaker function.
            endpoint.function = role == .lowFrequencyEffects ? .subwoofer : .fullRange
            endpoint.connectionState = .confirmedByUser
            if defaultName { endpoint.displayName = role.displayName }
            if endpoint.position == nil || [.standardLayoutDefault, .unknown].contains(endpoint.positionSource) {
                endpoint.position = SpeakerLayoutGeometry.suggestedPosition(for: role)
                endpoint.positionSource = .standardLayoutDefault
            }
            result.endpoints[index] = endpoint
        }
        result.groups = topology.groups.filter { $0.kind == .custom } + SpeakerGroup.standardGroups(for: result.endpoints)
        result.layoutTemplateID = id
        try result.validate()
        return result
    }
}

/// Shared by the AppKit canvas and SwiftUI selected-speaker controls.
struct SpeakerRoleChoices {
    let common: [ChannelRole]
    let more: [ChannelRole]

    init(topology: SpeakerTopology, selectedRole: ChannelRole) {
        let template = SpeakerLayoutTemplate.selected(in: topology)
        let roles = template?.endpointRoles ?? zip(topology.endpoints, SpeakerLayoutGeometry.layoutRoles(topology))
            .filter { $0.0.connectionState != .disabledByUser && $0.1 != .unknown }.map { $0.1 }
        var seen = Set<ChannelRole>()
        common = ([selectedRole] + (roles.isEmpty ? [.left, .right] : roles))
            .filter { $0 != .unknown && seen.insert($0).inserted } + [.unknown]
        seen.insert(.unknown)
        more = ChannelRole.allCases.filter { !seen.contains($0) }
    }
}

enum SpeakerPlacementWarning: String, Identifiable {
    case leftOnRight, rightOnLeft, heightBelowListener
    var id: String { rawValue }
    var message: String {
        switch self {
        case .leftOnRight: return "This left speaker is to the right of your listening position."
        case .rightOnLeft: return "This right speaker is to the left of your listening position."
        case .heightBelowListener: return "Height speakers normally sit above your listening position."
        }
    }
    static func warnings(for endpoint: SpeakerEndpoint, listener: SpatialVector3) -> [Self] {
        guard endpoint.connectionState != .disabledByUser, let position = endpoint.position else { return [] }
        let point = SpeakerLayoutGeometry.vector(position)
        let left: Set<ChannelRole> = [.left, .leftSurround, .leftRearSurround, .topFrontLeft,
            .topMiddleLeft, .topRearLeft, .frontLeftCenter, .wideLeft]
        let right: Set<ChannelRole> = [.right, .rightSurround, .rightRearSurround, .topFrontRight,
            .topMiddleRight, .topRearRight, .frontRightCenter, .wideRight]
        var result: [Self] = []
        if left.contains(endpoint.role), point.x > listener.x + 0.1 { result.append(.leftOnRight) }
        if right.contains(endpoint.role), point.x < listener.x - 0.1 { result.append(.rightOnLeft) }
        if endpoint.role.speakerLayer == .height, point.z <= listener.z + 0.1 { result.append(.heightBelowListener) }
        return result
    }
}
