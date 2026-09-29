import Foundation

package enum ProfileSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case deviceSetup, meters, spectrum, mode, equalizer, perChannel, deviceCorrection, crossfeed, multichannel
    // Retain the old identifiers so saved layouts can migrate without losing settings.
    case convolution
    package static let allCases: [ProfileSection] = [
        .deviceSetup, .meters, .spectrum, .mode, .deviceCorrection, .equalizer, .perChannel, .multichannel
    ]
    package static let defaultLayoutSections = allCases
    package var consolidated: Self {
        switch self {
        case .convolution, .crossfeed: return .deviceCorrection
        default: return self
        }
    }
    package var id: Self { self }
    package var title: String {
        switch self {
        case .deviceSetup: return "Device Setup"
        case .meters: return "Meters & Status"
        case .spectrum: return "Spectrum"
        case .mode: return "Mode"
        case .deviceCorrection: return "Device Correction"
        case .equalizer: return "Equalizer"
        case .convolution: return "FIR / Convolution"
        case .crossfeed: return "Crossfeed"
        case .perChannel: return "Channel Processing"
        case .multichannel: return "Bass & Routing"
        }
    }
    package func applies(to type: ProfileEndpointKind) -> Bool {
        if self == .multichannel { return type == .speakers }
        return self != .crossfeed || type == .headphones || type == .iem
    }
}

package enum EqualizerPresentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case simpleTone, bands, both
    package var id: Self { self }
    package var title: String { self == .bands ? "Bands" : self == .simpleTone ? "Simple" : "Both" }
}

package struct SectionPresentationPreference: Codable, Hashable, Sendable {
    package init(equalizer: EqualizerPresentation = .both) {
        self.equalizer = equalizer
    }

    package var equalizer: EqualizerPresentation = .both
}

package struct ProfileSectionLayout: Codable, Hashable, Sendable {
    package var order: [ProfileSection] = ProfileSection.allCases
    package var hidden: Set<ProfileSection> = []
    package var presentation: [String: SectionPresentationPreference] = [:]

    private enum CodingKeys: String, CodingKey { case order, hidden, presentation }
    package init(order: [ProfileSection] = ProfileSection.allCases, hidden: Set<ProfileSection> = [],
         presentation: [String: SectionPresentationPreference] = [:]) {
        var seen: Set<ProfileSection> = [.deviceSetup]
        self.order = [.deviceSetup] + (order + ProfileSection.defaultLayoutSections)
            .map(\.consolidated).filter { seen.insert($0).inserted }
        self.hidden = hidden.subtracting([.convolution, .crossfeed])
        if order.contains(.convolution) || order.contains(.crossfeed)
            || hidden.contains(.convolution) || hidden.contains(.crossfeed) {
            if hidden.contains(.convolution) && hidden.contains(.crossfeed) {
                self.hidden.insert(.deviceCorrection)
            } else {
                self.hidden.remove(.deviceCorrection)
            }
        }
        self.presentation = presentation
    }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            order: try values.decodeIfPresent([ProfileSection].self, forKey: .order) ?? ProfileSection.allCases,
            hidden: try values.decodeIfPresent(Set<ProfileSection>.self, forKey: .hidden) ?? [],
            presentation: try values.decodeIfPresent([String: SectionPresentationPreference].self, forKey: .presentation) ?? [:]
        )
    }
    package func encode(to encoder: Encoder) throws {
        let normalized = Self(order: order, hidden: hidden, presentation: presentation)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(normalized.normalizedOrder, forKey: .order)
        try values.encode(normalized.hidden, forKey: .hidden)
        try values.encode(normalized.presentation, forKey: .presentation)
    }

    package func visualDemand(for type: ProfileEndpointKind) -> (meters: Bool, spectrum: Bool) {
        let sections = visibleSections(for: type)
        return (sections.contains(.meters) || sections.contains(.equalizer) || sections.contains(.perChannel),
                sections.contains(.spectrum) || (sections.contains(.equalizer) && equalizer != .simpleTone))
    }

    package var equalizer: EqualizerPresentation {
        get { presentation[ProfileSection.equalizer.rawValue]?.equalizer ?? .both }
        set { presentation[ProfileSection.equalizer.rawValue] = SectionPresentationPreference(equalizer: newValue) }
    }
    package var normalizedOrder: [ProfileSection] {
        var seen: Set<ProfileSection> = [.deviceSetup]
        return [.deviceSetup] + (order + ProfileSection.allCases).map(\.consolidated).filter { seen.insert($0).inserted }
    }
    package func visibleSections(for type: ProfileEndpointKind) -> [ProfileSection] {
        normalizedOrder.filter { $0.applies(to: type) && ($0 == .deviceSetup || !hidden.contains($0)) }
    }
    package mutating func move(_ section: ProfileSection, before destination: ProfileSection?) {
        let section = section.consolidated
        let destination = destination?.consolidated
        guard section != .deviceSetup, destination != .deviceSetup, section != destination else { return }
        var ordered = normalizedOrder.filter { $0 != section }
        ordered.insert(section, at: destination.flatMap { ordered.firstIndex(of: $0) } ?? ordered.count)
        order = ordered
    }
}
