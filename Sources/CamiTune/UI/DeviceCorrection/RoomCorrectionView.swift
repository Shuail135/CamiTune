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
    @State private var selectedChannel: Int?
    @State private var mapZoom: CGFloat = 1
    @State private var mapViewportRevision = 0
    @State private var confirmReset = false
    @State private var correctionDetailsExpanded = false
    @State private var replacementMessage: String?
    @State private var confirmReplacement = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                Text("Room Correction").font(.title3.bold())
                Spacer()
            }
            tabs
            SelectedEditorPageLayout(selection: stepIndex) {
                step(.measure) { measure }
                step(.analysis) { RoomCorrectionAnalysisView(editor: editor) }
                step(.correction) { correction }
            }.clipped()
            if editor.busy && !editor.testingSound {
                HStack { ProgressView().controlSize(.small); Text(editor.status); Button("Cancel") { editor.cancel() } }
                    .uiInteractionAnchor("room-operation-cancel")
            }
            else if !editor.busy && showsStatus { Text(editor.status).font(.caption).foregroundStyle(.secondary) }
            if let error = editor.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            navigation
        }
        .onAppear { editor.load(profile: profile, app: state) }
        .onDisappear { importPanel?.cancel(nil); editor.close() }
        .onChange(of: saved?.id) { _ in editor.selectSeat(profile: profile, app: state) }
        .onChange(of: isVisible) { visible in
            if !visible { importPanel?.cancel(nil); editor.endCompare(); if editor.testingSound { editor.cancel() } }
        }
        .onChange(of: editor.tab) { tab in
            if tab != .correction { editor.endCompare() }
            if tab != .measure && editor.testingSound { editor.cancel() }
        }
        .onChange(of: editor.calculationRevision) { _ in correctionDetailsExpanded = true }
        .onChange(of: editor.importRevision) { _ in correctionDetailsExpanded = false }
        .onChange(of: editor.session?.id) { _ in mapZoom = 1; mapViewportRevision += 1 }
        .alert("Reset Room Correction?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                guard !editor.busy else { return }
                NSApp.keyWindow?.makeFirstResponder(nil)
                adjusting = false; selectedChannel = nil; mapZoom = 1; mapViewportRevision += 1
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
        !editor.status.isEmpty && ![
            "Room Correction ON", "Room Correction OFF", "Measurements ready",
            "Stop the phone recording, then import that one audio file.",
            "Keep recording. Move the phone to the blue marker, then press Next."
        ].contains(editor.status)
    }

    private var importedRecording: RoomRecordingReference? {
        guard editor.session?.source.kind == .recorder else { return nil }
        return editor.session?.recordings.last
    }

    private var hasImportedAnalysis: Bool { importedRecording != nil && editor.hasMeasurements }

    private func calculateCorrection() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        editor.create(profile: profile)
    }

    @ViewBuilder private var recordingControls: some View {
        if let recording = importedRecording {
            HStack(spacing: 6) {
                Text(recording.originalFileName ?? recording.fileName)
                    .lineLimit(1).truncationMode(.middle)
                    .help(recording.originalFileName ?? recording.fileName)
                    .uiInteractionAnchor("room-imported-recording")
                Button { editor.removeImportedRecording() } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove recording").accessibilityLabel("Remove recording")
                .uiInteractionAnchor("room-recording-remove")
            }
            .disabled(editor.busy)
        }
    }

    private enum ImportKind { case recording, calibration }
    private func chooseFile(_ kind: ImportKind) {
        guard !editor.busy, importPanel == nil else { return }
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
            Button("Reset Room Correction") {
                NSApp.keyWindow?.makeFirstResponder(nil)
                confirmReset = true
            }
            .disabled(editor.busy)
            .uiInteractionAnchor("room-correction-reset")
            Spacer(minLength: 12)
            if editor.tab == .measure && importedRecording != nil { recordingControls }
            if editor.tab != .measure && !hasImportedAnalysis {
                Button("Re-measure") { select(.measure) }
                    .disabled(editor.busy)
                    .uiInteractionAnchor("room-correction-remeasure")
            }
            if editor.tab == .correction {
                Button(editor.calculatedResult == nil ? "Calculate" : "Recalculate") {
                    calculateCorrection()
                }
                .disabled(!editor.canCalculate)
                .uiInteractionAnchor("room-correction-create")
                .accessibilityIdentifier("room-correction-create")
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
            } else if editor.tab == .measure && editor.session == nil {
                Button("Start Measurement") { editor.beginSession(profile: profile) }
                    .buttonStyle(.borderedProminent)
                    .disabled(editor.busy || (editor.source.kind == .microphone && !editor.microphoneIsConfigured))
                    .uiInteractionAnchor("room-correction-start").accessibilityIdentifier("room-correction-start")
            } else if editor.tab == .measure && editor.source.kind == .recorder && importedRecording == nil {
                Button(editor.recorderActionTitle) {
                    if editor.recorderPlaybackComplete { chooseFile(.recording) }
                    else { editor.measure(profile: profile, selectedChannel: nil) }
                }
                .buttonStyle(.borderedProminent).disabled(editor.busy)
                .uiInteractionAnchor("room-recorder-next").accessibilityIdentifier("room-recorder-next")
            } else if editor.tab == .measure && editor.source.kind == .microphone {
                if editor.session?.microphoneMeasurementsComplete == true {
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
            NSApp.keyWindow?.makeFirstResponder(nil)
            adjusting = false
            editor.measure(profile: profile, selectedChannel: selectedChannel)
        }
        .disabled(editor.busy || !editor.microphoneIsConfigured)
        .uiInteractionAnchor("room-microphone-measure")
    }
    private var measure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Recording", selection: Binding(get: { editor.source.kind }, set: { editor.setSourceKind($0, profile: profile) })) {
                Text("Phone or Others Microphone(Simple)").tag(RoomMeasurementSource.Kind.recorder)
                Text("Microphone with Calibration").tag(RoomMeasurementSource.Kind.microphone)
            }.pickerStyle(.radioGroup).disabled(editor.busy).uiInteractionAnchor("room-recording-type")
            if editor.source.kind == .microphone {
                HStack {
                    RoomCorrectionMenu(label: "Microphone", selection: Binding(get: { editor.source.deviceID }, set: { editor.setMicrophone($0) }),
                        options: microphoneOptions,
                        title: { id in
                            guard let id else { return "Choose microphone" }
                            return editor.microphones.first { $0.id == id }?.name ?? "\(editor.source.deviceName) (not connected)"
                        })
                        .frame(width: 280, alignment: .leading).disabled(editor.busy || editor.hasMicrophoneCaptures)
                        .uiInteractionAnchor("room-microphone-selection")
                    Button { editor.refreshMicrophones() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(editor.busy).help("Refresh microphones").accessibilityLabel("Refresh microphones")
                }
                HStack {
                    Text("Calibration")
                    Text(editor.source.calibration?.name ?? "Choose the file supplied for your microphone")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        .help(editor.source.calibration?.name ?? "").uiInteractionAnchor("room-calibration-name")
                    Button(editor.source.calibration == nil ? "Choose…" : "Change…") { chooseFile(.calibration) }
                        .uiInteractionAnchor("room-calibration-import").disabled(editor.busy)
                }
                positionCountControl(microphone: true)
                Text("Use an omnidirectional measurement microphone on a stand. Match its orientation to the calibration file: point upward for a 90° file. Keep input gain fixed and turn off voice processing.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Measure the main position at ear level, then spread the other positions around your listening area at different heights. Keep the microphone still while each speaker plays.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                positionCountControl(microphone: false)
                if importedRecording == nil {
                    Text(editor.recorderPlaybackComplete ? "All positions played. Stop recording on the phone and import the single audio file."
                    : (editor.session?.blocks.isEmpty != false
                        ? "Start recording on your phone and place it at the blue marker. Leave the recording running as you move between positions."
                        : "Keep the same phone recording running. Move to the blue marker, then press Next to play the sound.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Test volume")
                    SteppedValueSlider(value: Binding(get: { editor.testVolumeDB }, set: { editor.setTestVolumeDB($0) }),
                        in: editor.testVolumeRangeDB, step: 1)
                        .frame(width: 160).accessibilityLabel("Test volume")
                        .uiInteractionAnchor("room-test-volume")
                        .disabled(editor.busy && !editor.testingSound)
                    Text(String(format: "%+.0f dB", editor.testVolumeDB)).monospacedDigit().frame(width: 55, alignment: .trailing)
                    if editor.session != nil {
                        Button(editor.testingSound ? "Stop Sound" : "Test Sound") {
                            if editor.testingSound { editor.cancel() }
                            else { editor.measure(profile: profile, selectedChannel: selectedChannel, preview: true) }
                        }
                        .disabled(editor.busy && !editor.testingSound)
                        .uiInteractionAnchor("room-test-sound")
                    }
                }
                if editor.source.kind == .microphone {
                    Text("Start quietly. Use Test Sound to check the microphone input, then leave input gain unchanged. dBFS shows recording level, not sound pressure (SPL).")
                        .font(.caption).foregroundStyle(.secondary)
                    if let level = editor.microphoneLevel, editor.busy {
                        HStack {
                            Text(String(format: "Microphone · peak %.1f dBFS · RMS %.1f dBFS", level.peakDBFS, level.rmsDBFS)).monospacedDigit()
                            Text(level.clipped ? "Clipping — lower the level" : level.peakDBFS > -6 ? "Leave more headroom" : "")
                                .foregroundStyle(level.clipped ? Color.red : Color.orange)
                        }.font(.caption).uiInteractionAnchor("room-microphone-level")
                    }
                } else {
                    Text("Set test volume to ≈75 dB SPL").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let session = editor.session, let position = editor.position {
                positionNavigation(session)
                SpeakerRoomCanvas(topology: session.context.topology, listener: session.context.listener, selected: nil, playing: nil,
                    extent: 3, locked: true, listeningOnly: true, select: { _ in }, audition: { _ in }, moveSpeaker: { _, _ in },
                    moveListener: { _ in }, assignRole: { _, _ in }, measurementPoint: position.coordinate,
                    measurementRadius: 0,
                    allowsScrollPanning: false, fitsAllContent: true, viewportPoints: session.positions.map(\.coordinate),
                    viewportResetRevision: mapViewportRevision,
                    zoom: mapZoom, zoomChanged: { mapZoom = $0 })
                    .frame(height: 300).uiInteractionAnchor("room-measurement-map")
                HStack(spacing: 8) {
                    Text(session.source.kind == .recorder ? "Place the phone’s microphone at the blue marker (ear level)."
                        : "Place the microphone at the blue marker · \(String(format: "%+.2f", position.coordinate.z - session.context.listener.z)) m from ear level.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { mapZoom = max(0.25, mapZoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(mapZoom <= 0.25).help("Zoom Out").accessibilityLabel("Zoom Out")
                        .uiInteractionAnchor("room-map-zoom-out")
                    Button { mapZoom = min(4, mapZoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(mapZoom >= 4).help("Zoom In").accessibilityLabel("Zoom In")
                        .uiInteractionAnchor("room-map-zoom-in")
                    Button("Fit All") { mapZoom = 1; mapViewportRevision += 1 }.help("Show all speakers and measurement positions")
                        .uiInteractionAnchor("room-map-fit")
                }.controlSize(.small)
                if session.source.kind == .microphone {
                    HStack {
                        Button(adjusting ? "Done" : "Adjust Position") {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            adjusting.toggle()
                            if !adjusting { editor.persistSession() }
                        }.disabled(position.isMain || editor.busy).uiInteractionAnchor("room-position-adjust")
                        Button(position.skipped ? "Include" : "Skip") { adjusting = false; editor.skipPosition() }
                            .disabled(position.isMain || editor.busy || (!position.skipped && session.positions.filter { !$0.skipped }.count <= 3))
                            .uiInteractionAnchor("room-position-skip")
                        Button("Remove") { adjusting = false; editor.removePosition() }.disabled(position.isMain || editor.busy)
                            .uiInteractionAnchor("room-position-remove")
                        Button("Add Position") { adjusting = false; editor.addPosition(profile: profile) }.disabled(editor.busy || session.positions.count >= 32)
                            .uiInteractionAnchor("room-position-add")
                    }.uiInteractionAnchor("room-position-editing")
                    if adjusting && !position.isMain {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Offsets from the main listening position. Moving a measured position clears its recordings.").font(.caption).foregroundStyle(.secondary)
                            coordinateField("Left / right (m)", axis: \.x)
                            coordinateField("Front / back (m)", axis: \.y)
                            coordinateField("Height (m)", axis: \.z)
                        }
                    }
                }
                if session.source.kind == .microphone {
                    RoomCorrectionMenu(label: "Channels", selection: $selectedChannel,
                        options: [nil] + profile.configuredProcessingChannels.map { Optional($0.index) }, title: { index in
                            guard let channel = profile.configuredProcessingChannels.first(where: { $0.index == index }) else { return "All speakers" }
                            return channel.role.displayName + " · \(channel.index + 1)"
                        }).frame(width: 240, alignment: .leading).disabled(editor.busy)
                        .uiInteractionAnchor("room-measurement-channels")
                }
            }
            if editor.hasMeasurements {
                Text("\(measurementCount) \(measurementCount == 1 ? "measurement" : "measurements") ready").font(.callout)
            }
        }
    }

    private var microphoneOptions: [String?] {
        var ids = editor.microphones.map(\.id)
        if let selected = editor.source.deviceID, !ids.contains(selected) { ids.append(selected) }
        return [nil] + ids.map(Optional.some)
    }

    private func positionCountControl(microphone: Bool) -> some View {
        HStack(spacing: 10) {
            Text("Positions")
            if let session = editor.session, RoomRecorderPositionCount(rawValue: session.positions.count) == nil || (microphone && editor.hasMicrophoneCaptures) {
                Text("\(session.positions.count) positions").foregroundStyle(.secondary)
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
        return !position.observations.isEmpty ? "Ready" : (editor.hasPlayed(position, in: session) ? "Sound played" : "Not measured")
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
            if let position = editor.position, position.skipped || !position.observations.isEmpty {
                Text(positionStatus(position, in: session))
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
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
        .help("Position \(index + 1)\(position.isMain ? " · Main listening position" : "") · \(status)")
        .uiInteractionAnchor("room-position-\(index)")
    }

    private func coordinateField(_ title: String, axis: WritableKeyPath<SpatialVector3, Float>) -> some View {
        HStack {
        Text(title).frame(width: 130, alignment: .leading)
        TextField(title, value: Binding(get: { (editor.position?.coordinate[keyPath: axis] ?? 0) - (editor.session?.context.listener[keyPath: axis] ?? 0) }, set: { value in
            guard value.isFinite, abs(value) < 20, var coordinate = editor.position?.coordinate else { return }
            coordinate[keyPath: axis] = value + (editor.session?.context.listener[keyPath: axis] ?? 0)
            editor.movePosition(coordinate, profile: profile)
        }), format: .number.precision(.fractionLength(2))).frame(width: 100).onSubmit { editor.persistSession() }.disabled(editor.busy)
            .accessibilityLabel(title)
        }
    }
    private var correction: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = editor.calculatedResult {
                if !result.hasCorrection {
                    Text("No correction passed the quality checks. Audio is unchanged.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Correction Method").font(.callout)
            JoinedSegmentedControl(options: RoomCorrectionMethod.allCases, selection: $editor.settings.method,
                title: { $0 == .auto ? "Auto" : ($0 == .hybrid ? "Hybrid" : $0.rawValue.uppercased()) })
                .frame(width: 260).disabled(editor.busy)
                .accessibilityLabel("Correction Method")
                .uiInteractionAnchor("room-correction-method")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Correction Range · Low"); limit("Low frequency", $editor.settings.lowHz, values: [20, 25, 40, 60, 80], unit: "Hz") }
                GridRow { Text("High"); limit("High frequency", $editor.settings.highHz, values: [300, 500, 800, 1500, 3000, 8000], unit: "Hz") }
                GridRow { Text("Maximum Boost"); limit("Maximum Boost", $editor.settings.maximumBoostDB, values: [0, 0.5, 1, 2, 3], unit: "dB") }
                GridRow { Text("Maximum Cut"); limit("Maximum Cut", $editor.settings.maximumCutDB, values: [3, 6, 8, 12], unit: "dB") }
                GridRow { Text("Maximum Q"); limit("Maximum Q", $editor.settings.maximumQ, values: [1, 2, 4, 6, 10], unit: "") }
                GridRow { Text("Filter Count"); integerLimit("Filter Count", $editor.settings.filterCount, values: [3, 5, 8, 12, 20]) }
                if editor.settings.method == .fir || editor.settings.method == .hybrid {
                    GridRow { Text("Phase"); RoomCorrectionMenu(label: "Phase", selection: $editor.settings.phase, options: RoomFIRPhase.allCases, title: { $0.rawValue.capitalized }, showsLabel: false).frame(width: 120).uiInteractionAnchor("room-correction-phase") }
                    GridRow { Text("Filter Length"); integerLimit("Filter Length", $editor.settings.filterLength, values: [512, 1024, 2048, 4096, 8192, 16384]) }
                    GridRow { Text("Latency Limit"); limit("Latency Limit", $editor.settings.latencyLimitMS, values: [5, 10, 20, 50, 100, 200], unit: "ms") }
                }
            }.disabled(editor.busy)
            DisclosureGroup(isExpanded: $correctionDetailsExpanded) {
                RoomCorrectionResultDetails(result: editor.calculatedResult,
                    legacyBands: saved?.roomCorrectionBands ?? [])
                    .uiInteractionAnchor("room-correction-details")
            } label: {
                Text("Calculation").uiInteractionAnchor("room-correction-calculation")
            }
            .disclosureGroupStyle(SectionDisclosureStyle())
        }
    }
    private var measurementCount: Int {
        editor.source.kind == .microphone ? (editor.session?.completeMicrophonePositionCount ?? 0) : (editor.session?.usablePositionCount ?? 0)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calculated filters").font(.headline)
            if let result {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Method"); Text(methodTitle(result.method)) }
                    GridRow { Text("Frequency range"); Text("\(result.lowHz.formatted())–\(result.highHz.formatted()) Hz") }
                }.font(.callout)
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
                Text("Calculate room correction to see the filters for your speakers.")
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
        case .hybrid: return "Hybrid · IIR + FIR"
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
                        Text("\(band.frequency.formatted(.number.precision(.fractionLength(0...1)))) Hz")
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
