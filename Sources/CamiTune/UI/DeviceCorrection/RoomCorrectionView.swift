import CamiTuneAudio
import CamiTuneDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct RoomCorrectionView: View {
    let state: AppState
    @Binding var profile: DeviceProfile
    var isVisible = true
    @StateObject private var editor: RoomCorrectionEditorState
    @State private var importPanel: NSOpenPanel?
    @State private var adjusting = false
    @State private var mapZoom: CGFloat = 1
    @State private var mapViewportRevision = 0
    @State private var confirmReset = false
    @State private var correctionDetailsExpanded = false
    @State private var analysisLoading = false
    @State private var replacementMessage: String?
    @State private var confirmReplacement = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var saved: SpatialSeatingCalibration? { profile.effectiveSpatialSettings.seating }
    private var stepIndex: Int { RoomCorrectionEditorState.Tab.allCases.firstIndex(of: editor.tab) ?? 0 }
    init(state: AppState, profile: Binding<DeviceProfile>, isVisible: Bool = true,
         editor: RoomCorrectionEditorState? = nil) {
        self.state = state; self._profile = profile; self.isVisible = isVisible
        self._editor = StateObject(wrappedValue: editor ?? RoomCorrectionEditorState())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Room Correction(Beta)").font(.title3.bold())
                DeviceCorrectionHelpIcon(title: "Room correction",
                    message: "Measure the speaker response at your listening positions, review the graphs, then calculate and import the filters. Import replaces the channel EQ and FIR slots.")
                Spacer()
            }
            tabs
            if editor.source.kind == .recorder && editor.session != nil { simpleModeGuide }
            SelectedEditorPageLayout(selection: stepIndex) {
                step(.measure) {
                    VStack(alignment: .leading, spacing: 12) {
                        if editor.session == nil { recordingSelection }
                        if editor.measurementOpen && editor.profileIsActive { measure }
                    }
                }
                step(.analysis) { RoomCorrectionAnalysisView(editor: editor, loadingChanged: { analysisLoading = $0 }) }
                step(.correction) { correction }
            }.clipped()
            if !editor.busy && showsStatus {
                Text(editor.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .uiInteractionAnchor("room-workflow-guidance")
            }
            if editor.isVerifying {
                if editor.tab == .measure {
                    Text(editor.verificationMessage).font(.caption).foregroundStyle(.secondary)
                }
                Button("Back to correction") { editor.endVerification() }.disabled(editor.busy)
            }
            if let error = editor.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            navigation
        }
        .onAppear { editor.load(profile: profile, app: state); editor.normalizeCorrectionSettings() }
        .onChange(of: editor.source.kind) { _ in editor.normalizeCorrectionSettings() }
        .onDisappear { importPanel?.cancel(nil); editor.close() }
        .onChange(of: saved?.id) { _ in editor.selectSeat(profile: profile, app: state) }
        .onChange(of: saved?.roomCorrectionRevision) { _ in editor.selectSeat(profile: profile, app: state) }
        .onChange(of: isVisible) { visible in
            if !visible { importPanel?.cancel(nil); editor.endCompare(); editor.pauseMeasurement() }
        }
        .onChange(of: editor.tab) { tab in
            if tab != .correction { editor.endCompare() }
            if tab != .measure { editor.pauseMeasurement() }
        }
        .onChange(of: editor.calculationRevision) { _ in correctionDetailsExpanded = true }
        .onChange(of: editor.importRevision) { _ in correctionDetailsExpanded = false }
        .onChange(of: editor.session?.id) { _ in adjusting = false; mapZoom = 1; mapViewportRevision += 1 }
        .alert("Reset Room Correction?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                guard !editor.busy else { return }
                NSApp.keyWindow?.makeFirstResponder(nil)
                adjusting = false; mapZoom = 1; mapViewportRevision += 1
                editor.reset(profile: profile)
            }
        } message: {
            Text("This clears room correction and starts a new measurement setup for this listening position. Imported EQ and FIR filters remain in their channel editors.")
        }
        .alert("Replace Existing Filters?", isPresented: $confirmReplacement) {
            Button("Cancel", role: .cancel) { replacementMessage = nil }
            Button("Replace and Import", role: .destructive) {
                editor.importCorrection(profile: profile)
                replacementMessage = nil
            }
        } message: { Text(replacementMessage ?? "") }
    }

    private var showsStatus: Bool {
        editor.tab == .measure && !editor.status.isEmpty
            && !["Room Correction ON", "Room Correction OFF", "Measurements ready"].contains(editor.status)
    }

    private var importedRecording: RoomRecordingReference? {
        guard editor.session?.source.kind == .recorder else { return nil }
        return editor.session?.recordings.last
    }

    private var hasImportedAnalysis: Bool { importedRecording != nil && editor.hasMeasurements }

    private enum SimpleGuideStep: Int, CaseIterable {
        case volumeCheck = 1, record, importRecording, review, apply

        var title: String {
            switch self {
            case .volumeCheck: return "Volume Check"
            case .record: return "Record"
            case .importRecording: return "Import recording"
            case .review: return "Review"
            case .apply: return "Apply"
            }
        }
    }

    private var simpleGuideStep: SimpleGuideStep {
        if editor.importingRecording { return .importRecording }
        if importedRecording != nil {
            return editor.tab == .correction && editor.hasMeasurements ? .apply : .review
        }
        if editor.measuring { return .record }
        if editor.recorderPlaybackComplete { return .importRecording }
        return editor.recorderNeedsPreparation ? .volumeCheck : .record
    }

    private var simpleGuideInstruction: String {
        switch simpleGuideStep {
        case .volumeCheck:
            return "Use a decibel meter or phone app.\nPlay Test Sound and adjust Test volume until the meter reads about 20–30 dB above the room’s background level.\nTry to keep your room as quite as possible."
        case .record:
            if editor.measuring {
                return "Try Keep your phone still"
            }
            if editor.session?.blocks.isEmpty != false {
                return "Choose how many positions to record. More positions can improve accuracy across your listening area.\nPlace your phone upside down at the graph’s blue marker, with its microphone at ear level. Press Record in your recorder, then Play Sound here."
            }
            return "Keep the same recording running. Move your phone to the next blue marker, with its microphone at ear level, then press \(editor.recorderActionTitle). Keep it still while sound plays."
        case .importRecording:
            if editor.importingRecording {
                return "Analyzing your recording. The graphs will appear in Analysis when it finishes."
            }
            return "After all positions finish, stop recording and choose Import Recording… in Measure."
        case .review:
            if !editor.hasMeasurements {
                return "No usable measurements were found. Remove the imported file to choose another recording, or reset room correction to record again."
            }
            return "Analysis section here. Press next to calculate correction."
        case .apply:
            if let result = saved?.roomCorrectionResult,
               editor.calculatedResult?.generatedAt == result.generatedAt,
               editor.settings == result.settings, editor.verificationIsCurrent(profile: profile) {
                return "Correction imported. The filters are now in the channel processing and/or FIR."
            }
            if editor.canImport {
                return "Review the calculated filters under Calculation, then choose Import to apply them. Import replaces the channel processing and/or FIR."
            }
            return "Press calculate. Review Calculation, then choose Import to apply the filters. Import replaces the channel processing andor FIR."
        }
    }

    private var simpleModeGuide: some View {
        let current = simpleGuideStep
        return GroupBox {
            WrappingControlLayout(horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(SimpleGuideStep.allCases, id: \.self) { step in
                    HStack(spacing: 4) {
                        Image(systemName: "\(step.rawValue).circle\(step == current ? ".fill" : "")")
                            .accessibilityHidden(true)
                        Text(step.title)
                    }
                    .font(.caption.weight(step == current ? .semibold : .regular))
                    .foregroundStyle(step == current ? Color.blue : Color.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(step.rawValue): \(step.title)")
                    .accessibilityValue(step == current ? "Current step" : "")
                }
            }
            Text(simpleGuideInstruction)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Text("Simple mode guide")
        }
        .groupBoxStyle(DeviceCorrectionCardStyle(background: .white.opacity(colorScheme == .dark ? 0.10 : 0.65)))
        .uiInteractionAnchor("room-simple-mode-guide")
    }

    private func calculateCorrection() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        editor.create(profile: profile)
    }

    @ViewBuilder private var recordingControls: some View {
        if let recording = importedRecording {
            HStack(spacing: 6) {
                Text(recording.originalFileName ?? recording.fileName)
                    .lineLimit(1).truncationMode(.middle)
                    .uiInteractionAnchor("room-imported-recording")
                Button { editor.removeImportedRecording() } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove recording")
                .uiInteractionAnchor("room-recording-remove")
            }
            .disabled(editor.busy)
        }
    }

    private enum ImportKind { case recording, calibration }
    private func chooseFile(_ kind: ImportKind) {
        guard !editor.busy, !editor.isVerifying, importPanel == nil else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSOpenPanel()
        panel.title = kind == .recording ? "Import Recording" : "Choose Microphone Calibration"
        panel.prompt = kind == .recording ? "Import" : "Choose"
        panel.allowedContentTypes = kind == .recording ? [.audio] : [.plainText, .data]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        let sessionID = editor.session?.id
        importPanel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            importPanel = nil
            guard response == .OK, let url = panel.url, editor.session?.id == sessionID else { return }
            if kind == .recording { editor.importRecording(url); return }
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 1_000_000 else { throw AcousticMeasurementError.invalidCalibrationFile }
                editor.setCalibration(try .parse(String(contentsOf: url), name: url.lastPathComponent))
            } catch { editor.error = error.localizedDescription }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func select(_ tab: RoomCorrectionEditorState.Tab) {
        guard editor.tab != tab else { return }
        TextFocusClearRequest.commitBeforeChangingSelection { editor.tab = tab }
    }
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(RoomCorrectionEditorState.Tab.allCases, id: \.self) { tab in
                Button { select(tab) } label: {
                    Text(tab.rawValue.capitalized)
                        .font(.callout.weight(editor.tab == tab ? .semibold : .regular))
                        .foregroundStyle(editor.tab == tab ? Color.blue : Color.secondary)
                        .lineLimit(1)
                        .padding(.vertical, 10).frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(tab == .analysis && !editor.hasMeasurements)
                .accessibilityLabel(tab.rawValue.capitalized)
                .accessibilityAddTraits(editor.tab == tab ? .isSelected : [])
                .uiInteractionAnchor("room-correction-tab-\(tab.rawValue)")
                .accessibilityIdentifier("room-correction-tab-\(tab.rawValue)")
            }
        }
        .frame(maxWidth: 480)
        .background(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geometry in
                let width = geometry.size.width / CGFloat(RoomCorrectionEditorState.Tab.allCases.count)
                Capsule().fill(Color.blue)
                    .frame(width: width, height: 2)
                    .offset(x: CGFloat(stepIndex) * width)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stepIndex)
            }.frame(height: 2).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    private func step<Content: View>(_ tab: RoomCorrectionEditorState.Tab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(2)
            .opacity(editor.tab == tab ? 1 : 0)
            .allowsHitTesting(editor.tab == tab)
            .accessibilityHidden(editor.tab != tab)
            // Keep native controls stationary and retained. Only the tab
            // underline animates; sliding the editors redraws both graphs and
            // repeatedly moves AppKit controls during the height change.
            .transaction { $0.animation = nil }
    }
    private var navigation: some View {
        HStack {
            SectionResetButton("Reset Room Correction") {
                NSApp.keyWindow?.makeFirstResponder(nil)
                confirmReset = true
            }
            .disabled(editor.busy)
            .uiInteractionAnchor("room-correction-reset")
            if editor.tab == .measure && !editor.measurementOpen && !editor.profileIsActive {
                Label(editor.session == nil ? "Activate profile to start measurement" : "Activate profile to continue measurement",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .uiInteractionAnchor("room-measurement-activation-hint")
            }
            Spacer(minLength: 12)
            if editor.busy || (editor.tab == .analysis && analysisLoading) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(editor.busy ? editor.status : "Updating analysis…").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .uiInteractionAnchor("room-measurement-status")
            }
            if editor.busy && !editor.testingSound && !editor.measuring && !editor.importingRecording {
                Button("Cancel") { editor.cancel() }
                    .uiInteractionAnchor("room-operation-cancel")
            }
            if editor.tab == .measure && editor.measurementOpen && importedRecording != nil { recordingControls }
            if editor.tab != .measure && !hasImportedAnalysis && !editor.measuring && !editor.importingRecording {
                Button("Re-measure") { select(.measure) }
                    .disabled(editor.busy)
                    .uiInteractionAnchor("room-correction-remeasure")
            }
            if editor.tab == .measure && editor.measurementOpen && editor.recorderNeedsPreparation {
                Button("Continue") { editor.confirmRecorderPreparation() }
                .buttonStyle(.borderedProminent).disabled(editor.busy)
                .uiInteractionAnchor("room-prepare-confirm")
                .accessibilityIdentifier("room-prepare-confirm")
            } else if editor.importingRecording || ((editor.tab == .measure && editor.measurementOpen || editor.measuring)
                && editor.source.kind == .recorder && importedRecording == nil) {
                if editor.session?.blocks.isEmpty == true && !editor.measuring {
                    Button("Back to Volume Check") { editor.reviewRecorderPreparation() }
                        .disabled(editor.busy).uiInteractionAnchor("room-prepare-back")
                }
                if editor.tab == .measure && editor.recorderPlaybackComplete && !editor.busy {
                    Button("Play Again") { editor.measure(profile: profile, selectedChannel: nil) }
                        .uiInteractionAnchor("room-recorder-replay")
                }
                Button(editor.recorderActionTitle) {
                    if editor.measuring || editor.importingRecording { editor.cancel() }
                    else if editor.recorderPlaybackComplete { chooseFile(.recording) }
                    else { editor.measure(profile: profile, selectedChannel: nil) }
                }
                .buttonStyle(.borderedProminent).disabled(editor.busy && !editor.measuring && !editor.importingRecording)
                .uiInteractionAnchor("room-recorder-next").accessibilityIdentifier("room-recorder-next")
                DeviceCorrectionHelpIcon(title: "Simple recording",
                    message: "1. Start your phone’s recorder and place the phone at the blue marker on the graph before pressing Play Sound. \n 2. Keep it still at ear level while sound plays. \n 3. Between positions, keep recording, move to the next marker, then press Next. \n 4. To repeat a finished position, select its number and press Play Again while the same phone recording is still running. \n 5. Stop only after all positions are finished, then import that single audio file.")
            } else if editor.tab == .correction && !editor.measuring {
                Button(editor.calculatedResult == nil ? "Calculate" : "Recalculate") {
                    calculateCorrection()
                }
                .disabled(!editor.canCalculate)
                .uiInteractionAnchor("room-correction-create")
                .accessibilityIdentifier("room-correction-create")
                if editor.canVerify(profile: profile) {
                    Button("Verify Applied Response") { editor.startVerification(profile: profile) }
                }
                Button("Import") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    do {
                        if let message = try editor.replacementMessage(profile: profile) {
                            replacementMessage = message; confirmReplacement = true
                        } else { editor.importCorrection(profile: profile) }
                    } catch { editor.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!editor.canImport)
                .uiInteractionAnchor("room-correction-import")
                .accessibilityIdentifier("room-correction-import")
            } else if editor.tab == .measure && !editor.measurementOpen {
                Button(editor.measurementActionTitle) { editor.openMeasurement(profile: profile) }
                    .buttonStyle(.borderedProminent)
                    .disabled(editor.busy || !editor.profileIsActive)
                    .uiInteractionAnchor("room-correction-start").accessibilityIdentifier("room-correction-start")
            } else if (editor.tab == .measure || editor.measuring) && editor.source.kind == .microphone {
                if editor.session?.microphoneMeasurementsComplete == true && !editor.measuring {
                    microphoneMeasureButton
                    Button("Next") { select(.analysis) }
                        .buttonStyle(.borderedProminent).disabled(editor.busy)
                        .uiInteractionAnchor("room-correction-next")
                } else { microphoneMeasureButton.buttonStyle(.borderedProminent) }
            } else {
                Button("Next") { select(editor.tab == .measure ? .analysis : .correction) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.hasMeasurements || editor.busy)
                    .uiInteractionAnchor("room-correction-next")
                    .accessibilityIdentifier("room-correction-next")
            }
        }
    }
    private var microphoneMeasureButton: some View {
        Button(editor.microphoneActionTitle) {
            if editor.measuring { editor.cancel(); return }
            TextFocusClearRequest.commitBeforeChangingSelection {
                guard !editor.busy else { return }
                adjusting = false
                editor.measure(profile: profile, selectedChannel: nil)
            }
        }
        .disabled(!editor.measuring && (editor.busy || !editor.microphoneIsConfigured))
        .uiInteractionAnchor("room-microphone-measure")
    }
    private var recordingSelection: some View {
        Picker("Recording", selection: Binding(get: { editor.source.kind }, set: { editor.setSourceKind($0, profile: profile) })) {
            Text("Simple (Phone or Uncalibrated Microphone)").tag(RoomMeasurementSource.Kind.recorder)
            Text("Microphone with Calibration").tag(RoomMeasurementSource.Kind.microphone)
        }.pickerStyle(.radioGroup).disabled(editor.busy || editor.isVerifying).uiInteractionAnchor("room-recording-type")
    }
    private var measure: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.source.kind == .microphone {
                HStack {
                    RoomCorrectionMenu(label: "Microphone", selection: Binding(get: { editor.source.deviceID }, set: { editor.setMicrophone($0) }),
                        options: microphoneOptions,
                        title: { id in
                            guard let id else { return "Choose microphone" }
                            return editor.microphones.first { $0.id == id }?.name ?? "\(editor.source.deviceName) (not connected)"
                        })
                        .frame(width: 280, alignment: .leading).disabled(editor.busy || editor.isVerifying || editor.hasMicrophoneCaptures)
                        .uiInteractionAnchor("room-microphone-selection")
                    Button { editor.refreshMicrophones() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                    }
                        .buttonStyle(.borderless)
                        .disabled(editor.busy).accessibilityLabel("Refresh microphones")
                }
                HStack {
                    Text("Calibration")
                    Text(editor.source.calibration?.name ?? "Choose the calibration file")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        .uiInteractionAnchor("room-calibration-name")
                    Button(editor.source.calibration == nil ? "Choose…" : "Change…") { chooseFile(.calibration) }
                        .uiInteractionAnchor("room-calibration-import").disabled(editor.busy || editor.isVerifying)
                    DeviceCorrectionHelpIcon(title: "Microphone calibration",
                        message: "Use the calibration file for this microphone and input channel. Match its orientation to the file. Use a stand, keep the room quiet, and disable input gain automation and voice/noise processing.")
                }
            }
            if editor.session != nil && (editor.source.kind == .microphone || editor.recorderNeedsPreparation) {
                testSoundControls
            }
            if !editor.recorderNeedsPreparation { measurementPositions }
        }
    }

    private var testSoundControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Test volume")
                SteppedValueSlider(value: Binding(get: { editor.testVolumeDB }, set: { editor.setTestVolumeDB($0) }),
                    in: editor.testVolumeRangeDB, step: 1, style: .preamp)
                    .frame(width: 160).accessibilityLabel("Test volume")
                    .uiInteractionAnchor("room-test-volume")
                    .disabled(editor.busy && !editor.testingSound)
                Text(String(format: "%+.0f dB", editor.testVolumeDB)).monospacedDigit().frame(width: 55, alignment: .trailing)
                Button {
                    if editor.testingSound { editor.cancel() }
                    else { editor.measure(profile: profile, selectedChannel: nil, preview: true) }
                } label: {
                    Image(systemName: editor.testingSound ? "stop.fill" : "speaker.wave.2")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(editor.busy && !editor.testingSound)
                .uiInteractionAnchor("room-test-sound")
                .accessibilityLabel(editor.testingSound ? "Stop Sound" : "Test Sound")
                DeviceCorrectionHelpIcon(title: "Test sound",
                    message: "Volume should aim for roughly 20–30 dB above background noise. "
                        + (editor.source.kind == .microphone
                            ? "dBFS shows microphone recording level. Leave at least 6 dB of input peak headroom."
                            : "Use a decibel meter app if you do not have a physical meter."))
            }
            if editor.source.kind == .microphone, let level = editor.microphoneLevel, editor.busy {
                HStack {
                    Text(String(format: "Microphone · peak %.1f dBFS · RMS %.1f dBFS", level.peakDBFS, level.rmsDBFS)).monospacedDigit()
                    Text(level.clipped ? "Clipping — lower the level" : level.peakDBFS > -6 ? "Leave more headroom" : "")
                        .foregroundStyle(level.clipped ? Color.red : Color.orange)
                }.font(.caption).uiInteractionAnchor("room-microphone-level")
            }
        }
    }

    private var measurementPositions: some View {
        VStack(alignment: .leading, spacing: 12) {
            positionCountControl(microphone: editor.source.kind == .microphone)
            if let session = editor.session, let position = editor.position {
                positionNavigation(session)
                SpeakerRoomCanvas(topology: session.context.topology, listener: session.context.listener, selected: nil, playing: editor.playingOutput,
                    extent: 3, locked: true, listeningOnly: true, select: { _ in }, audition: { _ in }, moveSpeaker: { _, _ in },
                    moveListener: { _ in }, assignRole: { _, _ in }, measurementPoint: position.coordinate,
                    measurementRadius: 0,
                    allowsScrollPanning: false, fitsAllContent: true, viewportPoints: session.positions.map(\.coordinate),
                    viewportResetRevision: mapViewportRevision,
                    zoom: mapZoom, zoomChanged: { mapZoom = $0 })
                    .frame(height: 300).uiInteractionAnchor("room-measurement-map")
                HStack(spacing: 8) {
                    Text(session.source.kind == .recorder ? "Microphone · at ear level"
                        : "Microphone · \(microphoneHeightDescription(position, in: session))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    SpeakerMapZoomControls(zoom: $mapZoom, anchorPrefix: "room-map")
                }.controlSize(.small)
                if session.source.kind == .microphone {
                    if position.skipped {
                        Text("Skipped · measure again to include.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    microphonePositionEditor(position).id(position.id)
                }
            }
        }
    }

    private var microphoneOptions: [String?] {
        var ids = editor.microphones.map(\.id)
        if let selected = editor.source.deviceID, !ids.contains(selected) { ids.append(selected) }
        return [nil] + ids.map(Optional.some)
    }

    private func microphoneHeightDescription(_ position: RoomMeasurementPosition, in session: RoomMeasurementSession) -> String {
        let centimetres = ((position.coordinate.z - session.context.listener.z) * 100).rounded()
        if centimetres == 0 { return "at ear level" }
        return "\(String(format: "%.0f", abs(centimetres))) cm \(centimetres > 0 ? "above" : "below") ear level"
    }

    @ViewBuilder private func microphonePositionEditor(_ position: RoomMeasurementPosition) -> some View {
        if !position.isMain {
            DisclosureGroup(isExpanded: Binding(get: { adjusting }, set: { expanded in
                TextFocusClearRequest.commitBeforeChangingSelection {
                    guard !editor.busy, editor.position?.id == position.id else { return }
                    adjusting = expanded
                    if !expanded { editor.persistSession() }
                }
            })) {
                VStack(alignment: .leading, spacing: 8) {
                    if !position.observations.isEmpty || editor.session?.blocks.contains(where: { $0.positionID == position.id }) == true {
                        Text("Moving this position requires a new measurement.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 8) {
                            coordinateField("Left / right (cm)", axis: \.x)
                            coordinateField("Front / back (cm)", axis: \.y)
                            coordinateField("Height (cm)", axis: \.z)
                        }
                        DeviceCorrectionHelpIcon(title: "Measurement position",
                            message: "Place the microphone at the blue marker. Offsets are in cm from the main listening position."
                                + "\n\nNegative values mean left, back or below ear level; positive values mean right, forward or above."
                                + "\n\nKeep at least 3 positions, including the fixed main position.")
                    }.fixedSize(horizontal: true, vertical: false)
                }.padding(.leading, 16)
            } label: {
                Text("Adjust Position \(editor.positionIndex + 1)")
                    .uiInteractionAnchor("room-position-adjust")
            }
            .disclosureGroupStyle(SectionDisclosureStyle())
            .disabled(editor.busy)
            .uiInteractionAnchor("room-position-editing")
        }
    }

    private func positionCountControl(microphone: Bool) -> some View {
        HStack(spacing: 10) {
            Text("Positions")
            if let session = editor.session, RoomRecorderPositionCount(rawValue: session.positions.count) == nil
                || (microphone && editor.hasMicrophoneCaptures) || (!microphone && !session.recordings.isEmpty) {
                Text("\(session.positions.count) positions").foregroundStyle(.secondary)
                    .uiInteractionAnchor("room-position-count-fixed")
            } else {
                JoinedSegmentedControl(options: RoomRecorderPositionCount.allCases,
                    selection: Binding(get: { microphone ? editor.microphonePositionCount : editor.recorderPositionCount }, set: {
                        if microphone { editor.setMicrophonePositionCount($0, profile: profile) }
                        else { editor.setRecorderPositionCount($0, profile: profile) }
                    }), title: { "\($0.rawValue) positions" })
                    .frame(width: 180).disabled(editor.busy)
                    .accessibilityLabel("Number of recording positions")
                    .uiInteractionAnchor(microphone ? "room-microphone-position-count" : "room-recorder-position-count")
            }
        }
    }

    private func positionStatus(_ position: RoomMeasurementPosition, in session: RoomMeasurementSession) -> String {
        if position.skipped { return "Skipped" }
        if session.source.kind == .microphone {
            if session.microphonePositionIsComplete(position) { return "Ready" }
            let count = session.measuredMicrophoneChannels(at: position).count
            return position.observations.isEmpty ? "Not measured" : "\(count)/\(session.context.topology.endpoints.count) speakers ready"
        }
        if !position.observations.isEmpty || !session.recordings.isEmpty {
            let expected = Set(session.context.topology.endpoints.map { $0.id.channelIndex })
            let measured = Set(position.observations.filter(\.hasUsableMagnitude).map(\.channel)).intersection(expected)
            return !expected.isEmpty && measured == expected ? "Analyzed" : "\(measured.count)/\(expected.count) speakers analyzed"
        }
        return editor.hasPlayed(position, in: session) ? "Sound played" : "Not measured"
    }

    private func positionNavigation(_ session: RoomMeasurementSession) -> some View {
        HStack(spacing: 10) {
            Text("Position").foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.positions.indices, id: \.self) { index in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                            positionButton(index, in: session).id(index)
                        }
                    }.padding(2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .scrollBounceWhenNeeded(axes: .horizontal)
                .onChange(of: editor.positionIndex) { index in proxy.scrollTo(index, anchor: .center) }
                .onChange(of: session.positions.count) { _ in proxy.scrollTo(editor.positionIndex, anchor: .center) }
                .onAppear { proxy.scrollTo(editor.positionIndex, anchor: .center) }
            }
            if let position = editor.position,
               position.skipped || ((!position.observations.isEmpty || !session.recordings.isEmpty)
                   && positionStatus(position, in: session) != "Ready") {
                Text(positionStatus(position, in: session))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .uiInteractionAnchor("room-position-readiness")
            }
            if session.source.kind == .microphone {
                Button {
                    let positionID = editor.position?.id
                    TextFocusClearRequest.commitBeforeChangingSelection {
                        guard editor.position?.id == positionID, editor.canRemovePosition else { return }
                        adjusting = false
                        editor.removePosition()
                    }
                } label: {
                    Image(systemName: "minus.circle").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove Position \(editor.positionIndex + 1)")
                .fixedSize().disabled(!editor.canRemovePosition)
                .uiInteractionAnchor("room-position-remove")
                Button {
                    TextFocusClearRequest.commitBeforeChangingSelection {
                        guard !editor.busy else { return }
                        let previousID = editor.position?.id
                        editor.addPosition(profile: profile)
                        if editor.position?.id != previousID { adjusting = true }
                    }
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless).accessibilityLabel("Add Position")
                .fixedSize().disabled(session.positions.count >= 32)
                .uiInteractionAnchor("room-position-add")
            }
        }
        .controlSize(.small).disabled(editor.busy)
        .accessibilityElement(children: .contain).accessibilityLabel("Measurement positions")
        .uiInteractionAnchor("room-position-navigation")
    }

    private func positionButton(_ index: Int, in session: RoomMeasurementSession) -> some View {
        let position = session.positions[index]
        let selected = editor.positionIndex == index
        let status = positionStatus(position, in: session)
        return Button {
            TextFocusClearRequest.commitBeforeChangingSelection {
                guard !editor.busy,
                      let index = editor.session?.positions.firstIndex(where: { $0.id == position.id }) else { return }
                editor.selectPosition(index)
                if adjusting { adjusting = false; editor.persistSession() }
            }
        } label: {
            Text("\(index + 1)").font(.callout.monospacedDigit())
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 25, height: 25)
                .background(selected ? Color.blue : Color(nsColor: .controlBackgroundColor), in: Circle())
                .overlay(Circle().strokeBorder(selected ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).opacity(editor.busy ? 0.5 : 1)
        .accessibilityLabel("Position \(index + 1) of \(session.positions.count)")
        .accessibilityValue(status)
        .accessibilityAddTraits(editor.positionIndex == index ? .isSelected : [])
        .uiInteractionAnchor("room-position-\(index)")
    }

    private func coordinateField(_ title: String, axis: WritableKeyPath<SpatialVector3, Float>) -> some View {
        let positionID = editor.position?.id
        return HStack {
            Text(title).frame(width: 130, alignment: .leading)
            TextField(title, value: Binding(get: {
                ((editor.session?.positions.first { $0.id == positionID }?.coordinate[keyPath: axis] ?? 0)
                    - (editor.session?.context.listener[keyPath: axis] ?? 0)) * 100
            }, set: { centimetres in
                let metres = centimetres / 100
                guard editor.position?.id == positionID, metres.isFinite, abs(metres) < 20,
                      var coordinate = editor.position?.coordinate else { return }
                coordinate[keyPath: axis] = metres + (editor.session?.context.listener[keyPath: axis] ?? 0)
                editor.movePosition(coordinate, profile: profile)
            }), format: .number.precision(.fractionLength(0))).frame(width: 100).onSubmit { editor.persistSession() }.disabled(editor.busy)
                .accessibilityLabel(title)
        }
    }
    private var calibratedCorrection: Bool { editor.source.kind == .microphone }
    private var correction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correction Method").font(.callout)
            JoinedSegmentedControl(options: [RoomCorrectionMethod.auto, .iir, .fir], selection: $editor.settings.method,
                title: { $0 == .auto ? "Auto (IIR)" : $0.rawValue.uppercased() })
                .frame(width: 260).disabled(editor.busy || editor.isVerifying)
                .accessibilityLabel("Correction Method")
                .uiInteractionAnchor("room-correction-method")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                if calibratedCorrection {
                    GridRow {
                        Text("Target")
                        RoomCorrectionMenu(label: "Target", selection: Binding(get: { editor.settings.effectiveTarget }, set: { editor.settings.target = $0 }),
                            options: RoomCorrectionTarget.allCases, title: { $0 == .flat ? "Flat" : "Gentle · −0.5 dB/octave" }, showsLabel: false)
                    }
                }
                GridRow { Text("Correction Range · Low"); limit("Low frequency", $editor.settings.lowHz, values: calibratedCorrection ? [20, 25, 40, 60, 80] : [45, 60, 80], unit: "Hz") }
                GridRow { Text("High"); limit("High frequency", $editor.settings.highHz, values: calibratedCorrection ? [300, 500, 800, 1500, 3000, 8000] : [150, 200, 300], unit: "Hz") }
                GridRow { Text("Maximum Boost"); limit("Maximum Boost", $editor.settings.maximumBoostDB, values: calibratedCorrection ? [0, 0.5, 1] : [0], unit: "dB") }
                GridRow { Text("Maximum Cut"); limit("Maximum Cut", $editor.settings.maximumCutDB, values: calibratedCorrection ? [1, 3, 6, 8] : [0.5, 1, 1.5], unit: "dB") }
                GridRow { Text("Maximum Q"); limit("Maximum Q", $editor.settings.maximumQ, values: [1, 2, 4], unit: "") }
                GridRow { Text("Filter Count"); integerLimit("Filter Count", $editor.settings.filterCount, values: calibratedCorrection ? [3, 5, 8] : [3, 5]) }
                if editor.settings.method == .fir {
                    GridRow { Text("Phase"); RoomCorrectionMenu(label: "Phase", selection: $editor.settings.phase, options: RoomFIRPhase.allCases, title: { $0.rawValue.capitalized }, showsLabel: false).frame(width: 120).uiInteractionAnchor("room-correction-phase") }
                    GridRow { Text("Filter Length"); integerLimit("Filter Length", $editor.settings.filterLength, values: [256, 512, 1024, 2048, 4096, 8192, 16384, 32768]) }
                    GridRow { Text("Added Delay Limit"); limit("Latency Limit", $editor.settings.latencyLimitMS, values: [5, 10, 20, 50, 100, 200], unit: "ms") }
                }
            }.disabled(editor.busy || editor.isVerifying)
            DisclosureGroup(isExpanded: $correctionDetailsExpanded) {
                RoomCorrectionResultDetails(result: editor.calculatedResult,
                    legacyBands: saved?.roomCorrectionBands ?? [], verificationCurrent: editor.verificationIsCurrent(profile: profile))
                    .uiInteractionAnchor("room-correction-details")
            } label: {
                Text("Calculation").uiInteractionAnchor("room-correction-calculation")
            }
            .disclosureGroupStyle(SectionDisclosureStyle())
        }
    }
    private func limit(_ label: String, _ value: Binding<Double?>, values: [Double], unit: String) -> some View {
        RoomCorrectionMenu(label: label, selection: value, options: [nil] + values.map { Optional($0) },
            title: { $0.map { "\($0.formatted())\(unit.isEmpty ? "" : " " + unit)" } ?? "Auto" }, showsLabel: false).frame(width: 120)
    }
    private func integerLimit(_ label: String, _ value: Binding<Int?>, values: [Int]) -> some View {
        RoomCorrectionMenu(label: label, selection: value, options: [nil] + values.map { Optional($0) },
            title: { $0.map { String($0) } ?? "Auto" }, showsLabel: false).frame(width: 120)
    }
}

