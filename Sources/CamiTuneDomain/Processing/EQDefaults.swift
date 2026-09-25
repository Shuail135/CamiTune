import Foundation

package enum EQDefaults {
    package static let bands = [
        EQBand(kind: .lowShelf, frequency: 31, gain: 0, q: 1),
        EQBand(kind: .peaking, frequency: 76, gain: 0, q: 1),
        EQBand(kind: .peaking, frequency: 184, gain: 0, q: 1),
        EQBand(kind: .peaking, frequency: 447, gain: 0, q: 1),
        EQBand(kind: .peaking, frequency: 1_087, gain: 0, q: 1),
        EQBand(kind: .peaking, frequency: 2_643, gain: 0, q: 1),
        EQBand(kind: .peaking, frequency: 6_423, gain: 0, q: 1),
        EQBand(kind: .highShelf, frequency: 16_000, gain: 0, q: 1)
    ]
}
