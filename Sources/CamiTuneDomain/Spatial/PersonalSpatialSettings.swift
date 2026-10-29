import Foundation

package enum ListeningDistance: String, Codable, CaseIterable, Sendable {
    case near, mid, far
    package var meters: Float { switch self { case .near: return 1.2; case .mid: return 2.4; case .far: return 3.6 } }
    package var title: String { rawValue.capitalized }
}

package enum ProcessingCohort: String, Codable, CaseIterable, Hashable, Sendable {
    case direct, referencePlayback, spatialRender, spatialMovie
    package init(_ mode: PlaybackMode) {
        switch mode {
        case .direct: self = .direct
        case .referencePlayback: self = .referencePlayback
        case .spatialRender: self = .spatialRender
        }
    }
    package var mode: PlaybackMode {
        switch self {
        case .direct: return .direct
        case .referencePlayback: return .referencePlayback
        case .spatialRender, .spatialMovie: return .spatialRender
        }
    }
}

package enum VirtualSpeakerLayout: String, Codable, CaseIterable, Sendable {
    case source, stereo, stereoSub, surround50, surround51, surround70, surround71
    package var title: String {
        switch self {
        case .source: return "Automatic · follow audio channels"
        case .stereo: return "Stereo · 2 speakers"
        case .stereoSub: return "Stereo + subwoofer · 2.1"
        case .surround50: return "Surround · 5 speakers"
        case .surround51: return "Surround + subwoofer · 5.1"
        case .surround70: return "Full surround · 7 speakers"
        case .surround71: return "Full surround + subwoofer · 7.1"
        }
    }
    package var roles: [ChannelRole] {
        switch self {
        case .stereo, .stereoSub: return [.left, .right]
        case .surround50, .surround51: return [.left, .right, .center, .leftSurround, .rightSurround]
        case .source, .surround70, .surround71: return VirtualSpeakerScene.roles
        }
    }
    package var hasSubwoofer: Bool { self == .stereoSub || self == .surround51 || self == .surround71 }
    package var hasSurrounds: Bool { self == .surround50 || self == .surround51 || self == .surround70 || self == .surround71 }
    package var speakerRoles: [ChannelRole] { roles + (hasSubwoofer ? [.lowFrequencyEffects] : []) }
}

/// Missing secondary assignments inherit the main model. Explicit Neutral
/// remains distinguishable from "match the set" when a user customizes it.
package enum VirtualSpeakerAssignment: Codable, Hashable, Sendable {
    case neutral
    case model(VirtualSpeakerSound)
    package var sound: VirtualSpeakerSound? {
        if case .model(let sound) = self { return sound }
        return nil
    }
}

/// An assignment represents cabinets in the user's system, never the number
/// of drivers or the catalog's price unit ("each" / "pair").
package enum VirtualSpeakerGroup: String, Codable, CaseIterable, Sendable {
    case front, center, surround, rear
    package var title: String {
        switch self {
        case .front: return "Front pair"
        case .center: return "Center"
        case .surround: return "Surround pair"
        case .rear: return "Rear pair"
        }
    }
    package var roles: [ChannelRole] {
        switch self {
        case .front: return [.left, .right]
        case .center: return [.center]
        case .surround: return [.leftSurround, .rightSurround]
        case .rear: return [.leftRearSurround, .rightRearSurround]
        }
    }
    package static func containing(_ role: ChannelRole) -> Self? { allCases.first { $0.roles.contains(role) } }
}

package struct VirtualSpeakerSpecifications: Codable, Hashable, Sendable {
    package var cabinet: String?
    package var amplification: String?
    /// From the selected measurement, not another source's EQ or score.
    package var bassExtensionHz: Double?
    package var heightMM: Double?
    package var widthMM: Double?
    package var depthMM: Double?
    package init(cabinet: String? = nil, amplification: String? = nil, bassExtensionHz: Double? = nil,
                 heightMM: Double? = nil, widthMM: Double? = nil, depthMM: Double? = nil) {
        self.cabinet = cabinet; self.amplification = amplification; self.bassExtensionHz = bassExtensionHz
        self.heightMM = heightMM; self.widthMM = widthMM; self.depthMM = depthMM
    }
    package var summary: String {
        var parts = [cabinet, amplification].compactMap { $0?.replacingOccurrences(of: "bookshelves", with: "Bookshelf").capitalized }
        if let bassExtensionHz { parts.append(String(format: "Bass −3 dB: %.0f Hz", bassExtensionHz)) }
        if let heightMM, let widthMM, let depthMM {
            parts.append(String(format: "%.0f × %.0f × %.0f mm (H × W × D)", heightMM, widthMM, depthMM))
        }
        return parts.joined(separator: " · ")
    }
    package func validate() throws {
        guard bassExtensionHz.map({ $0.isFinite && (20...500).contains($0) }) ?? true,
              [heightMM, widthMM, depthMM].compactMap({ $0 }).allSatisfy({ $0.isFinite && (1...10_000).contains($0) }) else {
            throw PersonalSpatialError.invalidSpeakerSound
        }
    }
}

