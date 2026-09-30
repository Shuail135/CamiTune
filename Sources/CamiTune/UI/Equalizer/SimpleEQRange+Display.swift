import CamiTuneDomain

extension SimpleEQRange {
    var title: String {
        switch self {
        case .bass: return "Bass"
        case .mids: return "Mids"
        case .treble: return "Treble"
        }
    }

    var frequencyDescription: String {
        switch self {
        case .bass: return "Broad low shelf"
        case .mids: return "Broad midrange"
        case .treble: return "Broad high shelf"
        }
    }
}
