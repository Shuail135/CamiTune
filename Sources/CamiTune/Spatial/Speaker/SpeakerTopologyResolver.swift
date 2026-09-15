import AudioToolbox
import Foundation

struct SpeakerChannelDescription: Sendable {
    var role: ChannelRole = .unknown
    var position: SpatialPosition?
    var name: String?

    init(role: ChannelRole = .unknown, position: SpatialPosition? = nil, name: String? = nil) {
        self.role = role; self.position = position; self.name = name
    }

    init(_ description: AudioChannelDescription) {
        role = Self.role(for: description.mChannelLabel)
        guard description.mChannelLabel == kAudioChannelLabel_UseCoordinates else { return }
        let (a, b, c) = description.mCoordinates
        guard a.isFinite, b.isFinite, c.isFinite else { return }
        let flags = description.mChannelFlags
        let meters = flags.contains(.meters)
        if flags.contains(.sphericalCoordinates), !flags.contains(.rectangularCoordinates) {
            let azimuth = ((a + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180
            position = SpatialPosition(azimuthDegrees: azimuth, elevationDegrees: b,
                                       distanceMeters: meters ? c : nil)
        } else if flags.contains(.rectangularCoordinates), !flags.contains(.sphericalCoordinates) {
            let distance = sqrt(a * a + b * b + c * c)
            guard distance.isFinite, distance > 0 else { return }
            var azimuth = atan2(a, b) * 180 / .pi
            if azimuth >= 180 { azimuth -= 360 }
            position = SpatialPosition(azimuthDegrees: azimuth,
                elevationDegrees: asin(max(-1, min(1, c / distance))) * 180 / .pi,
                distanceMeters: meters ? distance : nil)
        }
        if let position, (try? position.validate()) == nil { self.position = nil }
    }

    static func role(for label: AudioChannelLabel) -> ChannelRole {
        switch label {
        case kAudioChannelLabel_Left: return .left
        case kAudioChannelLabel_Right: return .right
        case kAudioChannelLabel_Center, kAudioChannelLabel_Mono: return .center
        case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: return .lowFrequencyEffects
        case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_LeftSideSurround: return .leftSurround
        case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RightSideSurround: return .rightSurround
        case kAudioChannelLabel_RearSurroundLeft: return .leftRearSurround
        case kAudioChannelLabel_RearSurroundRight: return .rightRearSurround
        case kAudioChannelLabel_LeftCenter: return .frontLeftCenter
        case kAudioChannelLabel_RightCenter: return .frontRightCenter
        case kAudioChannelLabel_LeftWide: return .wideLeft
        case kAudioChannelLabel_RightWide: return .wideRight
        case kAudioChannelLabel_LeftTopFront: return .topFrontLeft
        case kAudioChannelLabel_RightTopFront: return .topFrontRight
        case kAudioChannelLabel_LeftTopMiddle: return .topMiddleLeft
        case kAudioChannelLabel_RightTopMiddle: return .topMiddleRight
        case kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_TopBackLeft: return .topRearLeft
        case kAudioChannelLabel_RightTopRear, kAudioChannelLabel_TopBackRight: return .topRearRight
        case kAudioChannelLabel_TopCenterSurround: return .topCenter
        default: return .unknown
        }
    }
}

struct SpeakerTopologyResolver {
    func resolve(deviceUID: String, sampleRate: Double, channelCount: Int,
                 channels: [SpeakerChannelDescription]) throws -> SpeakerTopology {
        guard (1...32).contains(channelCount) else {
            throw SpeakerTopologyError.unsupportedChannelCount(channelCount)
        }
        let endpoints = (0..<channelCount).map { index -> SpeakerEndpoint in
            let channel = index < channels.count ? channels[index] : SpeakerChannelDescription()
            return SpeakerEndpoint(id: PhysicalOutputID(deviceUID: deviceUID, channelIndex: index),
                role: channel.role, position: channel.position ?? StandardSpeakerPositions.position(for: channel.role),
                positionSource: channel.position != nil ? .coreAudioMetadata :
                    (StandardSpeakerPositions.position(for: channel.role) == nil ? .unknown : .standardLayoutDefault),
                layer: channel.role.speakerLayer,
                displayName: channel.name ?? (channel.role == .unknown ? "Channel \(index + 1)" : channel.role.displayName),
                function: channel.role == .lowFrequencyEffects ? .subwoofer : .fullRange,
                roleOrigin: channel.role == .unknown ? .user : .hardware)
        }
        var topology = SpeakerTopology(deviceUID: deviceUID, sampleRate: sampleRate,
                                       declaredChannelCount: channelCount, endpoints: endpoints)
        topology.hardwareRoles = endpoints.map(\.role)
        topology.hardwarePositions = (0..<channelCount).map { $0 < channels.count ? channels[$0].position : nil }
        topology.groups = SpeakerGroup.standardGroups(for: endpoints)
        try topology.validate()
        return topology
    }
}
