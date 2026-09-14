import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ConvolutionEditorView: View {
    let state: AppState
    @Binding var profile: DeviceProfile

    @State private var convolution: ConvolutionProcessor?
    @State private var isEnabled = false
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var suppressChanges = false
    @State private var loadedProfileID: UUID?

    private var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("FIR / Convolution").font(.title3.bold())
                    Spacer()
                    if convolution != nil {
                        Toggle("Enable", isOn: Binding(
                            get: { isEnabled },
                            set: { value in
                                isEnabled = value
                                commit()
                            }
                        ))
                        .toggleStyle(.switch)
                    }
                }

                Text("Apply a WAV impulse response after EQ and before the limiter. Imported files are copied into CamiTune so processing remains available after the original file is moved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let convolution {
                    let asset = convolution.asset
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "waveform.path")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(asset.displayName).font(.headline)
                            Text("\(asset.sampleRate) Hz · \(asset.frameCount) taps · \(asset.channelCount) \(asset.channelCount == 1 ? "channel" : "channels")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let maximum = asset.maximumMagnitudeDB(
                                forChannel: convolution.impulseChannel
                            ) {
                                Text("Measured maximum: \(maximum, format: .number.precision(.fractionLength(2))) dB")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Replace WAV…") { showImporter = true }
                            .disabled(isImporting)
                        Button("Remove", role: .destructive) {
                            self.convolution = nil
                            isEnabled = false
                            commit()
                        }
                    }

                    if asset.channelCount > 1 {
                        HStack {
                            Text("Impulse channel")
                            Picker("Impulse channel", selection: Binding(
                                get: { self.convolution?.impulseChannel ?? 0 },
                                set: { channel in
                                    self.convolution?.impulseChannel = channel
                                    commit()
                                }
                            )) {
                                ForEach(0..<asset.channelCount, id: \.self) { channel in
                                    Text("Channel \(channel + 1)").tag(channel)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                    }

                    if asset.sampleRate != profile.sampleRate {
                        Label(
                            "This WAV does not match the profile's \(profile.sampleRate) Hz processing rate. Replace it before activation.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } else {
                    Button("Import Impulse Response…") { showImporter = true }
                        .disabled(isImporting)
                    if isImporting {
                        ProgressView("Analyzing impulse response…")
                            .controlSize(.small)
                    }
                }
            }
            .padding(6)
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: profile.id) { _ in
            loadedProfileID = nil
            loadIfNeeded()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.wav],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                importImpulseResponse(url)
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private func loadIfNeeded() {
        guard loadedProfileID != profile.id else { return }
        load()
    }

    private func load() {
        suppressChanges = true
        let saved = profile.processing.convolution
        convolution = saved?.processor
        isEnabled = saved?.isEnabled ?? false
        loadedProfileID = profile.id
        DispatchQueue.main.async { suppressChanges = false }
    }

    private func commit() {
        guard !suppressChanges else { return }
        profile.processing.setConvolution(convolution, enabled: isEnabled)
        guard profileIsActive else { return }
        let updated = profile
        Task { await state.apply(profile: updated) }
    }

    private func importImpulseResponse(_ url: URL) {
        let importedProfileID = profile.id
        let expectedSampleRate = profile.sampleRate
        isImporting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try ImpulseResponseStore().importWAV(
                        at: url,
                        expectedSampleRate: expectedSampleRate
                    )
                }
            }.value
            isImporting = false
            guard profile.id == importedProfileID else { return }
            switch result {
            case .success(let asset):
                convolution = ConvolutionProcessor(asset: asset)
                isEnabled = true
                commit()
                state.clearTransientError()
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
    }
}
