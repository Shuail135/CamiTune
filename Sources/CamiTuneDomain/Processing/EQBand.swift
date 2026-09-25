import Foundation

package struct EQBand: Identifiable, Codable, Hashable, Sendable {
    package enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case peaking
        case lowShelf
        case highShelf
        case lowPass
        case highPass
        case notch
        case allPass
    }

    package let id: UUID
    package var enabled: Bool
    package var kind: Kind
    package var frequency: Double
    package var gain: Double?
    package var q: Double?
    package var bandwidth: Double?

    package init(
        id: UUID = UUID(),
        enabled: Bool = true,
        kind: Kind,
        frequency: Double,
        gain: Double? = nil,
        q: Double? = nil,
        bandwidth: Double? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.kind = kind
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.bandwidth = bandwidth
    }
}
