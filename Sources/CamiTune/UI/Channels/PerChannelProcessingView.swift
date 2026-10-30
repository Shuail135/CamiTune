import CamiTuneDomain
import AppKit
import SwiftUI

enum PerChannelSelectionScope: String, CaseIterable {
    case groups = "Groups", speakers = "Speakers"
}

@MainActor
struct PerChannelProcessingView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    var convolutionOnly = false
    @ScaledMetric(relativeTo: .caption) private var selectorScale: CGFloat = 1

    var equalizerPresentation: EqualizerPresentation {
        state.profiles.effectiveLayout(for: profile).presentation[ProfileSection.perChannel.rawValue]?.equalizer ?? .both
    }
    private var presentationBinding: Binding<EqualizerPresentation> {
        Binding(get: { equalizerPresentation }, set: { value in
            var layout = state.profiles.effectiveLayout(for: profile)
            layout.presentation[ProfileSection.perChannel.rawValue] = .init(equalizer: value)
            profile.sectionLayout = layout
            runtime.updateStatus(presentation: value)
        })
    }
    @State var selectedChannelIndex = 0
    @State var selectedGroupID: SpeakerGroupID?
    @State var selectionScope: PerChannelSelectionScope = .groups
    @State var pendingBandCount: Int?
    @State var showBandReductionConfirmation = false
    @StateObject var runtime = PerChannelEditorRuntime()
    @StateObject var bandReduction = UIBackgroundOperation<[EQBand]>()
    @State var runtimeVisualsActive = false
    @State private var isExpanded = false
    @State private var observedSettings: ChannelProcessingPresentationSnapshot?

    var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    var editableChannels: [ConfiguredProcessingChannel] { profile.configuredProcessingChannels }
    var editableGroups: [SpeakerGroup] { profile.configuredSpeakerGroups }
    var selectedGroup: SpeakerGroup? {
        guard profile.usesGroupedProcessingPresentation, selectionScope == .groups else { return nil }
        return editableGroups.first { $0.id == selectedGroupID } ?? editableGroups.first
    }
    var selectedTarget: HistoryTarget {
        selectedGroup.map { .profileGroup(profile.id, $0.id) } ?? .profileChannel(profile.id, selectedChannelIndex)
    }
    private var channelSelectorWidth: CGFloat {
        let labelWidth = editableChannels.map {
            ($0.displayName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11 * selectorScale)]).width
        }.max() ?? 0
        return CGFloat(editableChannels.count) * max(80 * selectorScale, ceil(labelWidth) + 24 * selectorScale)
    }
    var selectedChannel: ConfiguredProcessingChannel {
        editableChannels.first(where: { $0.index == selectedChannelIndex })
            ?? editableChannels.first
            ?? ConfiguredProcessingChannel(index: 0, role: .unknown,
                physicalOutputID: PhysicalOutputID(deviceUID: profile.outputDeviceUID, channelIndex: 0), displayName: "No configured channels")
    }

    var body: some View {
        Group {
            if convolutionOnly {
                editorContent
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    editorContent.padding(.top, 8)
                } label: {
                    Text("Channel Processing").font(.headline)
                        .uiInteractionAnchor("channel-processing-disclosure")
                }
                .disclosureGroupStyle(SectionDisclosureStyle {
                    if isExpanded {
                        PerChannelResetButton(status: runtime.status,
                            presentation: equalizerPresentation, onReset: resetSelectedChannel)
                            .disabled(editableChannels.isEmpty || bandReduction.isRunning)
                    }
                })
            }
        }
        .alert("Recalculate Equalizer Bands?", isPresented: $showBandReductionConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingBandCount = nil
            }
            Button("Recalculate", role: .destructive) {
                applyPendingBandReduction()
            }
        } message: {
            Text(bandReductionConfirmationMessage)
        }
        .onAppear {
            refreshProcessingPresentation()
            runtimeVisualsActive = convolutionOnly || isExpanded
            if runtimeVisualsActive { loadSelectedChannelIfNeeded() }
        }
        .onChange(of: profile.id) { _ in
            selectionScope = .groups
            selectedGroupID = nil
            selectedChannelIndex = 0
            observedSettings = nil
            isExpanded = false
            refreshProcessingPresentation()
            if convolutionOnly || isExpanded { loadSelectedChannel() }
        }
        .onChange(of: profile) { _ in refreshProcessingPresentation() }
        .onReceive(state.eqDraftChanges.filter { $0 == profile.id }) { _ in
            refreshProcessingPresentation()
        }
        .onChange(of: isExpanded) { expanded in
            runtimeVisualsActive = convolutionOnly || expanded
            if expanded { loadSelectedChannel() }
            else { runtime.responseCalculationTask?.cancel() }
        }
        .onChange(of: editableChannels) { channels in
            if !channels.contains(where: { $0.index == selectedChannelIndex }) { selectedChannelIndex = channels.first?.index ?? 0 }
            if convolutionOnly || isExpanded { loadSelectedChannel() }
        }
        .onChange(of: editableGroups) { _ in
            if convolutionOnly || isExpanded { loadSelectedChannel() }
        }
        .onChange(of: profile.sampleRate) { _ in bandReduction.cancel(); updateResponses() }
        .onDisappear {
            if runtime.continuousEditDepth > 0 {
                runtime.continuousEditDepth = 1
                continuousEditingChanged(false)
            }
            bandReduction.cancel()
            runtime.responseCalculationTask?.cancel()
            runtimeVisualsActive = false
        }
    }

    private func refreshProcessingPresentation() {
        do {
            // Global drafts neither reveal this subsection nor prevent valid
            // channel changes from being presented while a global edit is incomplete.
            var draft = state.processingDrafts[profile.id] ?? .init()
            draft.equalizer = .init()
            let current = try ChannelProcessingPresentationSnapshot(profile: draft.applying(to: profile))
            guard current != observedSettings else { return }
            let previous = observedSettings
            observedSettings = current
            let editorWasVisible = convolutionOnly || isExpanded
            if !convolutionOnly, previous?.profileID == current.profileID || current.hasProcessing {
                isExpanded = true
            }
            if editorWasVisible, !runtime.suppressChanges, let settings = current.settings[selectedTarget] {
                let selectedSettingsChanged = previous?.settings[selectedTarget].map {
                    !ChannelProcessingPresentationSnapshot.sameSettings($0, settings)
                } ?? true
                if selectedSettingsChanged,
                   runtime.loadedProfileID != profile.id
                    || !ChannelProcessingPresentationSnapshot.sameSettings(settings, runtime.snapshot.processingSettings) {
                    loadSelectedChannel()
                }
            }
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !convolutionOnly {
                if bandReduction.isRunning { ProgressView("Fitting bands…").controlSize(.small) }
            }

            if editableChannels.isEmpty {
                Label("Configure enabled physical channels in Profile Settings.", systemImage: "info.circle").foregroundStyle(.secondary)
            } else if profile.usesGroupedProcessingPresentation {
                groupAndSpeakerSelector
            } else {
                OverflowAwareHorizontalScrollView(contentWidth: channelSelectorWidth, height: 40 * selectorScale) {
                    JoinedSegmentedControl(
                        options: editableChannels,
                        selection: Binding(get: { selectedChannel }, set: { selectChannel($0.index) }),
                        title: { $0.displayName }
                    )
                    .accessibilityLabel("Channel")
                }
            }

            if !convolutionOnly {
                PerChannelGainDelayRows(
                    gain: runtime.gain,
                    limiter: runtime.limiter,
                    delay: runtime.delay,
                    meters: state.meters,
                    profileID: profile.id,
                    channelIndex: selectedChannelIndex,
                    groupChannelIndices: selectedGroup?.members.map(\.channelIndex),
                    visualEffectsEnabled: runtimeVisualsActive,
                    onChanged: channelSettingsChanged,
                    onEditingChanged: continuousEditingChanged
                )

                PerChannelResponseGraph(responses: runtime.responses)

                Text("Equalizer").font(.headline)
                JoinedSegmentedControl(
                    options: EqualizerPresentation.allCases,
                    selection: presentationBinding,
                    title: { $0.title }
                )
                .accessibilityLabel("Per-channel equalizer controls")
                .frame(width: 260)

                AutomaticGlobalHeadroomView(state: state, profile: profile)

                if equalizerPresentation != .simpleTone {
                    PerChannelBandsSection(
                        bands: runtime.bands,
                        responses: runtime.responses,
                        requestBandCount: requestBandCount,
                        setKind: EQEditorSupport.setKind,
                        onBandChanged: channelSettingsChanged,
                        onGainEditingChanged: continuousEditingChanged
                    )
                }
                if equalizerPresentation == .both { Divider() }
                if equalizerPresentation != .bands {
                    PerChannelSimpleEQControls(
                        tone: runtime.simpleTone,
                        onChanged: channelSettingsChanged,
                        onEditingChanged: continuousEditingChanged
                    )
                }
            } else {
                ConvolutionEditorView(state: state, profile: $profile, target: selectedTarget,
                    targetName: selectedGroup?.name ?? selectedChannel.displayName, showsTitle: false)
                    .id(selectedTarget)
            }
        }
        .disabled(editableChannels.isEmpty || bandReduction.isRunning)
        .uiInteractionAnchor("channel-processing-content")
    }

    private var groupAndSpeakerSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            JoinedSegmentedControl(options: PerChannelSelectionScope.allCases,
                selection: Binding(get: { selectionScope }, set: { value in changeSelection { selectionScope = value } }),
                title: { $0.rawValue })
                .frame(width: 220)
                .accessibilityLabel("Processing target")
            if let group = selectedGroup {
                Picker("Group", selection: Binding(get: { group.id }, set: { selectGroup($0) })) {
                    ForEach(editableGroups) { Text("\($0.name) (\($0.members.count))").tag($0.id) }
                }.frame(maxWidth: 360)
                HStack(alignment: .top) {
                    Text(group.members.compactMap { id in editableChannels.first { $0.physicalOutputID == id }?.displayName }
                        .joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Edit a speaker") {
                        ForEach(editableChannels.filter { group.members.contains($0.physicalOutputID) }) { channel in
                            Button(channel.displayName) { selectChannel(channel.index) }
                        }
                    }.fixedSize()
                }
            } else {
                Picker("Speaker", selection: Binding(get: { selectedChannel.index }, set: { selectChannel($0) })) {
                    ForEach(editableChannels) { Text($0.displayName).tag($0.index) }
                }.frame(maxWidth: 360)
                let inherited = editableGroups.filter { $0.members.contains(selectedChannel.physicalOutputID) }.map(\.name)
                Text("Groups: \(inherited.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PerChannelResetButton: View {
    @ObservedObject var status: PerChannelStatusState
    let presentation: EqualizerPresentation
    let onReset: @MainActor () -> Void

    var body: some View {
        SectionResetButton(presentation.resetTitle) { onReset() }
            .disabled(!status.canReset)
    }
}

private struct PerChannelGainDelayRows: View {
    @ObservedObject var gain: PerChannelValueState<Double>
    @ObservedObject var limiter: PerChannelValueState<Bool>
    @ObservedObject var delay: PerChannelValueState<Double>
    let meters: AudioRuntimeMonitor
    let profileID: UUID
    let channelIndex: Int
    var groupChannelIndices: [Int]?
    let visualEffectsEnabled: Bool
    let onChanged: @MainActor () -> Void
    let onEditingChanged: @MainActor (Bool) -> Void

    var body: some View {
        PreampGainControl(
            gainDB: Binding(
                get: { gain.value },
                set: { newValue in
                    let clamped = min(12, max(-12, newValue))
                    guard clamped != gain.value else { return }
                    gain.value = clamped
                    onChanged()
                }
            ),
            limiterEnabled: Binding(
                get: { limiter.value },
                set: { newValue in
                    guard newValue != limiter.value else { return }
                    limiter.value = newValue
                    onChanged()
                }
            ),
            meters: meters,
            profileID: profileID,
            title: groupChannelIndices == nil ? "Channel gain" : "Group gain",
            channelIndex: channelIndex,
            channelIndices: groupChannelIndices,
            visualEffectsEnabled: visualEffectsEnabled,
            delayMilliseconds: Binding(
                get: { delay.value },
                set: { newValue in
                    let clamped = min(100, max(0, newValue))
                    guard clamped != delay.value else { return }
                    delay.value = clamped
                    onChanged()
                }
            ),
            onEditingChanged: onEditingChanged
        )
    }
}

private struct PerChannelResponseGraph: View {
    @ObservedObject var responses: PerChannelResponseState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Combined channel response")
                    .font(.caption.weight(.medium))
                Spacer()
            }
            LineGraph(
                points: responses.totalResponse.map { ($0.frequency, $0.gainDB) },
                xRange: 20...20_000,
                yRange: -24...24,
                zeroLine: true,
                lineColor: .green
            )
            .frame(height: 120)
        }
    }
}

