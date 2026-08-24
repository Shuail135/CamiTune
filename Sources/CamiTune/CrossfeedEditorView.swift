import SwiftUI

/// Simple crossfeed controls. The split/merge mixers and the cross-path
/// low-pass, delay, and gain filters remain graph/compiler implementation
/// details as required by the roadmap.
@MainActor
struct CrossfeedEditorView: View {
    let state: AppState
    @Binding var profile: DeviceProfile

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
        .onAppear { loadIfNeeded() }
        .onChange(of: profile.id) { _ in
            loadedProfileID = nil
            loadIfNeeded()
        }
        .onDisappear { flushPendingCommit() }
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
        liveApplyTask?.cancel()
        pendingCommitGeneration &+= 1
        hasPendingCommit = false
        suppressChanges = true
        let saved = profile.processing.crossfeed
        settings = saved?.processor ?? .standard
        isEnabled = saved?.isEnabled ?? false
        loadedProfileID = profile.id
        DispatchQueue.main.async { suppressChanges = false }
    }

    private func commit() {
        guard !suppressChanges else { return }
        liveApplyTask?.cancel()
        pendingCommitGeneration &+= 1
        hasPendingCommit = true
        guard continuousEditDepth == 0 else { return }
        scheduleCommit(milliseconds: 120)
    }

    private func continuousEditingChanged(_ isEditing: Bool) {
        if isEditing {
            continuousEditDepth += 1
            liveApplyTask?.cancel()
            return
        }
        continuousEditDepth = max(0, continuousEditDepth - 1)
        guard continuousEditDepth == 0, hasPendingCommit else { return }
        scheduleCommit(milliseconds: 50)
    }

    private func scheduleCommit(milliseconds: Int) {
        liveApplyTask?.cancel()
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
            guard !Task.isCancelled,
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
        let generation = pendingCommitGeneration
        let pendingSettings = settings
        let pendingEnabled = isEnabled
        let profileID = profile.id
        Task { @MainActor in
            guard profile.id == profileID,
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
        var updated = profile
        updated.processing.setCrossfeed(pendingSettings, enabled: enabled)
        guard updated != profile else { return }
        profile = updated
        guard profileIsActive else { return }
        await state.apply(profile: updated)
    }
}
