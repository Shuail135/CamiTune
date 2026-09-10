import CoreAudio
import Foundation

/// The channel order attached to an LPCM block as it crosses the private
/// driver boundary. Keeping semantic roles beside the samples prevents later
/// spatial processing from having to guess what channel 2 or channel 7 means.
struct LPCMChannelLayout: Hashable, Sendable {
    var coreAudioTag: UInt32
    var roles: [ChannelRole]
    var positions: [SpatialPosition?]? = nil

    var channelCount: Int { roles.count }

    static let stereo = LPCMChannelLayout(
        coreAudioTag: UInt32(kAudioChannelLayoutTag_Stereo),
        roles: [.left, .right]
    )

    /// ITU/MPEG order: L, R, C, LFE, Ls, Rs.
    static let fivePointOne = LPCMChannelLayout(
        coreAudioTag: UInt32(kAudioChannelLayoutTag_MPEG_5_1_A),
        roles: [
            .left, .right, .center, .lowFrequencyEffects,
            .leftSurround, .rightSurround
        ]
    )

    /// ITU/MPEG order: L, R, C, LFE, Ls, Rs, Rls, Rrs.
    static let sevenPointOne = LPCMChannelLayout(
        coreAudioTag: UInt32(kAudioChannelLayoutTag_MPEG_7_1_C),
        roles: [
            .left, .right, .center, .lowFrequencyEffects,
            .leftSurround, .rightSurround,
            .leftRearSurround, .rightRearSurround
        ]
    )

    static let fivePointOnePointTwo = LPCMChannelLayout(coreAudioTag: UInt32(kAudioChannelLayoutTag_Atmos_5_1_2), roles: fivePointOne.roles + [.topMiddleLeft, .topMiddleRight])
    static let fivePointOnePointFour = LPCMChannelLayout(coreAudioTag: UInt32(kAudioChannelLayoutTag_Atmos_5_1_4), roles: fivePointOne.roles + [.topFrontLeft, .topFrontRight, .topRearLeft, .topRearRight])
    static let sevenPointOnePointTwo = LPCMChannelLayout(coreAudioTag: UInt32(kAudioChannelLayoutTag_Atmos_7_1_2), roles: sevenPointOne.roles + [.topMiddleLeft, .topMiddleRight])
    static let sevenPointOnePointFour = LPCMChannelLayout(coreAudioTag: UInt32(kAudioChannelLayoutTag_Atmos_7_1_4), roles: sevenPointOne.roles + [.topFrontLeft, .topFrontRight, .topRearLeft, .topRearRight])

    static let ninePointOnePointSix = LPCMChannelLayout(coreAudioTag: UInt32(kAudioChannelLayoutTag_Atmos_9_1_6), roles: sevenPointOne.roles + [.wideLeft, .wideRight, .topFrontLeft, .topFrontRight, .topMiddleLeft, .topMiddleRight, .topRearLeft, .topRearRight])

    init(coreAudioTag: UInt32, roles: [ChannelRole], positions: [SpatialPosition?]? = nil) {
        self.coreAudioTag = coreAudioTag
        self.roles = roles
        self.positions = positions
    }

    init?(channelDescriptions: [AudioChannelDescription]) {
        guard (1...32).contains(channelDescriptions.count) else { return nil }
        let channels = channelDescriptions.map { SpeakerChannelDescription($0) }
        self.init(coreAudioTag: UInt32(kAudioChannelLayoutTag_UseChannelDescriptions),
            roles: channels.map(\.role), positions: channels.map(\.position))
    }

