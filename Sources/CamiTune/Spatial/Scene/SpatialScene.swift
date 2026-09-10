import Foundation

struct SpatialObjectID: Codable, Hashable, Sendable { var rawValue: UInt32 }
enum SpatialObjectRole: Codable, Hashable, Sendable {
    case generic, bed(ChannelRole), lowFrequency
}
struct SpatialObject: Hashable, Sendable {
    var id: SpatialObjectID
    var audioPlaneIndex: Int
    var position: SpatialPosition?
    var gainLinear: Float = 1
    var spread: Float = 0
    var role: SpatialObjectRole
    var active: Bool = true
}

/// Describes source spatial intent. It must not contain room/speaker correction.
/// One interleaved buffer is shared by all objects; no per-object PCM copies.
struct SpatialSceneFrame: Sendable {
    var sampleTime: Int64
    var audio: PCMFrame
    var objects: [SpatialObject]

    func validate() throws {
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
    enum SceneError: Error { case invalidScene }
}

struct ChannelBasedSceneProvider {
    func makeScene(from frame: PCMFrame, sampleTime: Int64 = 0) throws -> SpatialSceneFrame {
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
