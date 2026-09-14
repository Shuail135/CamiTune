import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ReferenceCorrectionView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    @State private var draft: DeviceCorrectionProfile?
    @State private var snapshot: DeviceProfile?
    @State private var showingCorrection = false
    @State private var importing = false
    @State private var confirmTransfer = false
    @State private var pendingProfile: DeviceProfile?
    @State private var pendingEQ: String?
    @State private var busy = false
    @State private var message: String?
    @State private var headroom: Double?

    private var dirty: Bool { draft != snapshot?.processing.deviceCorrection }
    private var headphones: Bool { profile.effectiveEndpointKind == .headphones }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    Button("Clear") { commit(nil) }
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
                        Button("Discard Edits") { reload() }
                    }
                    Button("Import to Equalizer") { requestTransfer() }.disabled(dirty)
                        .help("Replace User Equalizer bands and remove this correction after a successful save.")
                }.buttonStyle(.bordered)
                if dirty { Text("Save your correction edits before transferring to Equalizer.").font(.caption).foregroundStyle(.secondary) }
            }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .disabled(busy || state.isSavingProfileSettings || state.transitionInProgress)
        .onAppear { reload() }
        .onChange(of: profile.id) { _ in reload() }
        .onChange(of: profile) { _ in if !dirty { reload() } }
        .task(id: draft) {
            guard let draft else { headroom = nil; return }
            var candidate = (try? state.applyingSessionEQDrafts(to: profile)) ?? profile
            candidate.processing.setDeviceCorrection(draft)
            let renderCandidate = candidate
            let result = await Task.detached(priority: .utility) {
                try? ProcessingGraphBuilder(channelCount: renderCandidate.processingChannelCount).build(profile: renderCandidate).automaticHeadroomDB
            }.value
            guard !Task.isCancelled else { return }
            headroom = result
        }
        .sheet(isPresented: $showingCorrection) {
            DeviceCorrectionEditorView(existing: draft?.importedAPOText == false ? draft : nil,
                sampleRate: Double(profile.sampleRate), referenceEndpoint: profile.effectiveEndpointKind,
                automaticHeadroom: { filters in
                    var candidate = (try? state.applyingSessionEQDrafts(to: profile)) ?? profile
                    var correction = draft ?? DeviceCorrectionProfile(deviceName: "Correction", policy: .recommended,
                        measurement: .flat(), target: .flat(), curve: CorrectionCurve(points: []), filters: [], preampDB: 0)
                    correction.filters = filters
                    candidate.processing.setDeviceCorrection(correction)
                    return (try? ProcessingGraphBuilder(channelCount: candidate.processingChannelCount).build(profile: candidate).automaticHeadroomDB) ?? 0
                }, shouldConfirmReplacement: { false }, onCancel: { showingCorrection = false },
                onLoad: { correction in showingCorrection = false; draft = correction; commit(correction) })
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                importText(try String(contentsOf: url, encoding: .utf8), name: url.lastPathComponent)
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
        snapshot = profile; draft = profile.processing.deviceCorrection; message = nil
    }
    private func importText(_ text: String, name: String) {
        do {
            let correction = try ReferenceCorrection.importText(text, name: name)
            draft = correction; commit(correction)
        } catch { message = error.localizedDescription }
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
            if EQEditorSupport.hasMeaningfulProcessing(current.processing.globalEqualizer) { confirmTransfer = true }
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
