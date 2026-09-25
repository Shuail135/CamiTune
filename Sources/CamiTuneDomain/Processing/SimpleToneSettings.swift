import Foundation

package enum SimpleEQRange: String, CaseIterable, Identifiable, Sendable {
    case bass
    case mids
    case treble

    package var id: Self { self }

}

/// Independent tone controls; older profiles decode to neutral.
package struct SimpleToneSettings: Codable, Hashable, Sendable {
    package init(bassDB: Double = 0, midsDB: Double = 0, trebleDB: Double = 0) {
        self.bassDB = bassDB; self.midsDB = midsDB; self.trebleDB = trebleDB
    }

    package static let gainRange = -12.0...12.0
    package static let step = 0.5
    package var bassDB: Double = 0
    package var midsDB: Double = 0
    package var trebleDB: Double = 0
    package var isNeutral: Bool { bassDB == 0 && midsDB == 0 && trebleDB == 0 }

    package subscript(_ range: SimpleEQRange) -> Double {
        get { switch range { case .bass: return bassDB; case .mids: return midsDB; case .treble: return trebleDB } }
        set {
            let value = newValue.isFinite ? min(12, max(-12, (newValue / Self.step).rounded() * Self.step)) : 0
            switch range { case .bass: bassDB = value; case .mids: midsDB = value; case .treble: trebleDB = value }
        }
    }

    package func validate() throws {
        guard [bassDB, midsDB, trebleDB].allSatisfy({ $0.isFinite && Self.gainRange.contains($0) }) else {
            throw ProfileSettingsError.runtime("Tone gains must be between −12 and +12 dB.")
        }
    }
}

package enum SimpleToneFilterFactory {
    package static let stageID = UUID(uuidString: "43414D49-5455-4E45-544F-4E4500000000")!
    /// Fixed broad shelves and a broad midrange bell, shared by both audio paths.
    package static func filters(for settings: SimpleToneSettings, sampleRate: Double) throws -> [EQBand] {
        try settings.validate()
        guard sampleRate.isFinite, sampleRate > 0 else { throw ProcessingGraphError.invalidSampleRate }
        let kinds: [EQBand.Kind] = [.lowShelf, .peaking, .highShelf]
        let frequencies = [200.0, 1000.0, 4000.0]
        return SimpleEQRange.allCases.enumerated().map { index, range in
            EQBand(id: UUID(uuidString: "43414D49-5455-4E45-544F-4E450000000\(index + 1)")!,
                kind: kinds[index], frequency: min(frequencies[index], sampleRate * 0.4),
                gain: settings[range], q: index == 1 ? 0.5 : 0.7071067811865476)
        }
    }
}
