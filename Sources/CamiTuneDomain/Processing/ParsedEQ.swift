import Foundation

package struct ParsedEQ: Sendable {
    package init(preampDB: Double = 0, bands: [EQBand] = [], warnings: [String] = [], importedDirectiveCount: Int = 0) {
        self.preampDB = preampDB; self.bands = bands; self.warnings = warnings
        self.importedDirectiveCount = importedDirectiveCount
    }

    package var preampDB: Double = 0
    package var bands: [EQBand] = []
    package var warnings: [String] = []
    /// Number of Preamp/filter directives actually represented in this graph.
    /// Metadata and recognized-but-unsupported APO commands do not increment it.
    package var importedDirectiveCount: Int = 0

    package var hasMeaningfulProcessing: Bool {
        if abs(preampDB) > 0.000_001 { return true }
        return bands.contains { band in
            guard band.enabled else { return false }
            switch band.kind {
            case .peaking, .lowShelf, .highShelf:
                return abs(band.gain ?? 0) > 0.000_001
            case .lowPass, .highPass, .notch, .allPass:
                return true
            }
        }
    }
}
