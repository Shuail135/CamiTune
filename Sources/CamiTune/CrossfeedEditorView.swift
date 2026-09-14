import SwiftUI

/// Simple crossfeed controls. The split/merge mixers and the cross-path
/// low-pass, delay, and gain filters remain graph/compiler implementation
/// details as required by the roadmap.
@MainActor
struct CrossfeedEditorView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile

    @State private var historyBaseline: CrossfeedHistoryState?
    @State private var settings = CrossfeedProcessor.standard
    @State private var isEnabled = false
    @State private var suppressChanges = false
    @State private var liveApplyTask: Task<Void, Never>?
    @State private var hasPendingCommit = false
    @State private var pendingCommitGeneration: UInt64 = 0
    @State private var continuousEditDepth = 0
    @State private var loadedProfileID: UUID?

    private var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Headphone Crossfeed").font(.title3.bold())
                    Spacer()
                    Toggle("Enable", isOn: Binding(
                        get: { isEnabled },
                        set: { value in
                            isEnabled = value
                            commit()
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden().accessibilityLabel("Headphone Crossfeed")
                }

                Text("Blend delayed, low-frequency sound from each stereo channel into the opposite ear to reduce hard left/right separation on headphones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    controlRow(
                        title: "Crossfeed Amount",
                        value: Binding(
                            get: { settings.amountPercent },
                            set: { value in
                                settings.amountPercent = value
                                commit()
                            }
                        ),
                        range: 0...100,
                        step: 1,
                        valueText: settings.amountPercent.formatted(
                            .number.precision(.fractionLength(0))
                        ) + "%"
                    )
                    controlRow(
                        title: "Delay",
                        value: Binding(
                            get: { settings.delayMilliseconds },
                            set: { value in
                                settings.delayMilliseconds = value
                                commit()
                            }
                        ),
                        range: 0...2,
                        step: 0.01,
                        valueText: settings.delayMilliseconds.formatted(
                            .number.precision(.fractionLength(2))
                        ) + " ms"
                    )
                    controlRow(
                        title: "Frequency",
                        value: Binding(
                            get: { settings.cutoffFrequency },
                            set: { value in
                                settings.cutoffFrequency = value
                                commit()
                            }
                        ),
                        range: 200...2_000,
                        step: 10,
                        valueText: settings.cutoffFrequency.formatted(
                            .number.precision(.fractionLength(0))
                        ) + " Hz"
                    )
                }
                .disabled(!isEnabled)

                Text("Automatic headroom includes the maximum correlated-signal boost introduced by crossfeed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
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

    private func controlRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 130, alignment: .leading)
            Slider(
                value: value,
                in: range,
                step: step,
                onEditingChanged: { isEditing in
                    continuousEditingChanged(isEditing)
                }
            )
            Text(valueText)
                .monospacedDigit()
                .frame(width: 78, alignment: .trailing)
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
