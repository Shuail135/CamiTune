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
        let horizontal = max(0.05, sqrt(x * x + y * y))
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

    static func setRole(_ role: ChannelRole?, on endpoint: inout SpeakerEndpoint) {
        guard let role else { endpoint.connectionState = .disabledByUser; return }
        endpoint.role = role
        endpoint.layer = role.speakerLayer
        endpoint.isSubwooferLike = role == .lowFrequencyEffects
        endpoint.connectionState = .confirmedByUser
    }
}
