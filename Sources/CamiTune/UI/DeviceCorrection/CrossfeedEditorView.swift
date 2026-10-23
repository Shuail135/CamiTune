import CamiTuneDomain
import SwiftUI

/// Listening presets and fine-tuning controls share one undoable settings draft.
@MainActor
struct CrossfeedEditorView: View {
    @ScaledMetric(relativeTo: .body) private var valueWidth: CGFloat = 76
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile

    @State private var historyBaseline: CrossfeedHistoryState?
    @State private var settings = CrossfeedProcessor.standard
    @State private var customSelected = false
    @State private var isEnabled = false
    @State private var suppressChanges = false
    @State private var liveApplyTask: Task<Void, Never>?
    @State private var hasPendingCommit = false
    @State private var pendingCommitGeneration: UInt64 = 0
    @State private var continuousEditDepth = 0
    @State private var loadedProfileID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Crossfeed").font(.title3.bold())
                DeviceCorrectionHelpIcon(title: "Crossfeed", message: "Mimics the natural experience of listening to speakers by gently blending a small amount of the left audio channel into the right ear (and vice versa) with a slight delay.")
                Spacer()
                Toggle("Enable Crossfeed", isOn: Binding(
                    get: { isEnabled },
                    set: { enabled in
                        TextFocusClearRequest.commitBeforeChangingSelection {
                            isEnabled = enabled
                            commit()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Crossfeed")
                .accessibilityIdentifier("crossfeed-enable")
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("Preset")
                        .frame(width: 104, alignment: .leading)
                    JoinedSegmentedControl(
                        options: CrossfeedPreset.allCases.map { Optional($0) } + [nil],
                        selection: Binding<CrossfeedPreset?>(
                            get: { customSelected ? nil : settings.preset },
                            set: { preset in
                                TextFocusClearRequest.commitBeforeChangingSelection {
                                    guard let preset else {
                                        customSelected = true
                                        return
                                    }
                                    let delay = settings.delayMilliseconds
                                    settings = preset.processor
                                    settings.delayMilliseconds = delay
                                    customSelected = false
                                    commit()
                                }
                            }
                        ),
                        title: { $0?.title ?? "Custom" }
                    )
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Crossfeed preset")
                    .accessibilityIdentifier("crossfeed-preset")
                    .uiInteractionAnchor("crossfeed-preset")
                    .padding(.leading, PreampSliderLayout.horizontalInset)
                    Spacer(minLength: 0)
                }

                controlRow(title: "Amount", value: setting(\.amountPercent), range: 0...100, step: 0.1, unit: "%",
                    help: "Higher amounts bring hard-panned instruments closer to the center. Zero leaves stereo unchanged.")

                controlRow(title: "Frequency", value: setting(\.cutoffFrequency),
                    range: min(200, settings.cutoffFrequency)...max(2_000, settings.cutoffFrequency), step: 1, unit: "Hz",
                    help: "Higher frequencies blend more of the midrange.")

                controlRow(title: "Delay", value: setting(\.delayMilliseconds), range: 0...5, step: 0.01, unit: "ms",
                    help: "Extra delay in the opposite ear. Defaults to 0 ms. Short delays around 0.3 ms are a useful starting point when adding delay.")
            }
            .disabled(!isEnabled)
        }
        .focusSection()
        .onChange(of: state.historyReplayRevision) { _ in load() }
        .onAppear { loadIfNeeded() }
        .onChange(of: profile.id) { _ in
            loadIfNeeded()
        }
        .onDisappear {
            if continuousEditDepth > 0 { continuousEditDepth = 1; continuousEditingChanged(false) }
            flushPendingCommit()
        }
    }

