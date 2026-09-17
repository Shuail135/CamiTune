import SwiftUI

@MainActor
struct MultichannelProcessingView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    var previewOnly = false
    @State private var draft = MultichannelProcessingSettings()
    @State private var topologyDraft: SpeakerTopology?
    @State private var editorRevision = UUID()
    @State private var loadedID: UUID?
    @State private var message: String?
    @State private var saving = false
    @State private var showingVerification = false
    @State private var routingExpanded = false
    @State private var crossoverExpanded = false

    private var candidate: DeviceProfile {
        var value = profile; value.speakerTopology = topologyDraft; value.multichannel = draft; return value
    }
    private var changed: Bool { draft != profile.multichannel || topologyDraft != profile.speakerTopology }
    private var endpoints: [SpeakerEndpoint] { candidate.configuredSpeakerEndpoints }
    private var subs: [SpeakerEndpoint] { endpoints.filter { $0.function == .subwoofer } }
    private var drivers: [SpeakerEndpoint] { endpoints.filter { [.woofer, .midrange, .tweeter].contains($0.function) } }
    private var source: LPCMChannelLayout {
        return ProfileRoutingDescriptor.sourceLayout(for: candidate)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Bass & Subwoofers").font(.title3.bold())
                    Text(!changed ? "Saved" : "Not saved").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert") { load(useDraft: false) }.disabled(!changed)
                    Button("Save") { save() }.disabled(saving || !changed)
                }
                Toggle("Enable bass management", isOn: Binding(get: { draft.bass.enabled }, set: { enabled in
                    if enabled && draft.bass.groups.isEmpty && draft.bass.subwooferEndpointIDs.isEmpty { draft.bass = candidate.defaultBassManagement }
                    draft.bass.enabled = enabled
                }))
                if draft.bass.enabled {
                    bassControls
                } else {
                    Text("Redirect low frequencies to one or more subwoofers. Each speaker keeps its own EQ and calibration.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                DisclosureGroup("Advanced Routing", isExpanded: $routingExpanded) { routingControls.padding(.top, 8) }
                DisclosureGroup("Active Crossovers & Protection", isExpanded: $crossoverExpanded) { crossoverControls.padding(.top, 8) }
                Divider()
                HStack {
                    Button("Verify Speakers") { showingVerification = true }.disabled(changed)
                    Button("Export runtime plan…") {
                        Task { do { try await state.exportRuntimePlan(profile: profile, previewOnly: previewOnly) } catch { message = error.localizedDescription } }
                    }.disabled(changed)
                }
                if let record = profile.speakerVerification, let topology = profile.speakerTopology, record.matches(topology) {
                    Text(record.simulated ? "Speaker verification completed in simulation." : "Speaker verification completed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if saving { ProgressView("Saving processing…").controlSize(.small) }
                if let message { Text(message).font(.callout).foregroundStyle(.orange) }
                if draft.isEnabled {
                    Text("Uses Direct playback. Changes take effect when saved. Global processing runs before routing; group and speaker processing follow it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6).disabled(saving).id(editorRevision)
        }
        .sheet(isPresented: $showingVerification) { SpeakerVerificationView(state: state, profile: $profile, previewOnly: previewOnly) }
        .onChange(of: showingVerification) { showing in
            // Verification can commit corrected physical assignments. It opens
            // only from a clean editor, so reload the committed topology on exit.
            if !showing { load(useDraft: false) }
        }
        .onAppear { if loadedID != profile.id { load() } }
        .onChange(of: profile.id) { _ in load() }
        .onDisappear {
            if let loadedID, changed { state.multichannelEditSessions[loadedID] = .init(settings: draft, topology: topologyDraft) }
        }
        .onChange(of: state.historyReplayRevision) { _ in
            if let current = state.profiles.profiles.first(where: { $0.id == profile.id }) { profile = current }
            load(useDraft: false)
        }
    }

    private var bassControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($draft.bass.groups) { $group in
                HStack {
                    Text(candidate.configuredSpeakerGroups.first { $0.id == group.groupID }?.name ?? "Unavailable group")
                        .frame(width: 110, alignment: .leading)
                    numeric("Crossover Hz", value: $group.crossoverHz)
                    Text("Hz").foregroundStyle(.secondary)
                    Picker("Slope", selection: $group.slope) {
                        ForEach(CrossoverSlope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(maxWidth: 240)
                    Button("Remove") { draft.bass.groups.removeAll { $0.id == group.id } }
                }
            }
            Menu("Add speaker group") {
                ForEach(candidate.configuredSpeakerGroups.filter { group in
                    group.kind != .subwoofers && !draft.bass.groups.contains { $0.groupID == group.id }
                }) { group in
                    Button(group.name) { draft.bass.groups.append(.init(groupID: group.id)) }
                }
            }.fixedSize()
            HStack { Text("LFE trim").frame(width: 110, alignment: .leading); numeric("LFE trim dB", value: $draft.bass.lfeGainDB); Text("dB") }
            Text("LFE enters at the selected trim; no extra +10 dB gain is added.").font(.caption).foregroundStyle(.secondary)
            Text("Subwoofers").font(.headline)
            if subs.isEmpty { Text("Assign the Subwoofer function to an output in Speaker Setup.").foregroundStyle(.secondary) }
            ForEach(subs) { sub in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(sub.displayName, isOn: Binding(get: { draft.bass.subwooferEndpointIDs.contains(sub.id) }, set: { enabled in
                        draft.bass.subwooferEndpointIDs.removeAll { $0 == sub.id }
                        if enabled { draft.bass.subwooferEndpointIDs.append(sub.id) }
                    }))
                    if draft.bass.subwooferEndpointIDs.contains(sub.id) {
                        HStack {
                            numeric("\(sub.displayName) trim dB", value: subBinding(sub.id, \.gainDB)); Text("dB")
                            numeric("\(sub.displayName) delay ms", value: subBinding(sub.id, \.delayMilliseconds)); Text("ms")
                            Toggle("Invert polarity", isOn: subBinding(sub.id, \.inverted))
                        }.padding(.leading, 20)
                    }
                }
            }
            Text("Use Speakers in the per-channel editor for each sub's EQ, FIR, calibration and limiter.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var routingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Use custom routing", isOn: $draft.routing.enabled)
            if draft.routing.enabled {
                HStack {
                    Picker("Source", selection: $draft.routing.sourceLayout) {
                        ForEach(RoutingSourceLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 300)
                    if draft.routing.sourceLayout == .discrete {
                        Stepper("\(draft.routing.discreteChannelCount) channels", value: $draft.routing.discreteChannelCount, in: 1...32)
                    }
                }
                Text("Each row connects a source to a physical speaker. Unrouted outputs are silent; several sources may feed one output.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($draft.routing.routes) { $route in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Picker("Source channel", selection: $route.sourceChannel) {
                                ForEach(0..<source.channelCount, id: \.self) { index in Text(sourceName(index)).tag(index) }
                            }.labelsHidden().frame(maxWidth: 220)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Picker("Destination speaker", selection: $route.destination) {
                                ForEach(endpoints) { Text($0.displayName).tag($0.id) }
                            }.labelsHidden().frame(maxWidth: 240)
                            Button { draft.routing.routes.removeAll { $0.id == route.id } } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Remove route")
                        }
                        HStack {
                            numeric("Route gain dB", value: $route.gainDB); Text("dB")
                            Toggle("Mute route", isOn: $route.muted)
                            Toggle("Invert route", isOn: $route.inverted)
                        }.padding(.leading, 12)
                    }
                }
                HStack {
                    Button("Add route") {
                        guard let endpoint = endpoints.first else { return }
                        draft.routing.routes.append(.init(sourceChannel: 0, destination: endpoint.id))
                    }
                    Button("Use speaker assignments") {
                        let candidate = self.candidate
                        if let format = try? AudioFormatDescriptor.source(sampleRate: profile.sampleRate, layout: source) {
                            draft.routing.routes = candidate.defaultSpeakerRoutes(source: format)
                                .filter { !draft.bass.enabled || !draft.bass.subwooferEndpointIDs.contains($0.destination) }
                        }
                    }
                }
            }
        }
    }

    private var crossoverControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu("Prepare active stereo setup") {
                ForEach(ActiveSpeakerPreset.allCases) { preset in
                    Button(preset.title) {
                        do { let prepared = try preset.applying(to: candidate); topologyDraft = prepared.speakerTopology; draft = prepared.multichannel; message = "Starting crossover values are 300 Hz and/or 2,000 Hz. Adjust them for the connected drivers, confirm the map, then Save." }
                        catch { message = error.localizedDescription }
                    }.disabled((topologyDraft?.endpoints.count ?? 0) < preset.rawValue * 2)
                }
            }.fixedSize()
            Toggle("Enable active crossovers", isOn: $draft.crossover.enabled)
            if draft.crossover.enabled {
                Text("Prepare an active setup above, then choose crossover frequencies and protection limits for the connected drivers before saving.")
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
                        message = "Hardware map confirmed. Save validates every driver's protection."
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
    private func subBinding<T>(_ id: PhysicalOutputID, _ key: WritableKeyPath<SubwooferSettings, T>) -> Binding<T> {
        Binding(get: { (draft.bass.subwooferSettings[id] ?? .init())[keyPath: key] }, set: {
            var sub = draft.bass.subwooferSettings[id] ?? .init(); sub[keyPath: key] = $0; draft.bass.subwooferSettings[id] = sub
        })
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
    private func save() {
        let value = draft, topology = topologyDraft, id = profile.id
        saving = true; message = nil
        Task {
            defer { saving = false }
            do {
                let updated = try await state.saveMultichannelSettings(value, profileID: id, topology: topology, previewOnly: previewOnly)
                guard profile.id == id else { return }
                profile = updated; load(useDraft: false)
            } catch { message = error.localizedDescription }
        }
    }
}

extension AppState {
    @discardableResult
    func saveMultichannelSettings(_ value: MultichannelProcessingSettings, profileID: UUID,
                                  topology: SpeakerTopology? = nil, previewOnly: Bool = false, recordHistory: Bool = true) async throws -> DeviceProfile {
        let original = try historyProfile(profileID)
        var candidate = original; candidate.multichannel = value
        if let topology { candidate.speakerTopology = topology }
        if previewOnly {
            let checked = candidate
            guard let hardware = checked.speakerTopology else { throw SpeakerTopologyError.hardwareLayoutChanged }
            _ = try await Task.detached(priority: .userInitiated) {
                try AudioRuntimePlanPreparer.prepare(profile: checked, detectedHardware: hardware)
            }.value
            profiles.update(candidate)
        } else {
            var settings = ProfileSettingsDraft(profile: original, activation: profiles.activationMode(for: original))
            settings.multichannel = value
            if let topology { settings.speakerTopology = topology }
            try await saveProfileSettings(settings)
            candidate = try historyProfile(profileID)
        }
        multichannelEditSessions[profileID] = nil
        if recordHistory {
            history.record(actionName: "Change Multichannel Processing", contextName: original.name,
                target: .profile(profileID), before: .multichannel(.init(settings: original.multichannel, topology: original.speakerTopology)),
                after: .multichannel(.init(settings: value, topology: candidate.speakerTopology)))
        }
        return candidate
    }
}
