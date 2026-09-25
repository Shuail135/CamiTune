import CamiTuneDomain
import Foundation

package struct SpatialObjectID: Codable, Hashable, Sendable {
    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package var rawValue: UInt32
}
package enum SpatialObjectRole: Codable, Hashable, Sendable {
    case generic, bed(ChannelRole), lowFrequency
}
package struct SpatialObject: Hashable, Sendable {
    package init(id: SpatialObjectID, audioPlaneIndex: Int, position: SpatialPosition? = nil, gainLinear: Float = 1, spread: Float = 0, role: SpatialObjectRole, active: Bool = true) {
        self.id = id
        self.audioPlaneIndex = audioPlaneIndex
        self.position = position
        self.gainLinear = gainLinear
        self.spread = spread
        self.role = role
        self.active = active
    }

    package var id: SpatialObjectID
    package var audioPlaneIndex: Int
    package var position: SpatialPosition?
    package var gainLinear: Float = 1
    package var spread: Float = 0
    package var role: SpatialObjectRole
    package var active: Bool = true
}

/// Describes source spatial intent. It must not contain room/speaker correction.
/// One interleaved buffer is shared by all objects; no per-object PCM copies.
package struct SpatialSceneFrame: Sendable {
    package init(sampleTime: Int64, audio: PCMFrame, objects: [SpatialObject]) {
        self.sampleTime = sampleTime
        self.audio = audio
        self.objects = objects
    }

    package var sampleTime: Int64
    package var audio: PCMFrame
    package var objects: [SpatialObject]

    package func validate() throws {
        guard (1...128).contains(audio.channelCount), audio.sampleRate.isFinite,
              (8000...384000).contains(audio.sampleRate),
              audio.interleaved.count.isMultiple(of: audio.channelCount), objects.count <= 128,
              Set(objects.map(\.id)).count == objects.count else { throw SceneError.invalidScene }
        for object in objects {
            guard (0..<audio.channelCount).contains(object.audioPlaneIndex),
                  object.gainLinear.isFinite, (0...4).contains(object.gainLinear),
                  object.spread.isFinite, (0...1).contains(object.spread) else { throw SceneError.invalidScene }
            try object.position?.validate()
        }
    }
    package enum SceneError: Error { case invalidScene }
}

package struct ChannelBasedSceneProvider {
    package init() {}

    package func makeScene(from frame: PCMFrame, sampleTime: Int64 = 0) throws -> SpatialSceneFrame {
        guard (1...32).contains(frame.channelCount), frame.channelLayout.channelCount == frame.channelCount,
              frame.channelLayout.positions == nil || frame.channelLayout.positions?.count == frame.channelCount else {
            throw SpatialSceneFrame.SceneError.invalidScene
        }
        let objects = frame.channelLayout.roles.enumerated().map { index, role in
            SpatialObject(id: SpatialObjectID(rawValue: UInt32(index)), audioPlaneIndex: index,
                position: frame.channelLayout.positions?[index] ?? StandardSpeakerPositions.position(for: role),
                role: role == .lowFrequencyEffects ? .lowFrequency : .bed(role))
        }
        let scene = SpatialSceneFrame(sampleTime: sampleTime, audio: frame, objects: objects)
        try scene.validate()
        return scene
    }
}