/// A specified generic subwoofer. No branded subwoofer measurement is implied.
package struct VirtualSubwoofer: Codable, Hashable, Sendable {
    package var extensionHz: Float = 20
    package init() {}
    package var bands: [EQBand] { [.init(kind: .highPass, frequency: Double(extensionHz), q: 0.70710678)] }
    package func validate() throws {
        guard extensionHz.isFinite, (15...60).contains(extensionHz) else { throw PersonalSpatialError.invalidRoom }
    }
}

package enum VirtualSpeakerRoom: String, Codable, CaseIterable, Sendable {
    case generic, sadieStudio
    package var title: String { self == .generic ? "Adjustable room" : "SADIE II · Genelec studio" }
}

/// Source-to-speaker sends are semantic, independent of the incoming channel order.
/// Stereo ambience uses the difference signal; it does not claim discrete surround.
package enum VirtualSpeakerRouting {
    package static func matrix(input: [ChannelRole], scene: VirtualSpeakerScene) -> [[Float]] {
        var result = Array(repeating: Array(repeating: Float(0), count: input.count), count: 7)
        func send(_ source: Int, _ role: ChannelRole, _ gain: Float = 1) {
            if let destination = VirtualSpeakerScene.roles.firstIndex(of: role) { result[destination][source] += gain }
        }
        for (i, role) in input.enumerated() where role != .lowFrequencyEffects {
            for (role, contribution) in floorContributions(role) {
                func route(_ destination: ChannelRole, _ gain: Float = 1) { send(i, destination, gain * contribution) }
            if scene.layout == .stereo || scene.layout == .stereoSub {
                switch role {
                case .left, .right: route(role)
                case .center: route(.left, 0.70710678); route(.right, 0.70710678)
                case .leftSurround, .leftRearSurround: route(.left, 0.70710678)
                case .rightSurround, .rightRearSurround: route(.right, 0.70710678)
                default: break
                }
            } else if scene.layout == .surround50 || scene.layout == .surround51 {
                switch role {
                case .leftSurround, .leftRearSurround:
                    route(.leftSurround, input.contains(.leftSurround) && input.contains(.leftRearSurround) ? 0.70710678 : 1)
                case .rightSurround, .rightRearSurround:
                    route(.rightSurround, input.contains(.rightSurround) && input.contains(.rightRearSurround) ? 0.70710678 : 1)
                default: route(role)
                }
            } else { route(role) }
            }
        }
        if scene.stereoAmbience, scene.layout.hasSurrounds, Set(input) == Set([.left, .right]),
           let l = input.firstIndex(of: .left), let r = input.firstIndex(of: .right) {
            let gain: Float = scene.layout.roles.count == 7 ? 0.3535534 : 0.5
            for role in scene.layout.roles where role == .leftSurround || role == .leftRearSurround {
                send(l, role, gain); send(r, role, -gain)
            }
            for role in scene.layout.roles where role == .rightSurround || role == .rightRearSurround {
                send(r, role, gain); send(l, role, -gain)
            }
        }
        return result
    }

    /// A floor-only cabinet set cannot reproduce measured height. Keep every
    /// supplied channel audible through explicit energy-preserving folds.
    private static func floorContributions(_ role: ChannelRole) -> [(ChannelRole, Float)] {
        switch role {
        case .topFrontLeft: return [(.left, 1)]
        case .topFrontRight: return [(.right, 1)]
        case .topMiddleLeft: return [(.leftSurround, 1)]
        case .topMiddleRight: return [(.rightSurround, 1)]
        case .topRearLeft: return [(.leftRearSurround, 1)]
        case .topRearRight: return [(.rightRearSurround, 1)]
        case .topCenter: return [(.center, 1)]
        case .frontLeftCenter: return [(.left, 0.70710678), (.center, 0.70710678)]
        case .frontRightCenter: return [(.right, 0.70710678), (.center, 0.70710678)]
        case .wideLeft: return [(.left, 0.70710678), (.leftSurround, 0.70710678)]
        case .wideRight: return [(.right, 0.70710678), (.rightSurround, 0.70710678)]
        case .unknown, .lowFrequencyEffects: return []
        default: return [(role, 1)]
        }
    }
}

