import Foundation

package enum ProfileSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case deviceSetup, meters, spectrum, mode, equalizer, perChannel, deviceCorrection, crossfeed, multichannel, subwooferControl
    // Retain the old identifiers so saved layouts can migrate without losing settings.
    case convolution, plugins
    package static let allCases: [ProfileSection] = [
        .deviceSetup, .meters, .spectrum, .mode, .deviceCorrection, .equalizer, .plugins, .subwooferControl, .perChannel, .multichannel
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
        case .plugins: return "Plug-ins"
        case .convolution: return "FIR / Convolution"
        case .crossfeed: return "Crossfeed"
        case .perChannel: return "Channel Processing"
        case .multichannel: return "Routing & Crossovers"
        case .subwooferControl: return "Subwoofer Control"
        }
    }
    package func applies(to type: ProfileEndpointKind) -> Bool {
        if self == .subwooferControl { return type == .speakers || type == .audioInterface }
        if self == .multichannel { return type == .speakers }
        return self != .crossfeed || type == .headphones || type == .iem
    }
}

package enum SectionVisibility: String, Codable, CaseIterable, Identifiable {
    case automatic, shown, hidden
    package var id: Self { self }
    package var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .shown: return "Show"
        case .hidden: return "Hide"
        }
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
    package var explicitlyShown: Set<ProfileSection> = []
    package var presentation: [String: SectionPresentationPreference] = [:]

    private enum CodingKeys: String, CodingKey { case order, hidden, explicitlyShown, presentation }
    package init(order: [ProfileSection] = ProfileSection.allCases, hidden: Set<ProfileSection> = [],
         presentation: [String: SectionPresentationPreference] = [:], explicitlyShown: Set<ProfileSection> = []) {
        self.explicitlyShown = explicitlyShown
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
            presentation: try values.decodeIfPresent([String: SectionPresentationPreference].self, forKey: .presentation) ?? [:],
            explicitlyShown: try values.decodeIfPresent(Set<ProfileSection>.self, forKey: .explicitlyShown) ?? []
        )
    }
    package func encode(to encoder: Encoder) throws {
        let normalized = Self(order: order, hidden: hidden, presentation: presentation, explicitlyShown: explicitlyShown)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(normalized.normalizedOrder, forKey: .order)
        try values.encode(normalized.hidden, forKey: .hidden)
        try values.encode(normalized.explicitlyShown, forKey: .explicitlyShown)
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
    package var subwooferVisibility: SectionVisibility {
        get { hidden.contains(.subwooferControl) ? .hidden : explicitlyShown.contains(.subwooferControl) ? .shown : .automatic }
        set {
            hidden.remove(.subwooferControl); explicitlyShown.remove(.subwooferControl)
            if newValue == .hidden { hidden.insert(.subwooferControl) }
            if newValue == .shown { explicitlyShown.insert(.subwooferControl) }
        }
    }
    package func visibleSections(for profile: DeviceProfile) -> [ProfileSection] {
        visibleSections(for: profile.effectiveEndpointKind).filter {
            $0 != .subwooferControl || subwooferVisibility == .shown || profile.hasSpeakersAndSubwoofer
        }
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

extension DeviceProfile {
    package var effectiveSectionLayout: ProfileSectionLayout {
        sectionLayout ?? inheritedSectionLayouts[endpointKind.rawValue] ?? defaultSectionLayout
    }

    package func isSectionEnabled(_ section: ProfileSection) -> Bool {
        effectiveSectionLayout.visibleSections(for: self).contains(section.consolidated)
    }

    package var effectivePlaybackMode: PlaybackMode { isSectionEnabled(.mode) ? playbackMode : .direct }
    package var effectivePluginRack: PluginRack { isSectionEnabled(.plugins) ? pluginRack : PluginRack() }
    package var effectiveMultichannel: MultichannelProcessingSettings {
        var settings = multichannel
        if !isSectionEnabled(.multichannel) {
            settings.bass.enabled = false
            settings.routing.enabled = false
            settings.crossover.enabled = false
        }
        if !isSectionEnabled(.subwooferControl) { settings.subwooferControl = .init() }
        return settings
    }

    private static func isCorrectionStage(_ stage: ProcessingStage) -> Bool {
        if ProcessingProfile.isRoomStage(stage.id) { return true }
        switch stage.processor {
        case .deviceCorrection, .convolution, .crossfeed: return true
        default: return false
        }
    }

    /// A disposable execution copy. Never persist it: the original retains all
    /// settings, including bypassed stages and the user's selected playback mode.
    package func processingRuntimeProfile() throws -> DeviceProfile {
        var result = self
        var processing = try resolvedProcessing()
        let correction = isSectionEnabled(.deviceCorrection)
        let equalizer = isSectionEnabled(.equalizer)
        let channels = isSectionEnabled(.perChannel)
        processing.global.stages.removeAll { Self.isCorrectionStage($0) ? !correction : !equalizer }
        if !equalizer { processing.simpleTone = .init() }
        for index in processing.channels.indices {
            processing.channels[index].chain.stages.removeAll { Self.isCorrectionStage($0) ? !correction : !channels }
            if !channels { processing.channels[index].chain.simpleTone = nil }
        }
        for index in processing.groups.indices {
            processing.groups[index].chain.stages.removeAll { Self.isCorrectionStage($0) ? !correction : !channels }
            if !channels { processing.groups[index].chain.simpleTone = nil }
        }
        result.physicalChannelProcessing = [:]
        result.replaceProcessing(processing)
        if !correction {
            for index in result.spatialSettings.listeningPositions.indices {
                result.spatialSettings.listeningPositions[index].roomCorrectionEnabled = false
            }
        }
        result.setPlaybackMode(effectivePlaybackMode)
        if !isSectionEnabled(.mode) { result.personalReferenceCorrections = [:] }
        result.pluginRack = effectivePluginRack
        result.multichannel = effectiveMultichannel
        return result
    }

    /// Used before hiding a section, including enabled settings on an inactive
    /// profile that would otherwise run the next time it is activated.
    package func hasEnabledProcessing(in section: ProfileSection) -> Bool {
        guard isSectionEnabled(section) else { return false }
        let processing = (try? resolvedProcessing()) ?? self.processing
        let chains = [processing.global] + processing.channels.map(\.chain) + processing.groups.map(\.chain)
        switch section.consolidated {
        case .mode: return playbackMode != .direct
        case .plugins: return pluginRack.isProcessing
        case .equalizer:
            return !processing.simpleTone.isNeutral || processing.global.stages.contains { $0.isEnabled && !Self.isCorrectionStage($0) }
        case .deviceCorrection:
            return chains.contains { $0.stages.contains { $0.isEnabled && Self.isCorrectionStage($0) } }
        case .perChannel:
            return (processing.channels.map(\.chain) + processing.groups.map(\.chain)).contains {
                $0.simpleTone?.isNeutral == false || $0.stages.contains { $0.isEnabled && !Self.isCorrectionStage($0) }
            }
        case .multichannel: return multichannel.isEnabled
        case .subwooferControl: return multichannel.subwooferControl.mode != .standard
        default: return false
        }
    }
}
