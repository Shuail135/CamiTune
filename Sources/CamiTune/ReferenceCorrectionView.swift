import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ReferenceCorrectionView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    private var draft: DeviceCorrectionProfile? {
        get { state.referenceCorrectionSessions[profile.id]?.draft ?? (state.referenceCorrectionSessions[profile.id] == nil ? profile.personalReferenceCorrection : nil) }
        nonmutating set { state.setReferenceCorrectionDraft(newValue, for: profile.id) }
    }
    @State private var snapshot: DeviceProfile?
    @State private var showingCorrection = false
    @State private var importing = false
    @State private var confirmTransfer = false
    @State private var pendingProfile: DeviceProfile?
    @State private var pendingEQ: String?
    @State private var busy = false
    @State private var message: String?
    @State private var headroom: Double?
    @StateObject private var importOperation = UIBackgroundOperation<DeviceCorrectionProfile>()

    private var dirty: Bool { draft != snapshot?.personalReferenceCorrection }
    private var headphones: Bool { profile.effectiveEndpointKind == .headphones }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if profile.processing.deviceCorrection != nil { Text("Your legacy correction still applies globally. Open Equalizer to edit it.").font(.caption).foregroundStyle(.secondary) }
            if headphones {
                Text("Measured headphone correction is still in development. You can import compatible filters below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Device Correction…") { showingCorrection = true }.disabled(headphones)
                    .help("Choose a measured earphone response and target.")
                Button("Import .txt") { importing = true }.help("Import compatible filter values from a text file.")
                Button("Paste APO Text") { importText(NSPasteboard.general.string(forType: .string) ?? "", name: "Pasted APO correction") }
                    .help("Paste Equalizer APO-compatible filter text.")
            }.buttonStyle(.bordered)
            if let correction = draft {
                HStack {
                    Text(correction.deviceName).font(.headline)
                    Text("\(correction.filters.count) filters · \(dirty ? "Unsaved" : correction.isEnabled ? "Enabled" : "Disabled")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { draft = nil }
                }
                if correction.importedAPOText {
                    Text("Imported correction is separate from User Equalizer. APO Preamp is ignored; use User Preamp instead. Import or paste again to replace these filters.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Graph").font(.headline)
                    if ReferenceCorrection.validFilters(correction.filters, sampleRate: Double(profile.sampleRate)) {
                        CorrectionResponseGraph(profile: correction, sampleRate: Double(profile.sampleRate))
                            .equatable().frame(height: 230)
                    } else {
                        Text("Enter a valid frequency below Nyquist, finite gain, and positive Q.").foregroundStyle(.orange)
                    }
                    if let headroom {
                        Text("Automatic headroom: \(headroom, format: .number.precision(.fractionLength(2))) dB")
                            .font(.caption.monospacedDigit())
                    }
                    CorrectionFilterTable(filters: Binding(get: { draft?.filters ?? [] }, set: { draft?.filters = $0 }))
                }
                HStack {
                    if dirty {
                        Button("Save Correction") { commit(draft) }
                            .disabled(!ReferenceCorrection.validFilters(correction.filters, sampleRate: Double(profile.sampleRate)))
                        Button("Discard Edits") { draft = profile.personalReferenceCorrection; reload() }
                    }
                    Button("Import to Equalizer") { requestTransfer() }.disabled(dirty)
                        .help("Replace User Equalizer bands and remove this correction after a successful save.")
                }.buttonStyle(.bordered)
                if dirty { Text("Save your correction edits before transferring to Equalizer.").font(.caption).foregroundStyle(.secondary) }
            }
            if draft == nil, dirty {
                HStack {
                    Text("Correction cleared · Unsaved").font(.caption)
                    Button("Save Correction") { commit(nil) }
                    Button("Discard Edits") { draft = profile.personalReferenceCorrection; reload() }
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if importOperation.isRunning { ProgressView("Importing correction…").controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .disabled(busy || importOperation.isRunning || state.isSavingProfileSettings || state.transitionInProgress)
        .onAppear { reload() }
        .onDisappear { importOperation.cancel() }
        .onChange(of: state.historyReplayRevision) { _ in snapshot = profile }
        .onChange(of: profile.id) { _ in reload() }
        .onChange(of: profile) { _ in if !dirty { reload() } }
        .task(id: draft) {
            guard let draft else { headroom = nil; return }
            let sampleRate = Double(profile.sampleRate)
            let result = await Task.detached(priority: .utility) {
                ReferenceCorrection.headroomDB(draft, sampleRate: sampleRate)
            }.value
            guard !Task.isCancelled else { return }
            headroom = result
        }
        .sheet(isPresented: $showingCorrection) {
            DeviceCorrectionEditorView(existing: draft?.importedAPOText == false ? draft : nil,
                sampleRate: Double(profile.sampleRate), referenceEndpoint: profile.effectiveEndpointKind,
                automaticHeadroom: { filters in
                    let candidate = (try? state.applyingSessionEQDrafts(to: profile)) ?? profile
                    var correction = draft ?? DeviceCorrectionProfile(deviceName: "Correction", policy: .recommended,
                        measurement: .flat(), target: .flat(), curve: CorrectionCurve(points: []), filters: [], preampDB: 0)
                    correction.filters = filters
                    return ReferenceCorrection.headroomDB(correction, sampleRate: Double(candidate.sampleRate))
                }, shouldConfirmReplacement: { false }, onCancel: { showingCorrection = false },
                onLoad: { correction in showingCorrection = false; draft = correction })
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            do {
                let url = try result.get()
                beginImport { try ReferenceCorrection.importFile(url) }
            } catch { message = error.localizedDescription }
        }
        .alert("Replace User Equalizer bands?", isPresented: $confirmTransfer) {
            Button("Cancel", role: .cancel) { pendingProfile = nil }
            Button("Replace Bands", role: .destructive) { transfer() }
        } message: {
            Text("This replaces the saved and unsaved User Equalizer bands. User Preamp is retained. The Reference correction is removed only after the transfer succeeds.")
        }
    }

    private func reload() {
        importOperation.cancel()
        snapshot = profile
        if state.referenceCorrectionSessions[profile.id] == nil {
            state.referenceCorrectionSessions[profile.id] = ReferenceCorrectionSession(draft: profile.personalReferenceCorrection)
        }
        message = nil
    }
    private func importText(_ text: String, name: String) {
        beginImport { try ReferenceCorrection.importText(text, name: name) }
    }
    private func beginImport(_ work: @escaping @Sendable () throws -> DeviceCorrectionProfile) {
        let original = profile
        let generation = state.editGeneration
        message = nil
        importOperation.run(work) { result in
            guard generation == state.editGeneration, profile == original else { return }
            switch result {
            case .success(let correction): draft = correction
            case .failure(let error): message = error.localizedDescription
            }
        }
    }
    private func commit(_ correction: DeviceCorrectionProfile?) {
        guard let original = snapshot, original.id == profile.id else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                try await state.saveReferenceCorrection(profile: original, correction: correction)
                if let latest = state.profiles.profiles.first(where: { $0.id == original.id }) { profile = latest; reload() }
            } catch { message = error.localizedDescription }
        }
    }
    private func requestTransfer() {
        pendingProfile = profile; pendingEQ = state.eqDraft(for: profile.id)
        do {
            let current = try state.applyingSessionEQDrafts(to: profile)
            if EQEditorSupport.hasMeaningfulProcessing(current.processing.globalEqualizerIncludingDeviceCorrection) { confirmTransfer = true }
            else { transfer() }
        } catch { message = error.localizedDescription }
    }
    private func transfer() {
        guard let original = pendingProfile else { return }
        let expected = pendingEQ
        pendingProfile = nil; busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                try await state.importReferenceToEqualizer(profile: original, expectedDraft: expected)
                if let latest = state.profiles.profiles.first(where: { $0.id == original.id }) { profile = latest; reload() }
            } catch { message = error.localizedDescription }
        }
    }
}