package struct VirtualSpeakerSound: Codable, Hashable, Sendable {
    package var name: String
    package var measurementID: String
    /// Forward broad tonal response, never physical-speaker inverse correction.
    package var bands: [EQBand]
    package var sourceName: String?
    package var retrievedAt: Date?
    package var specifications: VirtualSpeakerSpecifications?
    package init(name: String, measurementID: String, bands: [EQBand], sourceName: String? = nil, retrievedAt: Date? = nil,
                 specifications: VirtualSpeakerSpecifications? = nil) {
        self.name = name; self.measurementID = measurementID; self.bands = bands
        self.sourceName = sourceName; self.retrievedAt = retrievedAt
        self.specifications = specifications
    }
}

extension VirtualSpeakerSound {
    /// Fit a broad forward response around a common 500–2000 Hz reference.
    /// The measured error is deliberately not negated as in correction EQ.
    package static func tonalBands(_ response: FrequencyResponse, bassExtensionHz: Double? = nil) throws -> [EQBand] {
        let frequencies: [Double] = [80, 160, 315, 630, 1250, 2500, 5000, 10000]
        let reference = [500.0, 1000, 2000].compactMap { response.magnitude(at: $0) }
        guard reference.count == 3 else { throw PersonalSpatialError.speakerResponseCoverage }
        let center = reference.reduce(0, +) / 3
        let gains = frequencies.compactMap { response.magnitude(at: $0).map { max(-6, min(6, $0 - center)) } }
        guard gains.count == frequencies.count else { throw PersonalSpatialError.speakerResponseCoverage }
        guard gains.allSatisfy(\.isFinite) else { throw PersonalSpatialError.invalidSpeakerSound }
        var bands = frequencies.map { EQBand(kind: .peaking, frequency: $0, gain: 0, q: 0.8) }
        if let bassExtensionHz {
            guard bassExtensionHz.isFinite, (20...500).contains(bassExtensionHz) else { throw PersonalSpatialError.invalidSpeakerSound }
            bands.append(.init(kind: .highPass, frequency: bassExtensionHz, q: 0.70710678))
        }
        let calculator = EQResponseCalculator()
        for _ in 0..<12 {
            for i in frequencies.indices {
                let actual = calculator.gainDB(at: frequencies[i], parsed: ParsedEQ(preampDB: 0, bands: bands), sampleRate: 48_000)
                bands[i].gain = max(-6, min(6, (bands[i].gain ?? 0) + 0.5 * (gains[i] - actual)))
            }
        }
        return bands
    }
}

/// Relative adjustments to the generic listener, not physical measurements.
package struct PersonalHRTFTuning: Codable, Hashable, Sendable {
    package var strength: Float = 1
    package var earSize: Float = 1
    package var headSize: Float = 1
    package init() {}

    package func validate() throws {
        guard strength.isFinite, (0...1.5).contains(strength),
              earSize.isFinite, (0.8...1.2).contains(earSize),
              headSize.isFinite, (0.8...1.2).contains(headSize) else {
            throw PersonalSpatialError.invalidHRTFTuning
        }
    }
}