/// Reads calculated output only. Expanding this disclosure never regenerates filters
/// or reads impulse-response files on the main thread.
private struct RoomCorrectionResultDetails: View {
    let result: RoomCorrectionResult?
    let legacyBands: [EQBand]
    var verificationCurrent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calculated filters").font(.headline)
            if let result {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Method"); Text(methodTitle(result.method)) }
                    if let delay = result.addedDelayMS {
                        GridRow { Text("Added filter delay"); Text("\(delay.formatted(.number.precision(.fractionLength(2)))) ms on all channels") }
                    }
                    GridRow { Text("Frequency range"); Text("\(result.lowHz.formatted(.number.precision(.fractionLength(0))))–\(result.highHz.formatted(.number.precision(.fractionLength(0)))) Hz") }
                }.font(.callout)
                if let verification = result.verification, verificationCurrent {
                    Text(verification.passed ? "Verification passed" : "Verification failed").font(.callout)
                    Text("Worst prediction error: \(verification.comparedResponses > 0 ? verification.worstPredictionErrorDB.formatted(.number.precision(.fractionLength(2))) + " dB RMS" : "unavailable") · \(verification.comparedResponses) responses · \(verification.measuredAt.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                RoomCorrectionPredictionView(result: result)
                if !result.hasCorrection {
                    Text("No filters were generated.").foregroundStyle(.secondary)
                }
                if !result.sharedBands.isEmpty {
                    bands(result.sharedBands, title: "All speakers")
                }
                ForEach(Set(result.channelBands.keys).union(result.channelFIR.keys).sorted(), id: \.self) { channel in
                    let filters = result.channelBands[channel] ?? []
                    if !filters.isEmpty || result.channelFIR[channel] != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(channelTitle(channel, in: result)).font(.callout.weight(.semibold))
                            if !filters.isEmpty { filterTable(filters) }
                            if let fir = result.channelFIR[channel] {
                                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                                    GridRow { Text("FIR filter"); Text("\(fir.asset.frameCount) taps") }
                                    GridRow { Text("Sample rate"); Text("\(fir.asset.sampleRate) Hz") }
                                    GridRow { Text("Phase"); Text(result.settings.phase.rawValue.capitalized) }
                                }.font(.caption)
                            }
                        }
                    }
                }
            } else if !legacyBands.isEmpty {
                bands(legacyBands, title: "All speakers · IIR equalizer")
            } else {
                Text("No calculated filters.")
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func methodTitle(_ method: RoomCorrectionMethod) -> String {
        switch method {
        case .auto: return "Auto"
        case .iir: return "IIR equalizer"
        case .fir: return "FIR convolution"
        case .hybrid: return "IIR (legacy Hybrid)"
        }
    }

    private func channelTitle(_ channel: Int, in result: RoomCorrectionResult) -> String {
        let name = result.context.topology.endpoints.first { $0.id.channelIndex == channel }?.displayName
        return name.map { "\($0) · Channel \(channel + 1)" } ?? "Channel \(channel + 1)"
    }

    private func bands(_ filters: [EQBand], title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            filterTable(filters)
        }
    }

    private func filterTable(_ filters: [EQBand]) -> some View {
        OverflowAwareHorizontalScrollView {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Filter"); Text("Frequency"); Text("Gain"); Text("Q / Width")
                }.foregroundStyle(.secondary)
                ForEach(filters) { band in
                    GridRow {
                        Text(filterTitle(band.kind) + (band.enabled ? "" : " · Bypassed"))
                        Text("\(band.frequency.formatted(.number.precision(.fractionLength(0)))) Hz")
                        Text(band.gain.map { String(format: "%+.1f dB", $0) } ?? "—")
                        Text(band.q.map { $0.formatted(.number.precision(.fractionLength(0...2))) }
                            ?? band.bandwidth.map { "\($0.formatted(.number.precision(.fractionLength(0...2)))) oct" } ?? "—")
                    }
                }
            }.font(.caption.monospacedDigit()).fixedSize(horizontal: true, vertical: false)
        }
    }

    private func filterTitle(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "Peaking"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .lowPass: return "Low pass"
        case .highPass: return "High pass"
        case .notch: return "Notch"
        case .allPass: return "All pass"
        }
    }
}

/// Use the menu bar output selector's Menu/Toggle pattern: AppKit owns menu
/// tracking and commits a selection only when the user activates an item.
struct RoomCorrectionMenu<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var showsLabel = true
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            if showsLabel { Text(label).fixedSize() }
            HStack(spacing: 6) {
                Text(title(selection)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, compact ? 6 : 8).frame(height: compact ? 20 : 24)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .opacity(isEnabled ? 1 : 0.5)
            .overlay {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Toggle(title(option), isOn: Binding(get: { selection == option }, set: { _ in selection = option }))
                    }
                } label: {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("\(label): \(title(selection))")
            }
            .uiInteractionAnchor("room-menu-\(label)")
        }
    }
}
