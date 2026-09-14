import Foundation

/// Room coordinates in metres: right, front and above the listener's head.
/// Role/title edits deliberately do not participate in geometry calculations.
enum SpeakerLayoutGeometry {
    static func vector(_ position: SpatialPosition?) -> SpatialVector3 {
        let position = position ?? SpatialPosition(azimuthDegrees: 0, elevationDegrees: 0, distanceMeters: 2)
        let unit = position.unitVector
        let distance = position.distanceMeters ?? 2
        return SpatialVector3(x: unit.x * distance, y: unit.y * distance, z: unit.z * distance)
    }

    static func position(x: Float, y: Float, height: Float) -> SpatialPosition {
        let horizontal = max(0.0001, sqrt(x * x + y * y))
        var azimuth = atan2(x, y) * 180 / .pi
        if azimuth >= 180 { azimuth -= 360 }
        return SpatialPosition(azimuthDegrees: azimuth,
            elevationDegrees: atan2(height, horizontal) * 180 / .pi,
            distanceMeters: sqrt(horizontal * horizontal + height * height))
    }

    static func distance(from position: SpatialPosition?, listenerX: Float, listenerY: Float) -> Float {
        let point = vector(position)
        return max(0.05, sqrt(pow(point.x - listenerX, 2) + pow(point.y - listenerY, 2) + point.z * point.z))
    }

    // Display-only origin: the fixed screen is 0.75 metres in front of the
    // original listener origin. Acoustic calculations keep listener coordinates.
    static let screenY: Float = 0.75
    static func screenCoordinates(_ point: SpatialVector3) -> SpatialVector3 {
        SpatialVector3(x: point.x, y: screenY - point.y, z: point.z)
    }
    static func dragged(_ start: SpatialVector3, x: Float, y: Float, pointsPerMeter: Float) -> SpatialVector3 {
        guard pointsPerMeter > 0 else { return start }
        return SpatialVector3(x: start.x + x / pointsPerMeter, y: start.y - y / pointsPerMeter, z: start.z)
    }

    /// Gentle screen-space attraction, with a small release margin to avoid flicker.
    static func snap(_ value: Float, anchors: [Float], previous: Float?, scale: Float) -> Float? {
        guard scale > 0 else { return nil }
        if let previous, abs(value - previous) * scale <= 6 { return previous }
        guard let nearest = anchors.min(by: { abs(value - $0) < abs(value - $1) }),
              abs(value - nearest) * scale <= 3 else { return nil }
        return nearest
    }

    static func horizontalDistanceLabel(_ metres: Float) -> String {
        String(format: "%g m", abs(metres) < 0.001 ? 0 : abs(metres))
    }
    static func depthDistanceLabel(_ metres: Float) -> String {
        horizontalDistanceLabel(metres)
    }

    /// Display estimates for unlabeled outputs, using the same order as the starting layout.
    /// These are not hardware metadata or confirmed routing assignments.
    static func layoutRoles(_ topology: SpeakerTopology) -> [ChannelRole] {
        let typical: [ChannelRole] = [.left, .right, .center, .lowFrequencyEffects,
            .leftSurround, .rightSurround, .leftRearSurround, .rightRearSurround,
            .topFrontLeft, .topFrontRight, .topRearLeft, .topRearRight,
            .topMiddleLeft, .topMiddleRight, .frontLeftCenter, .frontRightCenter,
            .wideLeft, .wideRight, .topCenter]
        let known = Set(topology.endpoints.map(\.role).filter { $0 != .unknown })
        var available = typical.filter { !known.contains($0) }
        // Four/five-channel rooms normally use surrounds rather than a subwoofer.
        if topology.endpoints.count == 1 { available = [.center] }
        if topology.endpoints.count == 4 { available.removeAll { $0 == .center || $0 == .lowFrequencyEffects } }
        if topology.endpoints.count == 5 { available.removeAll { $0 == .lowFrequencyEffects } }
        return topology.endpoints.map { endpoint in
            endpoint.role == .unknown && endpoint.connectionState != .confirmedByUser
                ? (available.isEmpty ? .unknown : available.removeFirst()) : endpoint.role
        }
    }