package struct VirtualSpeakerScene: Codable, Hashable, Sendable {
    package var resetPreset: ListeningDistance = .near
    package var listener = SpatialVector3(x: 0, y: 0, z: 0)
    /// Semantic identity survives channel reordering and inactive sources.
    package var positions: [ChannelRole: SpatialVector3] = [:]
    package var speakers: [VirtualSpeakerGroup: VirtualSpeakerAssignment] = [:]
    package var subwoofer = VirtualSubwoofer()
    package var layout: VirtualSpeakerLayout = .source
    package var roomModel: VirtualSpeakerRoom = .generic
    package var stereoAmbience = false
    package var crossoverHz: Float = 80
    package var subwooferDB: Float = 0
    package var acoustics = PersonalSpatialRoom()
    package init() {}

    private enum CodingKeys: String, CodingKey {
        case resetPreset, listener, positions, speakerSound, layout, roomModel, stereoAmbience, crossoverHz, subwooferDB, decaySeconds
        case roomSize, earlyReflectionsDB, diffusion, speakers, subwoofer, acoustics
    }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resetPreset = try c.decode(ListeningDistance.self, forKey: .resetPreset)
        listener = try c.decode(SpatialVector3.self, forKey: .listener)
        positions = try c.decode([ChannelRole: SpatialVector3].self, forKey: .positions)
        if let assignments = try c.decodeIfPresent([VirtualSpeakerGroup: VirtualSpeakerAssignment].self, forKey: .speakers) {
            speakers = assignments
        } else if let legacy = try c.decodeIfPresent(VirtualSpeakerSound.self, forKey: .speakerSound) {
            speakers = [.front: .model(legacy)]
        }
        subwoofer = try c.decodeIfPresent(VirtualSubwoofer.self, forKey: .subwoofer) ?? .init()
        layout = try c.decodeIfPresent(VirtualSpeakerLayout.self, forKey: .layout) ?? .source
        roomModel = try c.decodeIfPresent(VirtualSpeakerRoom.self, forKey: .roomModel) ?? .generic
        stereoAmbience = try c.decodeIfPresent(Bool.self, forKey: .stereoAmbience) ?? false
        crossoverHz = try c.decodeIfPresent(Float.self, forKey: .crossoverHz) ?? 80
        subwooferDB = try c.decodeIfPresent(Float.self, forKey: .subwooferDB) ?? 0
        if let saved = try c.decodeIfPresent(PersonalSpatialRoom.self, forKey: .acoustics) {
            acoustics = saved
        } else {
            acoustics.size = try c.decodeIfPresent(Float.self, forKey: .roomSize) ?? 1
            acoustics.earlyReflectionsDB = try c.decodeIfPresent(Float.self, forKey: .earlyReflectionsDB) ?? 0
            acoustics.diffusion = try c.decodeIfPresent(Float.self, forKey: .diffusion) ?? 0.75
            acoustics.decaySeconds = try c.decodeIfPresent(Float.self, forKey: .decaySeconds) ?? 0.35
            // Freeze the old effective walls once. No runtime path continues
            // expanding the room when a source moves after migration.
            let points = layout.speakerRoles.map { positions[$0] ?? Self.canonical($0, distance: resetPreset.meters) } + [listener]
            let size = acoustics.size
            guard size.isFinite, (0.75...1.5).contains(size) else { throw PersonalSpatialError.invalidRoom }
            acoustics.minimum = .init(x: min(-3 * size, points.map(\.x).min()! - 0.25) / size,
                y: min(-3.5 * size, points.map(\.y).min()! - 0.25) / size, z: -1.2)
            acoustics.maximum = .init(x: max(3 * size, points.map(\.x).max()! + 0.25) / size,
                y: max(3.5 * size, points.map(\.y).max()! + 0.25) / size,
                z: (max(2.8 * size - 1.2, points.map(\.z).max()! + 0.25) + 1.2) / size - 1.2)
        }
        try validate()
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resetPreset, forKey: .resetPreset); try c.encode(listener, forKey: .listener)
        try c.encode(positions, forKey: .positions); try c.encode(speakers, forKey: .speakers)
        try c.encode(subwoofer, forKey: .subwoofer); try c.encode(layout, forKey: .layout)
        try c.encode(roomModel, forKey: .roomModel); try c.encode(stereoAmbience, forKey: .stereoAmbience)
        try c.encode(crossoverHz, forKey: .crossoverHz); try c.encode(subwooferDB, forKey: .subwooferDB)
        try c.encode(acoustics, forKey: .acoustics)
    }

    package static let roles: [ChannelRole] = [.left, .right, .center, .leftSurround,
        .rightSurround, .leftRearSurround, .rightRearSurround]
    package static let positionalRoles = roles + [.lowFrequencyEffects]
    package static let minimum = SpatialVector3(x: -4.25, y: -4.25, z: -0.95)
    package static let maximum = SpatialVector3(x: 4.25, y: 5.25, z: 3.95)

    /// Measured acoustics have fixed geometry. Keep the adjustable room's
    /// placement and tone saved so switching rooms does not erase those edits.
    package var effectiveListener: SpatialVector3 {
        roomModel == .generic ? listener : .init(x: 0, y: 0, z: 0)
    }
    package func speaker(for role: ChannelRole) -> VirtualSpeakerSound? {
        guard roomModel == .generic, let group = VirtualSpeakerGroup.containing(role) else { return nil }
        return (speakers[group] ?? speakers[.front])?.sound
    }
    package mutating func assign(_ sound: VirtualSpeakerSound?, to group: VirtualSpeakerGroup) {
        speakers[group] = sound.map(VirtualSpeakerAssignment.model) ?? .neutral
        // Choosing a front pair establishes two cabinets. Expanding the system
        // is an explicit layout choice and never inferred from source channels.
        if layout == .source {
            switch group {
            case .front: layout = .stereo
            case .center, .surround: layout = .surround50
            case .rear: layout = .surround70
            }
        }
        if group == .front, layout.hasSubwoofer, let suggested = recommendedCrossoverHz { crossoverHz = suggested }
    }
    package mutating func selectLayout(_ layout: VirtualSpeakerLayout) {
        self.layout = layout
        if roomModel == .generic, layout.hasSubwoofer, let suggested = recommendedCrossoverHz { crossoverHz = suggested }
    }
    package var recommendedCrossoverHz: Float? {
        let extensions = layout.roles.compactMap { speaker(for: $0)?.specifications?.bassExtensionHz }
        guard let highest = extensions.max() else { return nil }
        return Float(min(160, max(40, ceil(highest * 1.5 / 10) * 10)))
    }

    package func position(for role: ChannelRole) -> SpatialVector3 {
        if roomModel == .sadieStudio {
            if role == .lowFrequencyEffects { return .init(x: 2.025, y: 0.75, z: -0.9) }
            let azimuth: Float
            switch role {
            case .left: azimuth = -45; case .right: azimuth = 45
            case .leftSurround: azimuth = -90; case .rightSurround: azimuth = 90
            case .leftRearSurround: azimuth = -135; case .rightRearSurround: azimuth = 135
            default: azimuth = 0
            }
            return SpeakerLayoutGeometry.vector(.init(azimuthDegrees: azimuth, elevationDegrees: 0, distanceMeters: 1.5))
        }
        return positions[role] ?? Self.canonical(role, distance: resetPreset.meters)
    }
    package static func canonical(_ role: ChannelRole, distance: Float) -> SpatialVector3 {
        if role == .lowFrequencyEffects { return .init(x: min(4, distance * 1.35), y: distance * 0.5, z: -0.9) }
        let angle: Float
        switch role {
        case .left: angle = -30
        case .right: angle = 30
        case .center: angle = 0
        case .leftSurround: angle = -105
        case .rightSurround: angle = 105
        case .leftRearSurround: angle = -145
        case .rightRearSurround: angle = 145
        default: angle = 0
        }
        return SpeakerLayoutGeometry.vector(.init(azimuthDegrees: angle, elevationDegrees: 0, distanceMeters: distance))
    }
    package var isCustom: Bool {
        roomModel == .generic && (listener != SpatialVector3(x: 0, y: 0, z: 0) || layout.speakerRoles.contains {
            SpatialVector3.distance(position(for: $0), Self.canonical($0, distance: resetPreset.meters)) > 0.001
        })
    }
    package mutating func load(_ preset: ListeningDistance) {
        resetPreset = preset; positions = [:]; listener = .init(x: 0, y: 0, z: 0)
    }
    package static func contains(_ p: SpatialVector3) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite &&
        (minimum.x...maximum.x).contains(p.x) && (minimum.y...maximum.y).contains(p.y) &&
        (minimum.z...maximum.z).contains(p.z)
    }
    package func validate() throws {
        try subwoofer.validate()
        try acoustics.validate()
        guard crossoverHz.isFinite, (40...160).contains(crossoverHz), subwooferDB.isFinite, (-12...6).contains(subwooferDB) else {
            throw PersonalSpatialError.invalidRoom
        }
        guard Self.contains(listener), acoustics.contains(listener),
              positions.keys.allSatisfy(Self.positionalRoles.contains), positions.values.allSatisfy(Self.contains),
              layout.speakerRoles.allSatisfy({ role in
                  let position = positions[role] ?? Self.canonical(role, distance: resetPreset.meters)
                  return Self.contains(position) && acoustics.contains(position) && SpatialVector3.distance(position, listener) >= 1
              }) else {
            throw PersonalSpatialError.invalidGeometry
        }
        for sound in speakers.values.compactMap(\.sound) {
            try sound.specifications?.validate()
            guard sound.bands.count <= 16, ReferenceCorrection.validFilters(sound.bands, sampleRate: 44_100),
                  sound.bands.allSatisfy({ abs($0.gain ?? 0) <= 6 }) else { throw PersonalSpatialError.invalidSpeakerSound }
        }
    }
    @discardableResult package mutating func move(_ role: ChannelRole?, to point: SpatialVector3) -> Bool {
        guard roomModel == .generic else { return false }
        var candidate = self
        if let role { candidate.positions[role] = point } else { candidate.listener = point }
        guard (try? candidate.validate()) != nil else { return false }
        self = candidate; return true
    }
}

