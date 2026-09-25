import Foundation

package struct ProfileDocumentRevision: RawRepresentable, Comparable, Hashable, Codable, Sendable {
    package let rawValue: UInt64
    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    package init(rawValue: UInt64) { self.rawValue = rawValue }
    package init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UInt64.self) }
    package func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}
