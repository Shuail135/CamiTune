import CamiTuneDomain

extension SimpleEQRange {
    var title: String {
        switch self {
        case .bass: return "Bass"
        case .mids: return "Mids"
        case .treble: return "Treble"
        }
    }
}