private struct PerChannelBandsSection: View {
    @ObservedObject var bands: PerChannelBandsState
    let responses: PerChannelResponseState
    let requestBandCount: @MainActor (Int) -> Void
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let onBandChanged: @MainActor () -> Void
    let onGainEditingChanged: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("EQ bands")
                Picker("EQ bands", selection: Binding(
                    get: { bands.count },
                    set: { requestBandCount($0) }
                )) {
                    ForEach(0...20, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 64)
            }

            if bands.isEmpty {
                HStack {
                    Label("No EQ bands. Simple, gain, and delay still apply.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    Button("Add Bands") { requestBandCount(8) }
                }
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            } else {
                EqualizerBandScrollView(bandCount: bands.count) { columnWidth in
                    PerChannelGraphicEqualizerBands(
                        bands: bands,
                        responses: responses,
                        setKind: setKind,
                        columnWidth: columnWidth,
                        onBandChanged: onBandChanged,
                        onGainEditingChanged: onGainEditingChanged
                    )
                }
            }
        }
    }
}

/// Observes only tone values so knob edits do not rebuild the channel's band strip.
private struct PerChannelSimpleEQControls: View {
    @ObservedObject var tone: PerChannelValueState<SimpleToneSettings>
    let onChanged: @MainActor () -> Void
    let onEditingChanged: @MainActor (Bool) -> Void

    var body: some View {
        SimpleEQControlsView(
            settings: Binding(
                get: { tone.value },
                set: { value in
                    guard value != tone.value else { return }
                    tone.value = value
                    onChanged()
                }
            ),
            onEditingChanged: onEditingChanged
        )
    }
}
