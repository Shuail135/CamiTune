import Foundation

package enum SpatialContentMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case automatic, movieVideo, musicSafe, fixed
    package var id: String { rawValue }
    package var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .movieVideo: return "Movie / Video"
        case .musicSafe: return "Music-safe"
        case .fixed: return "Fixed (no analysis)"
        }
    }
}
