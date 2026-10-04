import CamiTuneAudio
import CamiTuneDomain
import SwiftUI

@MainActor
struct MultichannelProcessingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    var previewOnly = false
    @State private var draft = MultichannelProcessingSettings()
    @State private var topologyDraft: SpeakerTopology?
    @State private var editorRevision = UUID()
    @State private var loadedID: UUID?
    @State private var message: String?
    @State private var routingExpanded = false
    @State private var crossoverExpanded = false

    private var saving: Bool { state.isSavingProfileSettings }
    private var editorSnapshot: MultichannelHistoryState { .init(settings: draft, topology: topologyDraft) }

    private var candidate: DeviceProfile {
        var value = profile; value.speakerTopology = topologyDraft; value.multichannel = draft; return value
    }
    private var changed: Bool { draft != profile.multichannel || topologyDraft != profile.speakerTopology }
    private var endpoints: [SpeakerEndpoint] { candidate.configuredSpeakerEndpoints }
    private var drivers: [SpeakerEndpoint] { endpoints.filter { [.woofer, .midrange, .tweeter].contains($0.function) } }
    private var routingEndpoints: [SpeakerEndpoint] {
        endpoints.filter { !draft.effectiveBass.enabled || !draft.bass.subwooferEndpointIDs.contains($0.id) }
    }
    private var routingEnabled: Binding<Bool> {
        Binding(get: { draft.routing.enabled }, set: { enabled in
            if enabled {
                draft.routing = MultichannelRoutingEditor.enablingRouting(in: candidate)
                routingExpanded = true
            } else { draft.routing.enabled = false }
        })
    }
    private var source: LPCMChannelLayout {
        return ProfileRoutingDescriptor.sourceLayout(for: candidate)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text("Routing & Crossovers").font(.title3.bold())
                processingDisclosure("Custom Routing", expanded: $routingExpanded, enabled: routingEnabled) {
                    routingControls
                }
                processingDisclosure("Active Crossovers & Protection", expanded: $crossoverExpanded) {
                    crossoverControls
                }
                Divider()
                HStack {
                    Button("Export runtime plan…") {
                        Task { do { try await state.exportRuntimePlan(profile: profile, previewOnly: previewOnly) } catch { message = error.localizedDescription } }
                    }.disabled(changed)
                }
                if saving { ProgressView("Saving processing…").controlSize(.small) }
                if let message = state.multichannelAutosaveErrors[profile.id] ?? message { Text(message).font(.callout).foregroundStyle(.orange) }
                if draft.isEnabled {
                    Text("Valid changes are saved and applied automatically. These controls use Direct playback.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6).disabled(saving).id(editorRevision)
        }
        .onAppear {
            if loadedID != profile.id { load() }
            if changed { scheduleAutosave() }
        }
        .onChange(of: editorSnapshot) { _ in
            if loadedID == profile.id, changed, !state.history.isReplaying,
               state.multichannelEditSessions[profile.id] != editorSnapshot { scheduleAutosave() }
        }
        .onReceive(state.profiles.$multichannelDrafts) { sessions in
            guard loadedID == profile.id, let session = sessions[profile.id], session != editorSnapshot else { return }
            draft = session.settings; topologyDraft = session.topology
        }
        .onChange(of: profile.multichannel) { _ in reloadAfterAutosave() }
        .onChange(of: profile.speakerTopology) { _ in reloadAfterAutosave() }
        .onChange(of: profile.id) { _ in load() }
        .onDisappear {
            if changed, loadedID == profile.id { scheduleAutosave() }
        }
        .onChange(of: state.historyReplayRevision) { _ in
            if let current = state.profiles.profiles.first(where: { $0.id == profile.id }) { profile = current }
            load()
            if changed { scheduleAutosave() }
        }
    }

    private func processingDisclosure<Content: View>(_ title: String, expanded: Binding<Bool>,
                                                     enabled: Binding<Bool>? = nil,
                                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).frame(width: 10)
                            .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: expanded.wrappedValue)
                        Text(title)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
                Spacer()
                if let enabled {
                    Toggle(title, isOn: enabled).toggleStyle(.switch).labelsHidden()
                }
            }
            if expanded.wrappedValue {
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var routingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft.routing.enabled {
                HStack {
                    Picker("Input layout", selection: $draft.routing.sourceLayout) {
                        ForEach(RoutingSourceLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 300)
                    if draft.routing.sourceLayout == .discrete {
                        Stepper("\(draft.routing.discreteChannelCount) channels", value: $draft.routing.discreteChannelCount, in: 1...32)
                    }
                }
                if draft.routing.routes.isEmpty {
                    Text("No routes yet. Add a connection or start from speaker assignments.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($draft.routing.routes) { $route in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Picker("Source channel", selection: $route.sourceChannel) {
                                ForEach(0..<source.channelCount, id: \.self) { index in Text(sourceName(index)).tag(index) }
                            }.frame(maxWidth: 270)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Picker("Destination speaker", selection: $route.destination) {
                                if !routingEndpoints.contains(where: { $0.id == route.destination }) {
                                    Text("Unavailable output \(route.destination.channelIndex + 1)").tag(route.destination)
                                }
                                ForEach(routingEndpoints) { Text($0.displayName).tag($0.id) }
                            }.frame(maxWidth: 310)
                            Button { draft.routing.routes.removeAll { $0.id == route.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove route")
                        }
                        HStack {
                            Text("Gain"); numeric("Route gain dB", value: $route.gainDB); Text("dB")
                            Toggle("Mute route", isOn: $route.muted)
                            Toggle("Invert route", isOn: $route.inverted)
                        }
                    }
                }
                HStack {
                    Button("Add route") {
                        guard let route = MultichannelRoutingEditor.nextRoute(in: candidate) else { return }
                        draft.routing.routes.append(route)
                    }.disabled(MultichannelRoutingEditor.nextRoute(in: candidate) == nil)
                    Button("Reset to speaker assignments") {
                        let candidate = self.candidate
                        if let format = try? AudioFormatDescriptor.source(sampleRate: profile.sampleRate, layout: source) {
                            draft.routing.routes = candidate.defaultSpeakerRoutes(source: format)
                                .filter { !draft.bass.enabled || !draft.bass.subwooferEndpointIDs.contains($0.destination) }
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var crossoverControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu("Prepare active stereo setup") {
                ForEach(ActiveSpeakerPreset.allCases) { preset in
                    Button(preset.title) {
                        do { let prepared = try preset.applying(to: candidate); topologyDraft = prepared.speakerTopology; draft = prepared.multichannel; message = "Starting crossover values are 300 Hz and/or 2,000 Hz. Adjust them for the connected drivers, then confirm the hardware map. Valid changes save automatically." }
                        catch { message = error.localizedDescription }
                    }.disabled((topologyDraft?.endpoints.count ?? 0) < preset.rawValue * 2)
                }
            }.fixedSize()
            Toggle("Enable active crossovers", isOn: $draft.crossover.enabled)
                .toggleStyle(.switch)
            Text("For speakers whose individual drivers connect to separate amplifier outputs.")
                .font(.caption).foregroundStyle(.secondary)
            if draft.crossover.enabled {
                Text("Choose crossover frequencies and protection limits for each driver, then confirm the hardware map. Valid changes save automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(drivers) { driver in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(driver.displayName) · \(driver.function.displayName)").font(.headline)
                        if let index = draft.crossover.endpoints.firstIndex(where: { $0.endpointID == driver.id }) {
                            crossoverRow(index, driver: driver)
                        } else {
                            Button("Configure \(driver.displayName)") {
                                draft.crossover.endpoints.append(.init(endpointID: driver.id))
                                draft.crossover.protection[driver.id] = .init()
                            }
                        }
                    }
                }
                Button("Confirm this hardware map") {
                    do {
                        guard let topology = topologyDraft else { throw SpeakerTopologyError.invalidDeviceUID }
                        draft.crossover.reviewedHardware = try .init(topology: topology)
                        message = "Hardware map confirmed. Changes save automatically once every driver's protection is valid."
                    } catch { message = error.localizedDescription }
                }
                Text(draft.crossover.reviewedHardware == nil ? "Hardware map needs confirmation." : "Hardware map confirmed; hardware changes block activation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func crossoverRow(_ index: Int, driver: SpeakerEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("High-pass", isOn: optionalEnabled($draft.crossover.endpoints[index].highPassHz, defaultValue: 2000))
                if draft.crossover.endpoints[index].highPassHz != nil { numeric("Driver high-pass Hz", value: optionalValue($draft.crossover.endpoints[index].highPassHz, fallback: 2000)); Text("Hz") }
                Toggle("Low-pass", isOn: optionalEnabled($draft.crossover.endpoints[index].lowPassHz, defaultValue: 2000))
                if draft.crossover.endpoints[index].lowPassHz != nil { numeric("Driver low-pass Hz", value: optionalValue($draft.crossover.endpoints[index].lowPassHz, fallback: 2000)); Text("Hz") }
            }
            Picker("Crossover slope", selection: $draft.crossover.endpoints[index].slope) {
                ForEach(CrossoverSlope.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(maxWidth: 350)
            HStack {
                Toggle("Require high-pass", isOn: optionalEnabled(protectionBinding(driver.id, \.requiredHighPassHz), defaultValue: 2000))
                if draft.crossover.protection[driver.id]?.requiredHighPassHz != nil {
                    numeric("Minimum protection Hz", value: optionalValue(protectionBinding(driver.id, \.requiredHighPassHz), fallback: 2000)); Text("Hz")
                }
                Toggle("Require limiter", isOn: protectionBinding(driver.id, \.limiterRequired))
            }
            if draft.crossover.protection[driver.id]?.requiredHighPassHz != nil {
                Picker("Minimum protection slope", selection: protectionBinding(driver.id, \.requiredHighPassSlope)) {
                    ForEach(CrossoverSlope.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 420)
            }
            HStack {
                Toggle("Limit gain", isOn: optionalEnabled(protectionBinding(driver.id, \.maximumGainDB), defaultValue: 0))
                if draft.crossover.protection[driver.id]?.maximumGainDB != nil {
                    numeric("Maximum gain dB", value: optionalValue(protectionBinding(driver.id, \.maximumGainDB), fallback: 0)); Text("dB")
                }
            }
            Text("Required limiters run last at −3 dBFS. Tweeters and midrange drivers require high-pass and limiter protection. Positive global preamp is blocked by the default 0 dB gain limit.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func numeric(_ title: String, value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder).frame(width: 78).accessibilityLabel(title)
    }
    private func protectionBinding<T>(_ id: PhysicalOutputID, _ key: WritableKeyPath<EndpointProtection, T>) -> Binding<T> {
        Binding(get: { (draft.crossover.protection[id] ?? .init())[keyPath: key] }, set: {
            var protection = draft.crossover.protection[id] ?? .init(); protection[keyPath: key] = $0; draft.crossover.protection[id] = protection
        })
    }
    private func optionalEnabled(_ value: Binding<Double?>, defaultValue: Double) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? defaultValue : nil })
    }
    private func optionalValue(_ value: Binding<Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = $0 })
    }
    private func sourceName(_ index: Int) -> String {
        let role = source.roles[index]
        return role == .unknown ? "Source \(index + 1)" : role.displayName
    }
    private func load(useDraft: Bool = true) {
        if !useDraft { state.multichannelEditSessions[profile.id] = nil }
        let savedDraft = useDraft ? state.multichannelEditSessions[profile.id] : nil
        draft = savedDraft?.settings ?? profile.multichannel
        topologyDraft = savedDraft?.topology ?? profile.speakerTopology
        loadedID = profile.id; message = nil
        // SwiftUI retains a numeric field's editing text across external binding
        // resets. Recreate the controls on Revert/Undo so stale text cannot claim
        // to be the saved crossover frequency or protection value.
        editorRevision = UUID()
    }
    private func scheduleAutosave() {
        state.scheduleMultichannelAutosave(editorSnapshot, for: profile.id, previewOnly: previewOnly)
    }

    private func reloadAfterAutosave() {
        if state.multichannelEditSessions[profile.id] == nil { load(useDraft: false) }
    }

}

/// Edits the configuration draft; the containing setup owns saving or cancelling.
@MainActor
struct BassManagementControlsView: View {
    let profile: DeviceProfile
    let selectedSubwoofer: PhysicalOutputID
    @Binding var bass: BassManagementSettings
    @Binding var testGainDB: Double
    private var muted: Bool { profile.multichannel.subwooferControl.mode == .mute }

    private var subs: [SpeakerEndpoint] {
        profile.configuredSpeakerEndpoints.filter { $0.function == .subwoofer }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bass management").font(.headline)
                Spacer()
                Toggle("Enable bass management", isOn: bassEnabled)
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(muted)
            }
            HStack(spacing: 12) {
                Text("Test volume").font(.callout)
                SteppedValueSlider(value: $testGainDB, in: SpatialCalibrationClip.subwooferTestGainRangeDB, step: 1)
                    .accessibilityLabel("Subwoofer test volume")
                Text(String(format: "%+.0f dB", testGainDB))
                    .font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing)
                Button("Reset") { testGainDB = 0 }
                    .controlSize(.small).disabled(testGainDB == 0)
                    .accessibilityLabel("Reset subwoofer test volume")
            }
            .help("Adjusts this subwoofer’s next test sound. 0 dB uses the standard test level.")
            if bass.enabled {
                Divider()
                bassControls.disabled(muted)
            }
        }
    }

    private var availableBassGroups: [SpeakerGroup] {
        let used = Set(profile.configuredSpeakerGroups.filter { group in
            bass.groups.contains { $0.groupID == group.id }
        }.flatMap(\.members))
        let subIDs = Set(subs.map(\.id))
        return profile.configuredSpeakerGroups.filter {
            !$0.members.isEmpty && Set($0.members).isDisjoint(with: used.union(subIDs))
        }
    }
    private var bassEnabled: Binding<Bool> {
        Binding(get: { bass.enabled && !muted }, set: { enabled in
            if enabled && bass.groups.isEmpty && bass.subwooferEndpointIDs.isEmpty {
                bass = profile.defaultBassManagement
            }
            bass.enabled = enabled
        })
    }
    private var bassControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(subs.filter { $0.id == selectedSubwoofer }) { sub in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(sub.displayName)
                        Spacer()
                        Toggle("Use \(sub.displayName)", isOn: Binding(get: { bass.subwooferEndpointIDs.contains(sub.id) }, set: { enabled in
                            bass.subwooferEndpointIDs.removeAll { $0 == sub.id }
                            if enabled { bass.subwooferEndpointIDs.append(sub.id) }
                        })).toggleStyle(.switch).labelsHidden()
                            .disabled(bass.subwooferEndpointIDs == [sub.id])
                            .help("Keep at least one subwoofer selected while bass management is on.")
                    }
                    if bass.subwooferEndpointIDs.contains(sub.id) {
                        HStack(spacing: 12) {
                            Text("Trim")
                            numeric("\(sub.displayName) trim dB", value: subBinding(sub.id, \.gainDB))
                            Text("dB").foregroundStyle(.secondary)
                            Text("Delay")
                            numeric("\(sub.displayName) delay ms", value: subBinding(sub.id, \.delayMilliseconds))
                            Text("ms").foregroundStyle(.secondary)
                            Toggle("Invert polarity", isOn: subBinding(sub.id, \.inverted))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text("Redirect bass from speakers").font(.headline)
            ForEach($bass.groups) { $group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(profile.configuredSpeakerGroups.first { $0.id == group.groupID }?.name ?? "Unavailable group")
                        Spacer()
                        Button { bass.groups.removeAll { $0.id == group.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Stop redirecting bass from this group")
                    }
                    HStack(spacing: 12) {
                        Text("Crossover")
                        numeric("Crossover Hz", value: $group.crossoverHz)
                        Text("Hz").foregroundStyle(.secondary)
                        Picker("Slope", selection: $group.slope) {
                            ForEach(CrossoverSlope.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.frame(maxWidth: 300)
                    }
                }
            }
            Menu("Add speaker group") {
                ForEach(availableBassGroups) { group in
                    Button(group.name) { bass.groups.append(.init(groupID: group.id)) }
                }
            }.fixedSize().disabled(availableBassGroups.isEmpty)
            if bass.groups.isEmpty {
                Text("No speaker bass is redirected. Subwoofers receive only the source's LFE channel, when present.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 12) {
                Text("LFE trim")
                numeric("LFE trim dB", value: $bass.lfeGainDB)
                Text("dB").foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numeric(_ title: String, value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder).frame(width: 78).accessibilityLabel(title)
    }
    private func subBinding<T>(_ id: PhysicalOutputID, _ key: WritableKeyPath<SubwooferSettings, T>) -> Binding<T> {
        Binding(get: { (bass.subwooferSettings[id] ?? .init())[keyPath: key] }, set: {
            var sub = bass.subwooferSettings[id] ?? .init(); sub[keyPath: key] = $0; bass.subwooferSettings[id] = sub
        })
    }
}

@MainActor
struct SubwooferControlView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ProfileStore
    let profile: DeviceProfile

    private var settings: MultichannelProcessingSettings {
        store.multichannelDrafts[profile.id]?.settings ?? profile.multichannel
    }
    private var hasSubwoofer: Bool { profile.configuredSpeakerEndpoints.contains { $0.function == .subwoofer } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Subwoofer Control").font(.title3.bold())
                JoinedSegmentedControl(options: SubwooferControlMode.allCases,
                    selection: controlBinding(\.mode), title: { $0.title })
                    .accessibilityLabel("Subwoofer mode")
                    .frame(width: 260)
                    .disabled(!hasSubwoofer || state.isSavingProfileSettings)
                if settings.subwooferControl.mode == .reduce {
                    Text("Bass management settings remain unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if settings.subwooferControl.mode == .mute {
                    Text("Bass management is off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.subwooferControl.mode == .reduce {
                    HStack(spacing: 12) {
                        Text("Reduction").font(.callout)
                        SteppedValueSlider(value: controlBinding(\.reductionDB),
                            in: SubwooferControlSettings.reductionRangeDB, step: 0.5)
                            .accessibilityLabel("Subwoofer level reduction")
                        Text(String(format: "−%.1f dB", settings.subwooferControl.reductionDB))
                            .font(.callout.monospacedDigit()).frame(width: 78, alignment: .trailing)
                    }.disabled(!hasSubwoofer || state.isSavingProfileSettings)
                }
                if !hasSubwoofer {
                    Text("Assign a Subwoofer in Device Configuration to use these controls.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = state.multichannelAutosaveErrors[profile.id] {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func controlBinding<Value>(_ key: WritableKeyPath<SubwooferControlSettings, Value>) -> Binding<Value> {
        Binding(get: { settings.subwooferControl[keyPath: key] }, set: { value in
            var snapshot = store.multichannelDrafts[profile.id]
                ?? MultichannelHistoryState(settings: profile.multichannel, topology: profile.speakerTopology)
            snapshot.settings.subwooferControl[keyPath: key] = value
            state.scheduleMultichannelAutosave(snapshot, for: profile.id)
        })
    }
}

/// Keeps routing edits grounded in the current speaker assignments.
enum MultichannelRoutingEditor {
    static func enablingRouting(in profile: DeviceProfile) -> AdvancedRoutingSettings {
        var routing = profile.multichannel.routing
        if routing.routes.isEmpty {
            let source = ProfileRoutingDescriptor.sourceLayout(for: profile)
            routing.sourceLayout = RoutingSourceLayout.allCases.first {
                $0.layout(channelCount: source.channelCount) == source
            } ?? .discrete
            routing.discreteChannelCount = source.channelCount
            if let format = try? AudioFormatDescriptor.source(sampleRate: profile.sampleRate, layout: source) {
                routing.routes = profile.defaultSpeakerRoutes(source: format).filter {
                    !profile.multichannel.bass.enabled || !profile.multichannel.bass.subwooferEndpointIDs.contains($0.destination)
                }
            }
        }
        routing.enabled = true
        return routing
    }

    static func nextRoute(in profile: DeviceProfile) -> SpeakerRoute? {
        let routing = profile.multichannel.routing
        let count = routing.sourceLayout.layout(channelCount: routing.discreteChannelCount).channelCount
        let destinations = profile.configuredSpeakerEndpoints.filter {
            !profile.multichannel.bass.enabled || !profile.multichannel.bass.subwooferEndpointIDs.contains($0.id)
        }
        for source in 0..<count {
            for output in destinations where !routing.routes.contains(where: {
                $0.sourceChannel == source && $0.destination == output.id
            }) {
                return .init(sourceChannel: source, destination: output.id)
            }
        }
        return nil
    }
}
