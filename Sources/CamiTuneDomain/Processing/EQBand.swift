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

        package var usesGain: Bool {
            self == .peaking || self == .lowShelf || self == .highShelf
        }
    }

    package let id: UUID
    private var locked: Bool? = nil
    package var isLocked: Bool {
        get { locked ?? false }
        set { locked = newValue ? true : nil }
    }
    package var enabled: Bool
    package var kind: Kind
    package var frequency: Double
    package var gain: Double?
    package var q: Double?
    package var bandwidth: Double?

    package var hasMeaningfulProcessing: Bool {
        enabled && (!kind.usesGain || abs(gain ?? 0) > 0.000_001)
    }

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