    private func setting(_ keyPath: WritableKeyPath<CrossfeedProcessor, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            guard value.isFinite, settings[keyPath: keyPath] != value else { return }
            settings[keyPath: keyPath] = value
            if keyPath == \.delayMilliseconds { settings.model = .classic }
            customSelected = true
            commit()
        })
    }

    private func controlLabel(_ title: String, help: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            DeviceCorrectionHelpIcon(title: title, message: help)
                .disabled(false)
        }
    }

    private func controlRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        help: String
    ) -> some View {
        return HStack(spacing: 12) {
            controlLabel(title, help: help)
                .frame(width: 104, alignment: .leading)
            SteppedValueSlider(
                value: value,
                in: range,
                step: step,
                style: .preamp,
                onEditingChanged: { isEditing in
                    continuousEditingChanged(isEditing)
                }
            )
            .accessibilityLabel("Crossfeed " + title)
            .accessibilityValue(value.wrappedValue.formatted(.number.precision(.fractionLength(0...3))) + " " + unit)
            .accessibilityIdentifier("crossfeed-" + title.lowercased())
            HStack(spacing: 4) {
                CrossfeedValueField(title: title, value: value, range: range, unit: unit)
                    .id(profile.id)
                    .frame(width: valueWidth)
                Text(unit).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
            }
        }
    }

    private func loadIfNeeded() {
        guard loadedProfileID != profile.id else { return }
        load()
    }

    private func load() {
        if let oldID = loadedProfileID {
            state.history.cancelGesture(key: GestureKey(target: .profile(oldID), control: "crossfeed"))
        }
        liveApplyTask?.cancel()
        pendingCommitGeneration &+= 1
        hasPendingCommit = false
        suppressChanges = true
        let saved = profile.processing.crossfeed
        settings = saved?.processor ?? .standard
        customSelected = settings.preset == nil
        isEnabled = saved?.isEnabled ?? false
        historyBaseline = currentHistoryState
        continuousEditDepth = 0
        loadedProfileID = profile.id
        DispatchQueue.main.async { suppressChanges = false }
    }

    private func commit() {
        guard !suppressChanges else { return }
        liveApplyTask?.cancel()
        pendingCommitGeneration &+= 1
        hasPendingCommit = true
        guard continuousEditDepth == 0 else { return }
        recordEdit()
        scheduleCommit(milliseconds: 120)
    }

    private func continuousEditingChanged(_ isEditing: Bool) {
        if isEditing {
            if continuousEditDepth == 0 {
                state.history.beginGesture(key: gestureKey, actionName: "Adjust Crossfeed", contextName: profile.name,
                    target: .profile(profile.id), before: .crossfeed(currentHistoryState))
            }
            continuousEditDepth += 1
            liveApplyTask?.cancel()
            return
        }
        continuousEditDepth = max(0, continuousEditDepth - 1)
        guard continuousEditDepth == 0 else { return }
        state.history.endGesture(key: gestureKey, after: .crossfeed(currentHistoryState))
        historyBaseline = currentHistoryState
        saveCurrentState()
        guard hasPendingCommit else { return }
        scheduleCommit(milliseconds: 50)
    }

    private func scheduleCommit(milliseconds: Int) {
        state.markPendingEditorApply(profile.id)
        liveApplyTask?.cancel()
        let editGeneration = state.editGeneration
        let generation = pendingCommitGeneration
        let pendingSettings = settings
        let pendingEnabled = isEnabled
        let profileID = profile.id
        liveApplyTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(milliseconds))
            } catch {
                return
            }
            guard editGeneration == state.editGeneration, !Task.isCancelled,
                  continuousEditDepth == 0,
                  profile.id == profileID,
                  pendingCommitGeneration == generation else { return }
            await persist(
                pendingSettings,
                enabled: pendingEnabled,
                profileID: profileID
            )
            if pendingCommitGeneration == generation {
                hasPendingCommit = false
            }
        }
    }

    private func flushPendingCommit() {
        guard !suppressChanges, hasPendingCommit else { return }
        liveApplyTask?.cancel()
        let editGeneration = state.editGeneration
        let generation = pendingCommitGeneration
        let pendingSettings = settings
        let pendingEnabled = isEnabled
        let profileID = profile.id
        Task { @MainActor in
            guard editGeneration == state.editGeneration, profile.id == profileID,
                  pendingCommitGeneration == generation else { return }
            await persist(
                pendingSettings,
                enabled: pendingEnabled,
                profileID: profileID
            )
            if pendingCommitGeneration == generation {
                hasPendingCommit = false
            }
        }
    }

    @MainActor
    private func persist(
        _ pendingSettings: CrossfeedProcessor,
        enabled: Bool,
        profileID: UUID
    ) async {
        guard profile.id == profileID else { return }
        do {
            try await state.applyHistoryProfileIfActive(profileID)
        } catch { state.errorMessage = error.localizedDescription }
    }
    private var gestureKey: GestureKey { GestureKey(target: .profile(profile.id), control: "crossfeed") }
    private var currentHistoryState: CrossfeedHistoryState { CrossfeedHistoryState(processor: settings, isEnabled: isEnabled) }
    private func recordEdit() {
        if let before = historyBaseline {
            state.history.record(actionName: "Edit Crossfeed", contextName: profile.name, target: .profile(profile.id),
                before: .crossfeed(before), after: .crossfeed(currentHistoryState))
        }
        historyBaseline = currentHistoryState
        saveCurrentState()
    }
    private func saveCurrentState() {
        do { try state.mutateSavedProcessing(profileID: profile.id) { $0.setCrossfeed(settings, enabled: isEnabled) } }
        catch { state.errorMessage = error.localizedDescription }
    }
}

/// Commit a complete number on Return or focus loss, keeping intermediate
/// typing out of the audio settings and making each edit one undo step.
@MainActor
private struct CrossfeedValueField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    @State private var draft: String
    @FocusState private var focused: Bool

    private static let format = FloatingPointFormatStyle<Double>.number
        .grouping(.never).precision(.fractionLength(0...3))

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) {
        self.title = title
        _value = value
        self.range = range
        self.unit = unit
        _draft = State(initialValue: value.wrappedValue.formatted(Self.format))
    }

    var body: some View {
        TextField(title, text: $draft)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onSubmit { commitDraft() }
            .onChange(of: focused) { if !$0 { commitDraft() } }
            .onChange(of: value) { draft = $0.formatted(Self.format) }
            .onExitCommand {
                draft = value.formatted(Self.format)
                focused = false
            }
            .accessibilityLabel("Crossfeed \(title) (\(unit))")
            .accessibilityIdentifier("crossfeed-\(title.lowercased())-value")
    }

    private func commitDraft() {
        guard draft != value.formatted(Self.format) else { return }
        if let number = try? Double(draft, format: Self.format, lenient: false), number.isFinite {
            value = min(range.upperBound, max(range.lowerBound, number))
        }
        draft = value.formatted(Self.format)
    }
}
