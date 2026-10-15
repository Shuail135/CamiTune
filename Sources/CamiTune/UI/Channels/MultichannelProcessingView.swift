import CamiTuneAudio
import CamiTuneDomain
import AppKit
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
    @State private var selectedEditor = Editor.routing
    @State private var selectedDriverID: PhysicalOutputID?
    @State private var collapsedRouteIDs: Set<UUID> = []

    private enum Editor: String, CaseIterable {
        case routing = "Routing", crossovers = "Crossovers"
    }

    private var saving: Bool {
        // Subwoofer autosaves share the transaction without locking this editor.
        state.isSavingProfileSettings && (
            draft.routing != profile.multichannel.routing
            || draft.crossover != profile.multichannel.crossover
            || topologyDraft != profile.speakerTopology
        )
    }
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
            finishEditing()
            if enabled {
                draft.routing = MultichannelRoutingEditor.enablingRouting(in: candidate)
            } else { draft.routing.enabled = false }
        })
    }
    private var editorSelection: Binding<Editor> {
        Binding(get: { selectedEditor }, set: { value in
            finishEditing()
            selectedEditor = value
        })
    }
    private var selectedDriver: SpeakerEndpoint? {
        drivers.first { $0.id == selectedDriverID } ?? drivers.first
    }
    private var hardwareMapConfirmed: Bool {
        guard let topology = topologyDraft,
              let fingerprint = try? HardwareTopologyFingerprint(topology: topology) else { return false }
        return draft.crossover.reviewedHardware == fingerprint
    }
    private var source: LPCMChannelLayout {
        draft.routing.sourceLayout.layout(channelCount: draft.routing.discreteChannelCount)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Routing & Crossovers").font(.title3.bold())
                JoinedSegmentedControl(options: Editor.allCases, selection: editorSelection, title: { $0.rawValue })
                    .frame(width: 260)
                    .accessibilityLabel("Routing and crossover controls")
                if selectedEditor == .routing {
                    routingControls
                } else {
                    crossoverControls
                }
                Divider()
                HStack(alignment: .top) {
                    if let message = state.multichannelAutosaveErrors[profile.id] ?? message {
                        Text(message).font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Export runtime plan…") {
                        Task { do { try await state.exportRuntimePlan(profile: profile, previewOnly: previewOnly) } catch { message = error.localizedDescription } }
                    }.fixedSize().disabled(changed)
                }
            }.padding(6).disabled(saving).id(editorRevision)
        }
        .onAppear {
            if loadedID != profile.id { load() }
            if changed { scheduleAutosave() }
        }
        .onChange(of: editorSnapshot) { _ in
            let pending = state.multichannelEditSessions[profile.id]
            // Returning to the saved value still supersedes an older queued edit.
            if loadedID == profile.id, changed || pending != nil, !state.history.isReplaying,
               pending != editorSnapshot { scheduleAutosave() }
        }
        .onChange(of: draft.routing.enabled) { enabled in
            if !enabled { collapsedRouteIDs = Set(draft.routing.routes.map(\.id)) }
        }
        .onReceive(state.profiles.$multichannelDrafts) { sessions in
            guard loadedID == profile.id, let session = sessions[profile.id], session != editorSnapshot else { return }
            draft = session.settings; topologyDraft = session.topology
        }
        .onChange(of: profile.multichannel) { _ in reloadAfterAutosave() }
        .onChange(of: profile.speakerTopology) { _ in reloadAfterAutosave() }
        .onChange(of: profile.id) { _ in load() }
        .onDisappear {
            if loadedID == profile.id, changed || state.multichannelEditSessions[profile.id] != nil { scheduleAutosave() }
        }
        .onChange(of: state.historyReplayRevision) { _ in
            if let current = state.profiles.profiles.first(where: { $0.id == profile.id }) { profile = current }
            load()
            if changed { scheduleAutosave() }
        }
    }

    private var routingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom Routing").font(.headline)
                DeviceCorrectionHelpIcon(title: "Custom Routing",
                    message: "Enable custom routing to apply these connections. Edits save automatically, even while routing is off. Speaker assignments are used while routing is off.")
                Spacer()
                Toggle("Enable custom routing", isOn: routingEnabled)
                    .toggleStyle(.switch).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    WrappingControlLayout {
                        Picker("Input layout", selection: $draft.routing.sourceLayout) {
                            ForEach(RoutingSourceLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.frame(width: 280)
                        if draft.routing.sourceLayout == .discrete {
                            Stepper("\(draft.routing.discreteChannelCount) channels", value: $draft.routing.discreteChannelCount, in: 1...32)
                                .accessibilityLabel("Input channel count")
                        }
                    }
                    Spacer()
                    Button {
                        finishEditing()
                        guard let route = MultichannelRoutingEditor.nextRoute(in: candidate) else { return }
                        draft.routing.routes.append(route)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Add route")
                        .disabled(MultichannelRoutingEditor.nextRoute(in: candidate) == nil)
                    SectionResetButton("Reset to speaker assignments") {
                        finishEditing()
                        let candidate = self.candidate
                        if let format = try? AudioFormatDescriptor.source(sampleRate: profile.sampleRate, layout: source) {
                            draft.routing.routes = candidate.defaultSpeakerRoutes(source: format)
                                .filter { !draft.bass.enabled || !draft.bass.subwooferEndpointIDs.contains($0.destination) }
                        }
                    }
                }
                if draft.routing.routes.isEmpty {
                    Text("No routes yet. Add a connection or start from speaker assignments.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(draft.routing.routes) { route in
                    routingRow(routeBinding(route))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func routingRow(_ route: Binding<SpeakerRoute>) -> some View {
        let number = (draft.routing.routes.firstIndex { $0.id == route.wrappedValue.id } ?? 0) + 1
        let expanded = routeExpanded(route.wrappedValue.id)
        return DisclosureGroup(isExpanded: expanded) {
            routingDetails(route)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Route \(number)").font(.subheadline.weight(.semibold))
                if !expanded.wrappedValue {
                    Text(routeSummary(route.wrappedValue)).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.trailing, 30)
        }
        .disclosureGroupStyle(SectionDisclosureStyle())
        .overlay(alignment: .topTrailing) {
            Button {
                finishEditing()
                draft.routing.routes.removeAll { $0.id == route.wrappedValue.id }
            } label: { Image(systemName: "minus.circle").frame(width: 22, height: 22) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove route \(number)")
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
        .focusSection()
    }

    private func routeExpanded(_ id: UUID) -> Binding<Bool> {
        Binding(get: { !collapsedRouteIDs.contains(id) }, set: { expanded in
            if expanded {
                collapsedRouteIDs.remove(id)
            } else {
                finishEditing()
                collapsedRouteIDs.insert(id)
            }
        })
    }

    private func routeSummary(_ route: SpeakerRoute) -> String {
        let input = (0..<source.channelCount).contains(route.sourceChannel)
            ? sourceName(route.sourceChannel) : "Unavailable source \(route.sourceChannel + 1)"
        let output = routingEndpoints.first { $0.id == route.destination }?.displayName
            ?? "Unavailable output \(route.destination.channelIndex + 1)"
        return "\(input) → \(output)"
    }

    private func routingDetails(_ route: Binding<SpeakerRoute>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ResponsiveStackLayout(minimumHorizontalWidth: 560, horizontalSpacing: 16, verticalSpacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Source channel").font(.caption).foregroundStyle(.secondary)
                    Picker("Source channel", selection: route.sourceChannel) {
                        if !(0..<source.channelCount).contains(route.wrappedValue.sourceChannel) {
                            Text("Unavailable source \(route.wrappedValue.sourceChannel + 1)").tag(route.wrappedValue.sourceChannel)
                        }
                        ForEach(0..<source.channelCount, id: \.self) { index in Text(sourceName(index)).tag(index) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .lastTextBaseline, spacing: 16) {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Destination speaker").font(.caption).foregroundStyle(.secondary)
                        Picker("Destination speaker", selection: route.destination) {
                            if !routingEndpoints.contains(where: { $0.id == route.wrappedValue.destination }) {
                                Text("Unavailable output \(route.wrappedValue.destination.channelIndex + 1)").tag(route.wrappedValue.destination)
                            }
                            ForEach(routingEndpoints) { Text($0.displayName).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Text("Gain").font(.callout)
                SteppedValueSlider(value: route.gainDB, in: -120...24, step: 0.5)
                    .accessibilityLabel("Route gain")
                numeric("Route gain dB", value: route.gainDB)
                Text("dB").font(.callout).foregroundStyle(.secondary)
            }
            WrappingControlLayout {
                Toggle("Mute route", isOn: route.muted)
                Toggle("Invert route", isOn: route.inverted)
            }.toggleStyle(.checkbox).font(.callout)
        }
    }

    private func routeBinding(_ snapshot: SpeakerRoute) -> Binding<SpeakerRoute> {
        Binding(get: { draft.routing.routes.first { $0.id == snapshot.id } ?? snapshot }, set: { value in
            guard let index = draft.routing.routes.firstIndex(where: { $0.id == snapshot.id }) else { return }
            draft.routing.routes[index] = value
        })
    }

    private var crossoverHelpMessage: String {
        var hints = [
            "For speakers whose individual drivers connect to separate amplifier outputs.",
            "Active stereo setups need at least 4 output channels for 2-way or 6 for 3-way. The current setup has \(topologyDraft?.endpoints.count ?? 0)."
        ]
        if drivers.isEmpty {
            if (topologyDraft?.endpoints.count ?? 0) >= ActiveSpeakerPreset.twoWay.rawValue * 2 {
                hints.append("Choose an active stereo setup, or assign Woofer, Midrange or Tweeter speaker functions in Device Configuration.")
            }
        } else {
            if !draft.crossover.enabled {
                hints.append("Enable crossovers to edit driver filters and protection.")
            }
            hints.append("Choose crossover frequencies and protection limits for each driver, then confirm the hardware map. Valid changes save automatically.")
            hints.append("Starting crossover values are 300 Hz and/or 2,000 Hz. Adjust them for the connected drivers, then confirm the hardware map. Valid changes save automatically.")
            hints.append("Required limiters run last at −3 dBFS. Tweeters and midrange drivers require high-pass and limiter protection. Positive global preamp is blocked by the default 0 dB gain limit.")
            if hardwareMapConfirmed {
                hints.append("Hardware map confirmed. Changes save automatically once every driver's protection is valid.")
            }
        }
        return hints.joined(separator: "\n\n")
    }

    private var crossoverControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Active Crossovers & Protection").font(.headline)
                DeviceCorrectionHelpIcon(title: "Active Crossovers & Protection", message: crossoverHelpMessage)
                Spacer()
                Toggle("Enable active crossovers", isOn: $draft.crossover.enabled)
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(drivers.isEmpty && !draft.crossover.enabled)
            }
            Menu("Prepare active stereo setup") {
                ForEach(ActiveSpeakerPreset.allCases) { preset in
                    Button(preset.title) {
                        finishEditing()
                        do {
                            let prepared = try preset.applying(to: candidate)
                            topologyDraft = prepared.speakerTopology
                            draft = prepared.multichannel
                            selectedDriverID = nil
                            message = nil
                        } catch { message = error.localizedDescription }
                    }.disabled((topologyDraft?.endpoints.count ?? 0) < preset.rawValue * 2)
                }
            }.fixedSize()
            if !drivers.isEmpty {
                driverControls.disabled(!draft.crossover.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var driverControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let driver = selectedDriver {
                Picker("Driver", selection: Binding(get: { driver.id }, set: { value in
                    finishEditing()
                    selectedDriverID = value
                })) {
                    ForEach(drivers) { Text("\($0.displayName) · \($0.function.displayName)").tag($0.id) }
                }.frame(maxWidth: 420)
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(driver.displayName) · \(driver.function.displayName)").font(.headline)
                    if draft.crossover.endpoints.contains(where: { $0.endpointID == driver.id }) {
                        crossoverRow(driver)
                    } else {
                        Button("Configure \(driver.displayName)") {
                            draft.crossover.endpoints.append(.init(endpointID: driver.id))
                            draft.crossover.protection[driver.id] = .init()
                        }
                    }
                }
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
                .id(driver.id)
                .focusSection()
                Divider()
                Label(hardwareMapConfirmed
                      ? "Hardware map confirmed; hardware changes block activation."
                      : "Hardware map needs confirmation.",
                      systemImage: hardwareMapConfirmed ? "checkmark.circle" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Confirm this hardware map") {
                    finishEditing()
                    do {
                        guard let topology = topologyDraft else { throw SpeakerTopologyError.invalidDeviceUID }
                        draft.crossover.reviewedHardware = try .init(topology: topology)
                        message = nil
                    } catch { message = error.localizedDescription }
                }.disabled(hardwareMapConfirmed || topologyDraft == nil)
            }
        }
    }

    private func crossoverRow(_ driver: SpeakerEndpoint) -> some View {
        let crossover = crossoverBinding(driver.id)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Crossover filters").font(.subheadline.weight(.semibold))
            ResponsiveStackLayout(minimumHorizontalWidth: 600, horizontalSpacing: 24, verticalSpacing: 10) {
                optionalControl("High-pass", fieldTitle: "Driver high-pass Hz", value: crossover.highPassHz, defaultValue: 2000, unit: "Hz")
                optionalControl("Low-pass", fieldTitle: "Driver low-pass Hz", value: crossover.lowPassHz, defaultValue: 2000, unit: "Hz")
            }
            Picker("Crossover slope", selection: crossover.slope) {
                ForEach(CrossoverSlope.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(maxWidth: 420)
            Divider()
            Text("Driver protection").font(.subheadline.weight(.semibold))
            ResponsiveStackLayout(minimumHorizontalWidth: 600, horizontalSpacing: 24, verticalSpacing: 10) {
                optionalControl("Require high-pass", fieldTitle: "Minimum protection Hz",
                    value: protectionBinding(driver.id, \.requiredHighPassHz), defaultValue: 2000, unit: "Hz")
                optionalControl("Limit gain", fieldTitle: "Maximum gain dB",
                    value: protectionBinding(driver.id, \.maximumGainDB), defaultValue: 0, unit: "dB")
            }
            if draft.crossover.protection[driver.id]?.requiredHighPassHz != nil {
                Picker("Minimum protection slope", selection: protectionBinding(driver.id, \.requiredHighPassSlope)) {
                    ForEach(CrossoverSlope.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 420)
            }
            Toggle("Require limiter", isOn: protectionBinding(driver.id, \.limiterRequired))
                .toggleStyle(.checkbox)
        }
    }

    private func crossoverBinding(_ id: PhysicalOutputID) -> Binding<EndpointCrossover> {
        Binding(get: { draft.crossover.endpoints.first { $0.endpointID == id } ?? .init(endpointID: id) }, set: { value in
            guard let index = draft.crossover.endpoints.firstIndex(where: { $0.endpointID == id }) else { return }
            draft.crossover.endpoints[index] = value
        })
    }

    private func optionalControl(_ title: String, fieldTitle: String, value: Binding<Double?>,
                                 defaultValue: Double, unit: String) -> some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: optionalEnabled(value, defaultValue: defaultValue)).toggleStyle(.checkbox)
            Spacer(minLength: 8)
            numeric(fieldTitle, value: optionalValue(value, fallback: defaultValue))
                .disabled(value.wrappedValue == nil)
            Text(unit).font(.callout).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numeric(_ title: String, value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder).monospacedDigit().multilineTextAlignment(.trailing)
            .frame(width: 78).accessibilityLabel(title)
    }
    private func finishEditing() { NSApp.keyWindow?.makeFirstResponder(nil) }
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
        let changedProfile = loadedID != profile.id
        if !useDraft { state.multichannelEditSessions[profile.id] = nil }
        let savedDraft = useDraft ? state.multichannelEditSessions[profile.id] : nil
        draft = savedDraft?.settings ?? profile.multichannel
        topologyDraft = savedDraft?.topology ?? profile.speakerTopology
        if changedProfile {
            selectedEditor = draft.crossover.enabled && !draft.routing.enabled ? .crossovers : .routing
            selectedDriverID = nil
            collapsedRouteIDs = draft.routing.enabled ? [] : Set(draft.routing.routes.map(\.id))
        }
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
                    .accessibilityHint("Adjusts this subwoofer’s next test sound. 0 dB uses the standard test level.")
                Text(String(format: "%+.0f dB", testGainDB))
                    .font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing)
                SectionResetButton("Reset subwoofer test volume") { testGainDB = 0 }
                    .disabled(testGainDB == 0)
            }
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
                            .accessibilityHint("Keep at least one subwoofer selected while bass management is on.")
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
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Stop redirecting bass from this group")
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
    let onOpenSettings: () -> Void

    private var settings: MultichannelProcessingSettings {
        store.multichannelDrafts[profile.id]?.settings ?? profile.multichannel
    }
    private var hasSubwoofer: Bool { profile.configuredSpeakerEndpoints.contains { $0.function == .subwoofer } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Subwoofer Control").font(.title3.bold())
                    Spacer()
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Subwoofer Settings")
                    .accessibilityHint("Opens the subwoofer channel’s bass management in Speaker & Listening Position.")
                }
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
        // Seed only untouched settings; preserve configurations edited while off.
        if routing == AdvancedRoutingSettings() {
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
