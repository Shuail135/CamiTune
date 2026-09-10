import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SpatialMicrophoneCalibrationView: View {
    @ObservedObject var state: AppState
    let context: SpatialCalibrationContext
    let profile: DeviceProfile
    var roomCorrection = false
    @Environment(\.dismiss) private var dismiss
    @State private var microphones = SpatialMicrophoneCapture.microphones
    @State private var microphoneID = ""
    @State private var position: AcousticMeasurementPosition = .listeningPosition
    @State private var measurements: [AcousticPositionMeasurement] = []
    @State private var curve: MicrophoneCalibrationCurve?
    @State private var importing = false
    @State private var task: Task<Void, Never>?
    @State private var status = "Ready"
    @State private var error: String?
    @State private var measuredVolume: SystemVolumeControlSession.Snapshot?
    @State private var externalRecording = false
    @State private var importingRecording = false
    @State private var trimSeconds = 0.0

    private var result: SpatialAcousticProfile? {
        let microphone = externalRecording
            ? MeasurementMicrophone(id: "external-recording", name: "Imported recorder (unverified processing)", isBuiltIn: false)
            : microphones.first(where: { $0.id == microphoneID })
        guard let microphone,
              let measuredVolume, measurements.contains(where: { $0.position == .listeningPosition }) else { return nil }
        return SpatialAcousticProfile(outputDeviceUID: context.outputDeviceUID, processing: profile.processing,
            sampleRate: Int(context.sampleRate), measuredAt: Date(), microphone: microphone,
            microphoneCalibration: curve, positions: measurements, systemVolumeScalar: measuredVolume.scalar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(roomCorrection ? "Speaker room measurement" : "Measure Front Stage").font(.title2.bold())
            Text("Place the microphone at your normal HEAD POSITION, at ear height—not beside the speakers. Keep its position and orientation fixed and the room quiet. Use speakers, not headphones. Two physical-speaker sweeps play at your current volume; start at a comfortable low volume. Do not change volume or EQ during measurement.")
            Text(roomCorrection
                 ? "This measures the current speaker/room/EQ chain. Proposed correction only reduces shared low-frequency peaks; it never boosts room nulls. Unknown microphones receive weaker correction. This is not full-band room inversion or a measurement of seven physical speakers."
                 : "This measures the current output chain, including active EQ. Raw microphone audio stays on this Mac and is discarded after analysis. Unknown and built-in microphones are supported with reduced confidence; no automatic tonal EQ is applied.")
                .font(.caption).foregroundStyle(.secondary)
            if roomCorrection {
                Picker("Measurement method", selection: $externalRecording) {
                    Text("Connected microphone").tag(false)
                    Text("Other device → import recording").tag(true)
                }.pickerStyle(.segmented).disabled(task != nil || measuredVolume != nil)
            }
            if !externalRecording {
            Picker("Microphone", selection: $microphoneID) {
                ForEach(microphones) { Text($0.name).tag($0.id) }
            }.disabled(task != nil || !measurements.isEmpty)
            } else {
                Text("Put the other device's microphone at your head position. Record lossless mono WAV/AIFF, with automatic gain, noise reduction and voice enhancement OFF. Start recording, then press Play sweeps. Transfer that complete recording back to this Mac. Do not use music or a recording from another session.")
                    .font(.caption)
                TextField("Trim leading seconds", value: $trimSeconds, format: .number)
                    .disabled(task != nil)
                Text("Trim only the lead-in: retain at least 0.2 seconds of quiet before the first sweep, and put that sweep within the first 2 seconds. Both sweeps must remain intact. Mono files only; maximum 120 seconds/100 MB, with 16 seconds analyzed after trimming.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Import microphone calibration…") { importing = true }
                    .disabled(task != nil || !measurements.isEmpty)
                Text(curve?.name ?? "No calibration file (optional)").font(.caption)
            }
            Picker("Microphone position", selection: $position) {
                ForEach(AcousticMeasurementPosition.allCases) { Text($0.label).tag($0) }
            }.disabled(task != nil)
            Text("Optional: repeat with the same microphone at each ear position, keeping its orientation and output volume unchanged. Both ear measurements are needed for the four speaker-to-ear paths.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(task == nil ? (externalRecording ? "Play sweeps for recorder" : "Play sweeps and measure") : "Measuring…") {
                    if externalRecording { playForRecorder() } else { measure() }
                }
                    .disabled(task != nil || (!externalRecording && microphoneID.isEmpty))
                if externalRecording {
                    Button("Import recording…") { importingRecording = true }
                        .disabled(task != nil || measuredVolume == nil)
                }
                Text(status).font(.caption)
                if !measurements.isEmpty || measuredVolume != nil {
                    Button("Reset measurements") { measurements = []; measuredVolume = nil; status = "Ready" }
                        .disabled(task != nil)
                }
            }
            ForEach(measurements, id: \.position) { measurement in
                VStack(alignment: .leading, spacing: 3) {
                    Text(measurement.position.label).bold()
                    Text(String(format: "R − L arrival: %.2f ms · level: %.1f dB · coherence L/R: %.0f%% / %.0f%%",
                        measurement.rightMinusLeftArrivalMilliseconds, measurement.rightMinusLeftLevelDB,
                        measurement.left.meanCoherence * 100, measurement.right.meanCoherence * 100))
                    Text(String(format: "Signal/noise L/R: %.0f / %.0f dB · reflected/direct energy: %.2f / %.2f",
                        measurement.left.signalToNoiseDB, measurement.right.signalToNoiseDB,
                        measurement.left.reflectedEnergyRatio, measurement.right.reflectedEnergyRatio))
                    Text("Early reflection L/R: \(reflectionLabel(measurement.left)) / \(reflectionLabel(measurement.right))")
                }.font(.caption)
            }
            if let result { Text("Measurement confidence: \(result.confidence.label)").font(.callout.bold()) }
            if roomCorrection, let result {
                let bands = SpatialRoomCorrection.bands(for: result)
                Text(bands.isEmpty ? "No reliable shared peaks require EQ. You can still save the measurement."
                     : "Proposed room EQ: " + bands.map { String(format: "%.0f Hz: %.1f dB", $0.frequency, $0.gain ?? 0) }.joined(separator: " · "))
                    .font(.caption)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            Divider()
            HStack {
                Button("Cancel") { task?.cancel(); state.endSpatialCalibration(id: context.id); dismiss() }
                Spacer()
                Button(roomCorrection ? "Save measured position" : "Save measured tuning") {
                    if roomCorrection {
                        guard let result, state.acousticVolumeSnapshot == measuredVolume else {
                            error = AcousticMeasurementError.routeChanged.localizedDescription; return
                        }
                        task = Task {
                            let saved = await state.saveRoomCorrection(context: context, measurement: result)
                            task = nil
                            if saved { dismiss() } else { error = "The profile changed or a correction is already present. Reopen measurement and try again." }
                        }
                        return
                    }
                    guard let result, state.acousticVolumeSnapshot == measuredVolume,
                          state.saveAcousticCalibration(context: context, measurement: result) else {
                        error = AcousticMeasurementError.routeChanged.localizedDescription; return
                    }
                    dismiss()
                }.disabled(task != nil || result == nil)
            }
            Text(roomCorrection ? "Saving keeps the measurement with this listening position and adds any proposed room EQ without replacing your own EQ. Remove it before measuring again; corrections never stack. Raw recordings are processed locally and not saved by CamiTune."
                 : "Saving replaces earlier listener tuning. You can then use “Calibrate listening position…” to refine this measured starting point with A/B listening.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 660)
        .onAppear { microphoneID = microphones.first?.id ?? "" }
        .onDisappear { task?.cancel(); state.endSpatialCalibration(id: context.id) }
        .onChange(of: state.spatialCalibrationContext?.id) { id in
            if id != context.id { task?.cancel(); dismiss() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { selection in
            do {
                let url = try selection.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_000_000 else {
                    throw AcousticMeasurementError.invalidCalibrationFile
                }
                curve = try MicrophoneCalibrationCurve.parse(String(contentsOf: url), name: url.lastPathComponent)
            } catch { self.error = error.localizedDescription }
        }
        .fileImporter(isPresented: $importingRecording, allowedContentTypes: [.wav, .aiff]) { selection in
            do { importRecording(try selection.get()) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func playForRecorder() {
        error = nil
        task = Task {
            state.holdSpatialMeasurement(context: context, enabled: true)
            defer { state.holdSpatialMeasurement(context: context, enabled: false); task = nil }
            do {
                guard let volume = state.acousticVolumeSnapshot, !volume.muted, volume.scalar > 0,
                      measuredVolume == nil || measuredVolume == volume else { throw AcousticMeasurementError.routeChanged }
                let sweep = try AcousticSweep(sampleRate: context.sampleRate)
                guard state.playSpatialCalibration(context: context, clip: sweep.clip, tuning: .neutral, completion: {}) else {
                    throw AcousticMeasurementError.routeChanged
                }
                status = "Recording on your other device…"
                for _ in 0..<95 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    guard state.acousticMeasurementIsCurrent(context: context, processing: profile.processing),
                          state.acousticVolumeSnapshot == volume else { throw AcousticMeasurementError.routeChanged }
                }
                measuredVolume = volume
                status = "Stop the recorder, then import its file."
            } catch {
                state.pcmRouter.stopSpatialCalibrationSample(id: context.id)
                if !(error is CancellationError) { self.error = error.localizedDescription }
                status = "Stopped"
            }
        }
    }

    private func importRecording(_ url: URL) {
        task = Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() }; task = nil }
            do {
                guard state.acousticVolumeSnapshot == measuredVolume,
                      state.acousticMeasurementIsCurrent(context: context, processing: profile.processing) else {
                    throw AcousticMeasurementError.routeChanged
                }
                let sweep = try AcousticSweep(sampleRate: context.sampleRate)
                let trim = trimSeconds, selectedPosition = position, calibration = curve
                status = "Analyzing imported recording…"
                let analysis = Task.detached(priority: .utility) {
                    let recording = try SpatialRoomCorrection.readRecording(url: url, trimSeconds: trim)
                    try Task.checkCancellation()
                    return try AcousticSweepAnalyzer().analyze(recording: recording, sweep: sweep,
                        position: selectedPosition, calibration: calibration)
                }
                let measurement = try await withTaskCancellationHandler { try await analysis.value }
                    onCancel: { analysis.cancel() }
                try Task.checkCancellation()
                guard state.acousticMeasurementIsCurrent(context: context, processing: profile.processing),
                      state.acousticVolumeSnapshot == measuredVolume else { throw AcousticMeasurementError.routeChanged }
                measurements.removeAll { $0.position == selectedPosition }
                measurements.append(measurement)
                status = "Imported measurement complete"
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                status = "Import failed — check mono format and leading trim."
            }
        }
    }

    private func measure() {
        error = nil
        task = Task {
            let recorder = SpatialMicrophoneCapture()
            state.holdSpatialMeasurement(context: context, enabled: true)
            defer { state.holdSpatialMeasurement(context: context, enabled: false); task = nil }
            do {
                guard let volume = state.acousticVolumeSnapshot, !volume.muted, volume.scalar > 0,
                      measuredVolume == nil || measuredVolume == volume else {
                    throw AcousticMeasurementError.routeChanged
                }
                status = "Requesting microphone…"
                try await recorder.start(id: microphoneID)
                try Task.checkCancellation()
                let sweep = try AcousticSweep(sampleRate: context.sampleRate)
                try await Task.sleep(nanoseconds: 300_000_000)
                guard state.acousticMeasurementIsCurrent(context: context, processing: profile.processing),
                      state.acousticVolumeSnapshot == volume,
                      state.playSpatialCalibration(context: context, clip: sweep.clip, tuning: .neutral, completion: {}) else {
                    throw AcousticMeasurementError.routeChanged
                }
                status = "Recording left and right sweeps…"
                // Bounded wait also catches a stalled playback worker: analysis rejects missing sweeps.
                for _ in 0..<95 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    guard state.acousticMeasurementIsCurrent(context: context, processing: profile.processing),
                          state.acousticVolumeSnapshot == volume else { throw AcousticMeasurementError.routeChanged }
                }
                let recording = await recorder.stop()
                try Task.checkCancellation()
                status = "Analyzing response…"
                let measuredPosition = position
                let calibration = curve
                let analysis = Task.detached(priority: .utility) {
                    try AcousticSweepAnalyzer().analyze(recording: recording, sweep: sweep,
                        position: measuredPosition, calibration: calibration)
                }
                let measurement = try await withTaskCancellationHandler {
                    try await analysis.value
                } onCancel: { analysis.cancel() }
                try Task.checkCancellation()
                measurements.removeAll { $0.position == measuredPosition }
                measurements.append(measurement)
                measuredVolume = volume
                status = "Measurement complete"
            } catch {
                _ = await recorder.stop()
                state.pcmRouter.stopSpatialCalibrationSample(id: context.id)
                status = "Stopped"
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    private func reflectionLabel(_ response: AcousticSpeakerResponse) -> String {
        response.earlyReflectionDelayMilliseconds.map { String(format: "%.1f ms", $0) } ?? "not detected"
    }
}