package enum PersonalSpatialError: Error, LocalizedError {
    case invalidMovieSettings
    case invalidDeviceType, incompatibleDeviceType
    case unsupportedSourceLayout, invalidSourcePlacement
    case invalidGeometry, invalidSpeakerSound, speakerResponseCoverage, invalidHeadphoneCorrection, invalidHRTFTuning, invalidRoom, measuredRoomUnavailable, unsupportedVersion
    package var errorDescription: String? {
        switch self {
        case .invalidMovieSettings: return "Keep Movie adjustments between 0 and 100%, and additional loud-moment control between 0 and 6 dB."
        case .unsupportedSourceLayout: return "This source includes channels without a known direction. Supply positions or confirm a channel mapping before using Spatial listening."
        case .invalidSourcePlacement: return "Check the saved source layout and placement. Each channel needs its own identity and a valid position."
        case .invalidDeviceType: return "Open or closed back applies to over-ear and on-ear headphones. Check the selected device type."
        case .incompatibleDeviceType: return "This measurement does not match the selected device type. Choose a compatible model, or explicitly use this device without correction."
        case .invalidGeometry: return "Keep virtual speakers inside the room and at least one metre from the listener."
        case .invalidSpeakerSound: return "The speaker response is invalid. Choose Neutral Monitor or another measurement."
        case .speakerResponseCoverage: return "This speaker measurement does not cover 80 Hz–10 kHz, the range needed for speaker tone. Choose another model or Neutral Monitor."
        case .invalidHeadphoneCorrection: return "The headphone correction is invalid. Choose the model again."
        case .invalidHRTFTuning: return "Use direction detail of 0–150% and ear/head size of 80–120%."
        case .invalidRoom: return "Check the room size, reflections, diffusion, reverberation time and bass settings."
        case .measuredRoomUnavailable: return "The SADIE II studio responses could not be loaded. Reinstall the app resources or choose Adjustable room."
        case .unsupportedVersion: return "This personal Spatial profile needs a newer version of CamiTune."
        }
    }
}

