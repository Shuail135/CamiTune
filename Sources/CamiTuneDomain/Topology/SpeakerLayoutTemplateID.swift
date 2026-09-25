import Foundation

package struct SpeakerLayoutTemplateID: RawRepresentable, Codable, Hashable, Sendable {
    package init(rawValue: String) { self.rawValue = rawValue }

    package let rawValue: String
    package static let custom = Self(rawValue: "custom")
}