    /// Resolves the layouts CamiTune accepts at the LPCM boundary. A zero tag
    /// keeps the historical CamiTune 2/6/8-channel producer convention. Other
    /// untagged counts and explicitly discrete tags retain unknown roles.
    init?(coreAudioTag: UInt32, channelCount: Int) {
        guard (1...32).contains(channelCount) else { return nil }
        let roles: [ChannelRole]?
        switch coreAudioTag {
        case UInt32(kAudioChannelLayoutTag_Atmos_9_1_6): roles = Self.ninePointOnePointSix.roles
        case UInt32(kAudioChannelLayoutTag_Atmos_5_1_2): roles = Self.fivePointOnePointTwo.roles
        case UInt32(kAudioChannelLayoutTag_Atmos_5_1_4): roles = Self.fivePointOnePointFour.roles
        case UInt32(kAudioChannelLayoutTag_Atmos_7_1_2): roles = Self.sevenPointOnePointTwo.roles
        case UInt32(kAudioChannelLayoutTag_Atmos_7_1_4): roles = Self.sevenPointOnePointFour.roles
        case UInt32(kAudioChannelLayoutTag_Mono): roles = [.center]
        case UInt32(kAudioChannelLayoutTag_Stereo):
            roles = Self.stereo.roles
        case UInt32(kAudioChannelLayoutTag_MPEG_5_1_A):
            roles = Self.fivePointOne.roles
        case UInt32(kAudioChannelLayoutTag_MPEG_5_1_B):
            roles = [
                .left, .right, .leftSurround, .rightSurround,
                .center, .lowFrequencyEffects
            ]
        case UInt32(kAudioChannelLayoutTag_MPEG_5_1_C):
            roles = [
                .left, .center, .right, .leftSurround,
                .rightSurround, .lowFrequencyEffects
            ]
        case UInt32(kAudioChannelLayoutTag_MPEG_5_1_D):
            roles = [
                .center, .left, .right, .leftSurround,
                .rightSurround, .lowFrequencyEffects
            ]
        case UInt32(kAudioChannelLayoutTag_MPEG_7_1_A):
            // MPEG 7.1 A carries the front left/right-center pair.
            roles = [
                .left, .right, .center, .lowFrequencyEffects,
                .leftSurround, .rightSurround, .frontLeftCenter, .frontRightCenter
            ]
        case UInt32(kAudioChannelLayoutTag_MPEG_7_1_B):
            roles = [
                .center, .frontLeftCenter, .frontRightCenter, .left, .right,
                .leftSurround, .rightSurround, .lowFrequencyEffects
            ]
        case UInt32(kAudioChannelLayoutTag_MPEG_7_1_C):
            roles = Self.sevenPointOne.roles
        case UInt32(kAudioChannelLayoutTag_Emagic_Default_7_1):
            roles = [
                .left, .right, .leftSurround, .rightSurround,
                .center, .lowFrequencyEffects, .frontLeftCenter, .frontRightCenter
            ]
        default:
            switch channelCount {
            case 2 where coreAudioTag == 0:
                roles = Self.stereo.roles
            case 6 where coreAudioTag == 0:
                roles = Self.fivePointOne.roles
            case 8 where coreAudioTag == 0:
                roles = Self.sevenPointOne.roles
            case 1...32 where coreAudioTag == 0:
                roles = Array(repeating: .unknown, count: channelCount)
            case 1...32 where (coreAudioTag & 0xFFFF0000) == UInt32(kAudioChannelLayoutTag_DiscreteInOrder)
                && Int(coreAudioTag & 0xFFFF) == channelCount:
                roles = Array(repeating: .unknown, count: channelCount)
            default:
                roles = nil
            }
        }
        guard let roles, roles.count == channelCount else { return nil }
        self.init(coreAudioTag: coreAudioTag, roles: roles)
    }

    static func canonical(forChannelCount channelCount: Int) -> LPCMChannelLayout? {
        switch channelCount {
        case 2: return .stereo
        case 6: return .fivePointOne
        case 8: return .sevenPointOne
        default: return nil
        }
    }
}

enum SpatialSourceFormat: Hashable, Sendable {
    case stereo
    case fivePointOne(LPCMChannelLayout)
    case sevenPointOne(LPCMChannelLayout)
    case multichannel(LPCMChannelLayout)

    init(layout: LPCMChannelLayout) {
        switch layout.roles {
        case LPCMChannelLayout.stereo.roles: self = .stereo
        case let roles where roles.count == 6 && Set(roles) == Set(LPCMChannelLayout.fivePointOne.roles): self = .fivePointOne(layout)
        case let roles where roles.count == 8 && Set(roles) == Set(LPCMChannelLayout.sevenPointOne.roles): self = .sevenPointOne(layout)
        default: self = .multichannel(layout)
        }
    }

    var channelLayout: LPCMChannelLayout {
        switch self {
        case .stereo: return .stereo
        case .fivePointOne(let layout),
             .sevenPointOne(let layout),
             .multichannel(let layout):
            return layout
        }
    }

    var displayName: String {
        switch self {
        case .stereo: return "2.0"
        case .fivePointOne: return "5.1"
        case .sevenPointOne: return "7.1"
        case .multichannel(let layout):
            if layout.roles == LPCMChannelLayout.ninePointOnePointSix.roles { return "9.1.6" }
            if layout.roles == LPCMChannelLayout.fivePointOnePointTwo.roles { return "5.1.2" }
            if layout.roles == LPCMChannelLayout.fivePointOnePointFour.roles { return "5.1.4" }
            if layout.roles == LPCMChannelLayout.sevenPointOnePointTwo.roles { return "7.1.2" }
            if layout.roles == LPCMChannelLayout.sevenPointOnePointFour.roles { return "7.1.4" }
            return "\(layout.channelCount)-channel"
        }
    }
}
