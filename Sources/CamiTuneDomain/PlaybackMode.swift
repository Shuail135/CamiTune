import Foundation

package enum PlaybackMode: String, Codable, CaseIterable, Hashable, Sendable {
    case direct
    case referencePlayback
    case spatialRender

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "normal" { self = .direct; return }
        guard let mode = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Unsupported playback mode: \(value)")
        }
        self = mode
    }
}