    /// A compact, draggable starting layout. Roles and hardware metadata stay intact.
    static func arrangedForEditing(_ topology: SpeakerTopology, previous: SpeakerTopology? = nil) -> SpeakerTopology {
        var result = topology
        let roles = layoutRoles(topology)
        var occurrences: [ChannelRole: Int] = [:]
        for index in result.endpoints.indices {
            if let prior = previous?.endpoints.first(where: { $0.id == result.endpoints[index].id }), prior.position != nil {
                result.endpoints[index].position = prior.position
                result.endpoints[index].positionSource = prior.positionSource
            } else if result.endpoints[index].positionSource != .coreAudioMetadata {
                // Unknown channels get useful initial locations, without inventing hardware roles.
                let layoutRole = roles[index]
                let duplicate = occurrences[layoutRole, default: 0]
                occurrences[layoutRole] = duplicate + 1
                var point = defaultPoint(for: layoutRole)
                if layoutRole == .unknown {
                    let angle = Float(duplicate) * 0.65
                    let radius: Float = 1.15 + Float(duplicate) * 0.04
                    point = SpatialVector3(x: sin(angle) * radius, y: cos(angle) * radius - 0.5, z: 0)
                } else if duplicate > 0 {
                    point.x += (point.x < 0 ? -1 : 1) * Float(duplicate) * 0.22
                    point.y -= Float(duplicate) * 0.22
                }
                result.endpoints[index].position = position(x: point.x, y: point.y, height: point.z)
                result.endpoints[index].positionSource = .standardLayoutDefault
            }
        }
        return result
    }

    private static func defaultPoint(for role: ChannelRole) -> SpatialVector3 {
        let x: Float, y: Float, z: Float
        switch role {
        case .left: (x, y, z) = (-0.45, 0.65, 0)
        case .right: (x, y, z) = (0.45, 0.65, 0)
        case .center: (x, y, z) = (0, 0.60, 0)
        case .lowFrequencyEffects: (x, y, z) = (-0.78, 0.50, 0)
        case .leftSurround: (x, y, z) = (-0.80, -0.15, 0)
        case .rightSurround: (x, y, z) = (0.80, -0.15, 0)
        case .leftRearSurround: (x, y, z) = (-0.55, -0.65, 0)
        case .rightRearSurround: (x, y, z) = (0.55, -0.65, 0)
        case .topFrontLeft: (x, y, z) = (-0.28, 0.30, 0.6)
        case .topFrontRight: (x, y, z) = (0.28, 0.30, 0.6)
        case .topMiddleLeft: (x, y, z) = (-0.45, -0.10, 0.6)
        case .topMiddleRight: (x, y, z) = (0.45, -0.10, 0.6)
        case .topRearLeft: (x, y, z) = (-0.28, -0.40, 0.6)
        case .topRearRight: (x, y, z) = (0.28, -0.40, 0.6)
        case .frontLeftCenter: (x, y, z) = (-0.22, 0.65, 0)
        case .frontRightCenter: (x, y, z) = (0.22, 0.65, 0)
        case .wideLeft: (x, y, z) = (-0.78, 0.20, 0)
        case .wideRight: (x, y, z) = (0.78, 0.20, 0)
        case .topCenter: (x, y, z) = (0, -0.30, 0.8)
        case .unknown: (x, y, z) = (0, 0, 0)
        }
        return SpatialVector3(x: x, y: y, z: z)
    }

    static func relativeTopology(_ topology: SpeakerTopology, seat: SpatialSeatingCalibration?) -> SpeakerTopology {
        guard let seat, seat.roomX != 0 || seat.roomY != 0 else { return topology }
        var result = topology
        for index in result.endpoints.indices {
            guard let original = result.endpoints[index].position else { continue }
            let point = vector(original)
            result.endpoints[index].position = position(x: point.x - seat.roomX, y: point.y - seat.roomY, height: point.z)
        }
        return result
    }

    static func setRole(_ role: ChannelRole?, for id: PhysicalOutputID, in topology: inout SpeakerTopology) {
        guard let index = topology.endpoints.firstIndex(where: { $0.id == id }) else { return }
        let previousRole = topology.endpoints[index].role
        setRole(role, on: &topology.endpoints[index])
        guard let role else { return }
        let peers = topology.endpoints.filter { $0.id != id }
        let names = Set(peers.map(\.displayName))
        let base = role.displayName
        let current = topology.endpoints[index].displayName
        let suffix = current.hasPrefix(base + " ") ? Int(current.dropFirst(base.count + 1)) : nil
        if previousRole == role, (current == base || (suffix ?? 0) >= 2), !names.contains(current) { return }
        var number = peers.filter { $0.role == role }.count + 1
        var name = number == 1 ? base : "\(base) \(number)"
        while names.contains(name) {
            number += 1; name = "\(base) \(number)"
        }
        topology.endpoints[index].displayName = name
    }

    static func setRole(_ role: ChannelRole?, on endpoint: inout SpeakerEndpoint) {
        guard let role else { endpoint.connectionState = .disabledByUser; return }
        endpoint.role = role
        endpoint.layer = role.speakerLayer
        endpoint.isSubwooferLike = role == .lowFrequencyEffects
        endpoint.connectionState = .confirmedByUser
    }
}