/// Only values that require a prepared bank. Room amount and Movie controls
/// remain inexpensive, smoothed render parameters.
package struct PersonalSpatialRenderIntent: Hashable, Sendable {
    package var scene: PersonalSpatialSceneIntent
    package var hrtf: PersonalHRTFTuning
    package var playbackDevice: SpatialPlaybackDevice?
    package init(scene: PersonalSpatialSceneIntent, hrtf: PersonalHRTFTuning = .init(), playbackDevice: SpatialPlaybackDevice? = nil) {
        self.scene = scene; self.hrtf = hrtf; self.playbackDevice = playbackDevice
    }
}

package struct PersonalSpatialSettings: Codable, Hashable, Sendable {
    package static let supportedSampleRates = [44100, 48000, 88200, 96000, 176400, 192000]
    package var playbackDevice: SpatialPlaybackDevice?
    package var experience: PersonalSpatialExperience = .spatialListening
    package var inputLayout: LPCMChannelLayout = .sevenPointOnePointFour
    package var hrtf = PersonalHRTFTuning()
    /// The cabinet scene is retained while Spatial listening is selected.
    package var scene = VirtualSpeakerScene()
    package var listening = SpatialListeningScene()
    package var mimicRoom: Float = 0.25
    package var listeningRoom: Float = 0.25
    package var room: Float {
        get { experience == .spatialListening ? listeningRoom : mimicRoom }
        set { if experience == .spatialListening { listeningRoom = newValue } else { mimicRoom = newValue } }
    }
    package var acoustics: PersonalSpatialRoom {
        get { experience == .spatialListening ? listening.acoustics : scene.acoustics }
        set { if experience == .spatialListening { listening.acoustics = newValue } else { scene.acoustics = newValue } }
    }
    package var movie = MovieSettings()
    package var renderIntent: PersonalSpatialRenderIntent {
        .init(scene: experience == .spatialListening ? .spatialListening(listening, inputLayout.signalSignature) : .speakerMimic(scene),
            hrtf: hrtf, playbackDevice: playbackDevice)
    }
    package func room(for experience: PersonalSpatialExperience) -> Float {
        experience == .spatialListening ? listeningRoom : mimicRoom
    }
    package func validate() throws {
        try scene.validate(); try listening.validate(); try hrtf.validate(); try playbackDevice?.validate(); try movie.validate()
        _ = try listening.sources(for: inputLayout)
        guard [mimicRoom, listeningRoom].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw PersonalSpatialError.invalidRoom
        }
    }
    package init() {}
    private enum CodingKeys: String, CodingKey {
        case version, playbackDevice, scene, room, movie, experience, inputLayout, hrtf, listening, mimicRoom, listeningRoom
    }
    private enum LegacySceneKeys: String, CodingKey { case hrtf }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard (1...5).contains(version) else { throw PersonalSpatialError.unsupportedVersion }
        playbackDevice = try c.decodeIfPresent(SpatialPlaybackDevice.self, forKey: .playbackDevice)
        scene = try c.decode(VirtualSpeakerScene.self, forKey: .scene)
        movie = try c.decode(MovieSettings.self, forKey: .movie)
        movie.dialogueClarity = SpatialRenderIntent.unit(movie.dialogueClarity)
        if version < 5 {
            movie.adaptation = 0
            experience = .speakerMimic
            inputLayout = .sevenPointOne
            mimicRoom = SpatialRenderIntent.unit(try c.decode(Float.self, forKey: .room))
            let legacy = try c.nestedContainer(keyedBy: LegacySceneKeys.self, forKey: .scene)
            hrtf = try legacy.decodeIfPresent(PersonalHRTFTuning.self, forKey: .hrtf) ?? .init()
        } else {
            experience = try c.decode(PersonalSpatialExperience.self, forKey: .experience)
            inputLayout = try c.decode(LPCMChannelLayout.self, forKey: .inputLayout)
            hrtf = try c.decode(PersonalHRTFTuning.self, forKey: .hrtf)
            listening = try c.decode(SpatialListeningScene.self, forKey: .listening)
            mimicRoom = try c.decode(Float.self, forKey: .mimicRoom)
            listeningRoom = try c.decode(Float.self, forKey: .listeningRoom)
        }
        try validate()
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(5, forKey: .version)
        try c.encodeIfPresent(playbackDevice, forKey: .playbackDevice)
        try c.encode(scene, forKey: .scene); try c.encode(movie, forKey: .movie)
        try c.encode(experience, forKey: .experience); try c.encode(inputLayout, forKey: .inputLayout)
        try c.encode(hrtf, forKey: .hrtf); try c.encode(listening, forKey: .listening)
        try c.encode(mimicRoom, forKey: .mimicRoom); try c.encode(listeningRoom, forKey: .listeningRoom)
    }
    package static func migrated(_ legacy: VirtualSurroundLayout) -> Self {
        var result = Self()
        result.experience = .speakerMimic
        result.inputLayout = .sevenPointOne
        // Legacy radius 0.8 represented no measured distance. Infer Near (1.2 m),
        // reverse its negative-front y convention, and reject invalid geometry.
        for (role, p) in legacy.positions where VirtualSpeakerScene.roles.contains(role) {
            result.scene.positions[role] = .init(x: p.x * 1.5, y: -p.y * 1.5, z: 0)
        }
        if (try? result.scene.validate()) == nil { result.scene = .init() }
        return result
    }
}
