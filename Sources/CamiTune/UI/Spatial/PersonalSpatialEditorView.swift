import CamiTuneAudio
import CamiTuneDomain
import SwiftUI

@MainActor
struct PersonalSpatialEditorView: View {
    @ObservedObject var state: AppState
    let profile: DeviceProfile
    @State private var draft: PersonalSpatialSettings
    @State private var selectionPreference: String?
    @State private var activeInputChannels: Set<Int> = []
    @State private var fineTune = false
    @State private var customizeSpeakers = false
    @State private var sheet: Sheet?
    @State private var pendingSettings: PersonalSpatialSettings?
    @State private var preparation: PersonalSpatialPreparationStatus?
    @State private var movieAnalysis: MovieAnalysisStatus = .off
    @State private var error: String?
    @State private var audition: Audition?
    @State private var knownRoles: Set<ChannelRole> = [.left, .right]
    @State private var zoom: CGFloat = 1
    @State private var viewportResetRevision = 0

    private enum Sheet: Hashable, Identifiable {
        case device, deviceType, speaker(VirtualSpeakerGroup), applications
        var id: Self { self }
    }
    private struct Audition {
        let context: SpatialCalibrationContext
        let sourceID: String
    }

    init(state: AppState, profile: DeviceProfile) {
        self.state = state
        self.profile = profile
        _draft = State(initialValue: profile.personalSpatial)
        _preparation = State(initialValue: state.pcmRouter.personalSpatialPreparationStatus)
    }

    private var active: Bool { state.isActive && state.activeProfileID == profile.id }
    private var canAudition: Bool { active && pendingSettings == nil && preparation == .active(draft.renderIntent) }
    private var genericName: String { profile.effectiveEndpointKind == .iem ? "Generic IEM" : "Generic Headphones" }
    private var listening: Bool { draft.experience == .spatialListening }
    private var movieVisible: Bool { listening && draft.movie.enabled && active }
    private var adjustable: Bool { listening || draft.scene.roomModel == .generic }
    private var listener: SpatialVector3 {
        listening ? draft.listening.placement(for: draft.inputLayout).listener : draft.scene.effectiveListener
    }
    private var currentProfile: DeviceProfile? {
        state.profiles.profiles.first {
            $0.id == profile.id && $0.deviceTypeConfigurationKey == profile.deviceTypeConfigurationKey
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(profile.effectiveEndpointKind == .iem ? "Earphones" : "Headphones")
                Spacer()
                Text(draft.playbackDevice?.name ?? genericName).foregroundStyle(.secondary).lineLimit(1)
                Button("Change…") { sheet = .device }
                    .accessibilityLabel("Change playback device model")
            }
            HStack {
                Text(draft.playbackDevice?.resolvedType.summary ?? "Device type not identified")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(draft.playbackDevice?.resolvedType.needsDetails != false ? "Confirm type…" : "Change type…") { sheet = .deviceType }
                    .accessibilityLabel("Change listening device type")
            }
            if draft.playbackDevice?.id == nil {
                Text("Choose your model for a closer match.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if draft.playbackDevice?.correction == nil {
                Text("Generic spatial rendering · no model correction applied.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            JoinedSegmentedControl(options: PersonalSpatialExperience.allCases, selection: Binding(
                get: { draft.experience }, set: { draft.experience = $0; resetViewport(); commit() }
            ), title: { $0.title })
                .accessibilityLabel("Spatial experience")
                .uiInteractionAnchor("personal-spatial-experience")
            Text(listening ? "Hear sounds around you, in the positions carried by your audio."
                : "Hear a matching speaker set or the measured SADIE II studio. Movie settings are saved for Spatial listening.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if listening {
                Text("Input bus: \(SpatialSourceFormat(layout: draft.inputLayout).displayName) · \(activeInputChannels.count) channels with recent signal")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The input bus does not identify the original track format. For already binaural or game-headphone audio, use the app's Direct override.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Listening distance")
                if adjustable {
                    if distanceSelection == nil { Text("Custom").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    JoinedSegmentedControl(options: ListeningDistance.allCases.map(Optional.some), selection: Binding(
                        get: { distanceSelection }, set: { if let preset = $0 { loadDistance(preset); resetViewport(); commit() } }
                    ), title: { $0?.title ?? "" }, unavailableReason: { preset in
                        guard let preset else { return nil }
                        var candidate = draft
                        if listening {
                            guard candidate.listening.load(preset, layout: candidate.inputLayout) else {
                                return "Increase Room size in Fine-tune to fit this listening distance."
                            }
                        } else { candidate.scene.load(preset) }
                        return (try? candidate.validate()) == nil ? "Increase Room size in Fine-tune to fit this listening distance." : nil
                    })
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Listening distance")
                        .uiInteractionAnchor("personal-spatial-distance")
                        .help("Starts with sounds closer to you or farther away. You can move them in Fine-tune.")
                } else {
                    Spacer()
                    Text("1.5 m · measured room").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Room")
                SteppedValueSlider(value: Binding(get: { Double(draft.room) }, set: {
                    draft.room = Float($0)
                    if active { state.pcmRouter.setPersonalRoom(draft.room) }
                }), in: 0...1, step: 0.01, style: .preamp, onEditingChanged: { if !$0 { commit() } })
                    .accessibilityLabel("Room")
                    .help(adjustable
                        ? "Adds reflections around the sound sources. At zero, you hear the direct sound without the added room."
                        : "Adjusts the recorded room tail. At 100%, you hear the complete measured studio response.")
                Text("\(Int((draft.room * 100).rounded()))%").monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            if listening {
            Toggle("Movie mode", isOn: Binding(get: { draft.movie.enabled }, set: { draft.movie.enabled = $0; commit() }))
                .help("Makes dialogue and loud moments easier to follow. Uses audio from apps playing through CamiTune.")
            if draft.movie.enabled {
                HStack {
                    Text("Apps")
                    Spacer()
                    Text(scopeLabel).foregroundStyle(.secondary)
                    Button(draft.movie.scope == .allApplications ? "Choose…" : "Change…") { sheet = .applications }
                        .accessibilityLabel("Choose Movie apps")
                }
                Picker("Detection", selection: Binding(get: { draft.movie.detector }, set: { draft.movie.detector = $0; commit() })) {
                    ForEach(MovieDetector.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("Basic estimates broad audio patterns. Local AI uses Apple's on-device classifier with about one second of context. Local AI measured about 1–2% of one M2 CPU core in analysis-only tests; total app usage depends on your setup. Audio stays on this Mac. Neither option separates dialogue from music.")
                if active {
                    Text(movieAnalysis.title).font(.caption).foregroundStyle(.secondary)
                    if case .unavailable(let reason) = movieAnalysis {
                        Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            }
            DisclosureGroup("Fine-tune", isExpanded: $fineTune) {
                fineTuneControls
            }.disclosureGroupStyle(SectionDisclosureStyle())
                .uiInteractionAnchor("personal-spatial-fine-tune")

            if pendingSettings != nil || (active && preparation == .preparing) {
                Text("Preparing…").font(.caption).foregroundStyle(.secondary)
            }
            if active, case .unavailable(let reason) = preparation {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if !active {
                Text("Activate this profile to hear changes and test its speakers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .disabled(pendingSettings != nil || state.transitionInProgress || state.isSavingProfileSettings)
        .onChange(of: profile.personalSpatial) { if pendingSettings == nil { draft = $0 } }
        .onReceive(state.pcmRouter.personalSpatialChanges) { preparation = $0 }
        .onReceive(state.pcmRouter.movieAnalysisChanges) { movieAnalysis = $0 }
        .onChange(of: movieVisible) { state.setMovieAnalysisPresentation(profileID: profile.id, active: $0) }
        .onReceive(state.perAppAudio.$applications) { _ in
            if state.mainWindowPresentationActive { updateInputEvidence() }
        }
        .onChange(of: fineTune) { if $0 { updateInputEvidence() } }
        .onChange(of: active) { if $0 && fineTune { updateInputEvidence() } }
        .onAppear {
            updateInputEvidence()
            movieAnalysis = state.pcmRouter.movieAnalysisStatus
            state.setMovieAnalysisPresentation(profileID: profile.id, active: movieVisible)
        }
        .onDisappear {
            stopAudition()
            state.setMovieAnalysisPresentation(profileID: profile.id, active: false)
            if active, let saved = currentProfile { state.pcmRouter.setPersonalRoom(saved.personalSpatial.room) }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .device:
                SpatialDevicePicker(endpoint: profile.effectiveEndpointKind, genericName: genericName, current: draft.playbackDevice) { choice in
                    draft.playbackDevice = choice
                    sheet = nil
                    commit()
                }
            case .deviceType:
                SpatialDeviceTypePicker(device: draft.playbackDevice ?? .init(name: genericName, source: "Generic")) { choice in
                    draft.playbackDevice = choice
                    sheet = nil
                    commit()
                }
            case .speaker(let group):
                SpatialSpeakerPicker(group: group) { sound in
                    draft.scene.assign(sound, to: group)
                    sheet = nil
                    resetViewport()
                    commit()
                }
            case .applications:
                MovieApplicationPicker(controller: state.perAppAudio, scope: draft.movie.scope) { scope in
                    draft.movie.scope = scope
                    sheet = nil
                    commit()
                }
            }
        }
    }

    private var fineTuneControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !listening {
            HStack(spacing: 4) {
                Text("Speaker setup").font(.headline)
                DeviceCorrectionHelpIcon(title: "Speaker setup",
                    message: "Choose one model and a stereo or surround setup. All speakers match automatically; Customize speakers lets you mix models if you want. The SADIE II studio uses measured Genelec 8030/8040 speakers with a KU100 listener; its speakers, placement and decay are fixed.")
            }
            Picker("Room model", selection: Binding(get: { draft.scene.roomModel }, set: {
                draft.scene.roomModel = $0
                resetViewport()
                commit()
            })) {
                ForEach(VirtualSpeakerRoom.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if adjustable { speakerModelRow(.front) }
            Picker("Setup", selection: Binding(get: { draft.scene.layout }, set: {
                draft.scene.selectLayout($0)
                resetViewport()
                commit()
            })) {
                ForEach(VirtualSpeakerLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if adjustable { speakerSetup }
            else if draft.scene.layout.hasSubwoofer {
                Text("The studio speakers use measured responses. The added subwoofer is generic; SADIE II has no measured subwoofer response.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if draft.scene.layout.hasSurrounds {
                Toggle("Surround ambience for stereo", isOn: Binding(get: { draft.scene.stereoAmbience }, set: { draft.scene.stereoAmbience = $0; commit() }))
                    .help("Adds stereo difference information to surround speakers while centered sounds stay in front. Multichannel tracks keep their own channels.")
                Text("Stereo stays in front unless ambience is on. Multichannel tracks use the speakers carried by the recording.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            } else {
                Picker("Receive audio", selection: Binding(get: { draft.inputLayout }, set: {
                    draft.inputLayout = $0
                    activeInputChannels = []
                    resetViewport(); commit()
                })) {
                    ForEach(inputLayouts, id: \.self) { layout in
                        Text(SpatialSourceFormat(layout: layout).displayName).tag(layout)
                    }
                }
                Text("Choose the format offered to your apps. Changing it may require selecting CamiTune again in the source app. Stereo remains stereo within a surround bus.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if draft.playbackDevice?.correction != nil {
                valueSlider(profile.effectiveEndpointKind == .iem ? "Earphone correction" : "Headphone correction",
                    value: Binding(get: { Double(draft.playbackDevice?.strength ?? 0) }, set: { draft.playbackDevice?.strength = Float($0) }),
                    range: 0...1, text: "\(Int(((draft.playbackDevice?.strength ?? 0) * 100).rounded()))%")
                    .help(deviceCorrectionHelp)
            }

            if adjustable {
                Divider()
                HStack(spacing: 4) {
                    Text("Spatial fit").font(.headline)
                    DeviceCorrectionHelpIcon(title: "Spatial fit",
                        message: "Adjust the generic listener to make sound direction more natural for you. 100% uses the measured reference. These are listening adjustments, not measurements of your head or ears. Select a position on the map and use Test to compare small changes.")
                    Spacer()
                    SectionResetButton("Reset spatial fit") { draft.hrtf = .init(); commit() }
                }
                valueSlider("Direction detail", value: Binding(get: { Double(draft.hrtf.strength) }, set: { draft.hrtf.strength = Float($0) }),
                    range: 0...1.5, step: 0.01, text: "\(Int((draft.hrtf.strength * 100).rounded()))%")
                    .help("Strength of the fine ear-shape cues in the HRTF. Reduce it if the sound is hollow or seems above you. Timing and broad head-shadow cues remain at zero.")
                valueSlider("Ear size", value: Binding(get: { Double(draft.hrtf.earSize) }, set: { draft.hrtf.earSize = Float($0) }),
                    range: 0.8...1.2, step: 0.01, text: "\(Int((draft.hrtf.earSize * 100).rounded()))%")
                    .disabled(draft.hrtf.strength == 0)
                    .help("Shifts the fine spectral cues associated with ear size. Adjust until a front speaker sounds naturally in front, rather than above you.")
                valueSlider("Head size", value: Binding(get: { Double(draft.hrtf.headSize) }, set: { draft.hrtf.headSize = Float($0) }),
                    range: 0.8...1.2, step: 0.01, text: "\(Int((draft.hrtf.headSize * 100).rounded()))%")
                    .help("Adjusts the arrival-time difference between your ears. Use a left or right speaker's test and listen for a clear, stable direction.")

                Divider()
                HStack(spacing: 4) {
                    Text("Room character").font(.headline)
                    DeviceCorrectionHelpIcon(title: "Room character",
                        message: "Room in the main view controls the overall amount. These settings adjust the size and texture of the added space.")
                    Spacer()
                    SectionResetButton("Reset room character") {
                        draft.acoustics = listening ? SpatialListeningScene().acoustics : PersonalSpatialRoom()
                        commit()
                    }
                }
                valueSlider("Room size", value: Binding(get: { Double(draft.acoustics.size) }, set: { draft.acoustics.size = Float($0) }),
                    range: Double(draft.acoustics.minimumSize(containing: placementPoints))...1.5,
                    step: 0.01, text: "\(Int((draft.acoustics.size * 100).rounded()))%")
                    .help("Moves the walls and changes echo spacing. The minimum keeps the current sound sources inside; moving a source does not move the walls.")
                Text(roomDimensions).font(.caption).foregroundStyle(.secondary)
                valueSlider("Early reflections", value: Binding(get: { Double(draft.acoustics.earlyReflectionsDB) }, set: { draft.acoustics.earlyReflectionsDB = Float($0) }),
                    range: -12...3, step: 0.1, text: String(format: "%+.1f dB", draft.acoustics.earlyReflectionsDB))
                    .help("Level of the first wall, floor and ceiling echoes. More can make speakers feel farther from your head; less keeps the sound drier.")
                valueSlider("Diffusion", value: Binding(get: { Double(draft.acoustics.diffusion) }, set: { draft.acoustics.diffusion = Float($0) }),
                    range: 0...1, step: 0.01, text: "\(Int((draft.acoustics.diffusion * 100).rounded()))%")
                    .help("How quickly later echoes blend into a smooth room tail. Lower values keep echoes more distinct.")
                valueSlider("Reverberation time", value: Binding(get: { Double(draft.acoustics.decaySeconds) }, set: { draft.acoustics.decaySeconds = Float($0) }),
                    range: 0.15...0.8, step: 0.01, text: String(format: "%.2f s", draft.acoustics.decaySeconds))
                    .help("How long the room sound lingers after a sound stops.")
                if draft.room == 0 {
                    Text("Room is off. Raise Room to hear these room settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack(spacing: 4) {
                Text(listening ? "Source placement" : "Speaker placement").font(.headline)
                DeviceCorrectionHelpIcon(title: listening ? "Source placement" : "Speaker placement", message: listening
                    ? "Drag a source or the listener. Use arrow keys to move, [ and ] to select sources, and Space to test. Hold Option to drag without snapping. Silent input channels stay silent. The height control moves a selected source above or below you."
                    : adjustable ? "Drag a speaker or the listener. Use arrow keys to move, [ and ] to select speakers, and Space to test. Hold Option to drag without snapping. Channels absent from the source stay silent unless stereo surround ambience is enabled."
                    : "These positions reproduce the measured studio. Select a speaker to inspect its position or test it. Choose Adjustable room to move speakers.")
                Spacer()
                if adjustable {
                    SectionResetButton("Reset placement") { resetPlacement(); resetViewport(); commit() }
                }
            }
            canvas.frame(height: nodes.count > 2 ? 430 : 270)
            HStack(spacing: 8) {
                Text("Drag empty space to pan. Scroll to move the page.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                SectionResetButton("Reset View") { resetViewport() }
                    .uiInteractionAnchor("personal-map-reset")
                SpeakerMapZoomControls(zoom: $zoom, anchorPrefix: "personal-map")
            }
            if let selected {
            HStack {
                Picker(listening ? "Source" : "Speaker", selection: Binding(
                    get: { self.selected ?? selected }, set: { selectionPreference = $0 }
                )) {
                    ForEach(nodes, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                Spacer()
                Button(audition?.sourceID == selected ? "Stop" : "Test") { play(selected) }
                    .disabled(!canAudition)
                    .help(active ? "Plays a short test through the selected virtual speaker." : "Activate this profile to test a speaker.")
            }
            if listening, let source = listeningSources.first(where: { $0.id.rawValue == selected }) {
                Text("\(source.origin.title) · \(source.role.speakerLayer == .height ? "Height channel" : "Source channel")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if adjustable {
                valueSlider("Azimuth", value: Binding(get: { Double(selectedPosition.azimuthDegrees) }, set: { moveSelected(azimuth: Float($0)) }),
                    range: -180...180, text: String(format: "%+.0f°", selectedPosition.azimuthDegrees))
                valueSlider("Distance", value: Binding(get: { Double(selectedPosition.distanceMeters ?? 1) }, set: { moveSelected(distance: Float($0)) }),
                    range: 1...5, text: String(format: "%.2f m", selectedPosition.distanceMeters ?? 1))
                valueSlider("Height", value: Binding(get: { Double(selectedPoint.z) }, set: {
                    var p = selectedPoint
                    p.z = Float($0)
                    move(selected, to: p)
                }), range: Double(max(draft.acoustics.bounds.minimum.z + 0.25, listening ? -15 : VirtualSpeakerScene.minimum.z))...Double(min(draft.acoustics.bounds.maximum.z - 0.25, listening ? 15 : VirtualSpeakerScene.maximum.z)),
                    text: String(format: "%.2f m", selectedPoint.z))
            } else {
                Text(String(format: "%+.0f° azimuth · %.2f m · %+.0f° elevation", selectedPosition.azimuthDegrees,
                    selectedPosition.distanceMeters ?? 0, selectedPosition.elevationDegrees))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            } else {
                Text("This input has no directional sources to place.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !listening && draft.scene.layout.hasSubwoofer {
                valueSlider("Bass crossover", value: Binding(get: { Double(draft.scene.crossoverHz) }, set: { draft.scene.crossoverHz = Float($0) }),
                    range: 40...160, step: 1, text: String(format: "%.0f Hz", draft.scene.crossoverHz))
                    .help("Sends bass below this frequency to the virtual subwoofer, along with the source LFE channel.")
                if adjustable, let recommended = draft.scene.recommendedCrossoverHz {
                    HStack {
                        Text(String(format: "Suggested from the speakers' measured bass extension: %.0f Hz", recommended))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use suggestion") { draft.scene.crossoverHz = recommended; commit() }
                    }
                }
                valueSlider("Subwoofer level", value: Binding(get: { Double(draft.scene.subwooferDB) }, set: { draft.scene.subwooferDB = Float($0) }),
                    range: -12...6, step: 0.1, text: String(format: "%+.1f dB", draft.scene.subwooferDB))
                valueSlider("Sub bass extension", value: Binding(get: { Double(draft.scene.subwoofer.extensionHz) }, set: { draft.scene.subwoofer.extensionHz = Float($0) }),
                    range: 15...60, step: 1, text: String(format: "%.0f Hz", draft.scene.subwoofer.extensionHz))
                    .help("The generic subwoofer's lower −3 dB frequency, with a 12 dB/octave roll-off. Set it from a subwoofer specification or tune it by ear. This is not a measured branded subwoofer.")
            }
            if listening && draft.movie.enabled {
                Divider()
                HStack {
                    Text("Movie options").font(.headline)
                    Spacer()
                    SectionResetButton("Reset Movie adjustments") {
                        var reset = MovieSettings()
                        reset.enabled = draft.movie.enabled; reset.scope = draft.movie.scope; reset.detector = draft.movie.detector
                        draft.movie = reset; commit()
                    }
                }
                valueSlider("Dialogue Clarity", value: Binding(get: { Double(draft.movie.dialogueClarity) }, set: { draft.movie.dialogueClarity = Float($0) }),
                    range: 0...1, text: "\(Int((draft.movie.dialogueClarity * 100).rounded()))%")
                    .help("Raises a real center channel, or adds broad voice presence when there is no center. Other sounds sharing those channels also change.")
                Picker("Dynamics", selection: Binding(get: { draft.movie.dynamics }, set: { draft.movie.dynamics = $0; commit() })) {
                    ForEach(MovieDynamics.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("Original preserves dynamics. Balanced softens peaks; Night reduces larger level differences. All channels share one fast gain control.")
                valueSlider("Music preservation", value: Binding(get: { Double(draft.movie.musicPreservation) }, set: { draft.movie.musicPreservation = Float($0) }),
                    range: 0...1, text: "\(Int((draft.movie.musicPreservation * 100).rounded()))%")
                    .help("Eases speech enhancement and room reduction when music or singing is detected.")
                valueSlider("Room reduction", value: Binding(get: { Double(draft.movie.roomReduction) }, set: { draft.movie.roomReduction = Float($0) }),
                    range: 0...1, text: "\(Int((draft.movie.roomReduction * 100).rounded()))%")
                    .help("Reduces only the added late room sound during speech, up to 3 dB. It leaves source positions and early reflections intact.")
                valueSlider("Adaptation", value: Binding(get: { Double(draft.movie.adaptation) }, set: { draft.movie.adaptation = Float($0) }),
                    range: 0...1, text: "\(Int((draft.movie.adaptation * 100).rounded()))%")
                    .help("Controls how much detection can adjust your manual settings. At zero, analysis stops and only manual clarity and dynamics remain.")
                valueSlider("Response speed", value: Binding(get: { Double(draft.movie.responseSpeed) }, set: { draft.movie.responseSpeed = Float($0) }),
                    range: 0...1, text: "\(Int((draft.movie.responseSpeed * 100).rounded()))%")
                    .help("How quickly context adjustments settle: 200–500 ms to engage, 1–2 seconds to release. Peak protection responds separately.")
                valueSlider("Extra reduction limit", value: Binding(get: { Double(draft.movie.additionalReductionLimitDB) }, set: { draft.movie.additionalReductionLimitDB = Float($0) }),
                    range: 0...6, step: 0.5, text: String(format: "%.1f dB", draft.movie.additionalReductionLimitDB))
                    .help("Caps the extra level reduction analysis may request beyond Balanced or Night dynamics. Original ignores this adjustment; no automatic makeup boost is added.")
            }
        }.padding(.top, 6)
    }

    private var speakerSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.scene.layout == .source
                ? "The map follows your audio. Choosing a speaker model starts a stereo set; choose a larger setup whenever you want."
                : "\(draft.scene.layout.roles.count) speakers\(draft.scene.layout.hasSubwoofer ? " + 1 generic subwoofer" : ""). Your chosen model fills the set automatically. You can change individual speakers below.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if draft.scene.layout.hasSurrounds || draft.scene.layout == .source {
                DisclosureGroup("Customize speakers", isExpanded: $customizeSpeakers) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Optional: mix models for dialogue, side or rear speakers. Leave them matching for a complete set with one choice.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(VirtualSpeakerGroup.allCases.filter { $0 != .front && $0.roles.contains(where: draft.scene.layout.roles.contains) }, id: \.self) {
                            speakerModelRow($0)
                        }
                        if draft.scene.speakers.keys.contains(where: { $0 != .front }) {
                            Button("Match all speakers to the set") {
                                draft.scene.speakers = draft.scene.speakers.filter { $0.key == .front }
                                commit()
                            }
                        }
                    }.padding(.top, 6)
                }.disclosureGroupStyle(SectionDisclosureStyle())
                    .uiInteractionAnchor("personal-speaker-customize")
            }
        }
    }

    private func speakerModelRow(_ group: VirtualSpeakerGroup) -> some View {
        let sound = draft.scene.speaker(for: group.roles[0])
        let matches = group != .front && draft.scene.speakers[group] == nil
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(group == .front ? "Speakers" : group.title).frame(width: 105, alignment: .leading)
                Text(sound?.name ?? "Neutral Monitor").foregroundStyle(.secondary).lineLimit(1)
                if matches { Text("Matching").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                Button("Change…") { sheet = .speaker(group) }
                    .accessibilityLabel(group == .front ? "Change speaker model" : "Change \(group.title.lowercased()) model")
                    .uiInteractionAnchor("personal-speaker-\(group.rawValue)")
                if group != .front && !matches {
                    Button("Match set") { draft.scene.speakers.removeValue(forKey: group); commit() }
                }
            }
            if let specs = sound?.specifications, !specs.summary.isEmpty {
                Text(specs.summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deviceCorrectionHelp: String {
        guard let correction = draft.playbackDevice?.correction else { return "" }
        let target = DeviceCorrectionTargetCatalog().displayName(for: correction.targetSelection.preset, sources: correction.sources)
        return "AutoEq · \(target). 0% bypasses the measured model correction; 100% applies it fully. User EQ remains separate."
    }
    private var roomDimensions: String {
        let bounds = draft.acoustics.bounds
        return String(format: "Room · %.1f m wide × %.1f m deep × %.1f m high",
            bounds.maximum.x - bounds.minimum.x, bounds.maximum.y - bounds.minimum.y, bounds.maximum.z - bounds.minimum.z)
    }
    private var visibleRoles: [ChannelRole] {
        draft.scene.layout == .source ? VirtualSpeakerScene.roles.filter { knownRoles.contains($0) } : draft.scene.layout.speakerRoles
    }
    private static let zero = SpatialVector3(x: 0, y: 0, z: 0)
    private var inputLayouts: [LPCMChannelLayout] {
        [.mono, .stereo, .quad, .fivePointOne, .sevenPointOne, .fivePointOnePointTwo, .fivePointOnePointFour,
         .sevenPointOnePointTwo, .sevenPointOnePointFour, .ninePointOnePointSix]
    }
    private var listeningSources: [SpatialListeningSource] { (try? draft.listening.sources(for: draft.inputLayout)) ?? [] }
    private var distanceSelection: ListeningDistance? {
        guard listening else { return draft.scene.isCustom ? nil : draft.scene.resetPreset }
        let placement = draft.listening.placement(for: draft.inputLayout)
        guard placement.positions.isEmpty, placement.listener == Self.zero else { return nil }
        return placement.distance ?? (draft.inputLayout.positions?.contains(where: { $0 != nil }) == true ? nil : .near)
    }
    private func loadDistance(_ distance: ListeningDistance) {
        if listening { _ = draft.listening.load(distance, layout: draft.inputLayout) }
        else { draft.scene.load(distance) }
    }
    private func resetPlacement() {
        if listening { draft.listening.resetPlacement(for: draft.inputLayout) }
        else { draft.scene.load(draft.scene.resetPreset) }
    }
    private var placementPoints: [SpatialVector3] {
        (listening ? listeningSources.compactMap(\.position) : draft.scene.layout.speakerRoles.map { draft.scene.position(for: $0) }) + [listener]
    }
    private var nodes: [SpeakerSceneNode] {
        if listening {
            return listeningSources.compactMap { source in
                guard let point = source.position else { return nil }
                return SpeakerSceneNode(id: source.id.rawValue, displayName: source.name, role: source.role, displayedRole: source.role,
                    position: SpeakerLayoutGeometry.position(x: point.x, y: point.y, height: point.z), connectionState: .confirmedByUser)
            }
        }
        return visibleRoles.map { role in
            let p = draft.scene.position(for: role)
            return SpeakerSceneNode(id: role.rawValue, displayName: speakerName(role), role: role, displayedRole: role,
                position: SpeakerLayoutGeometry.position(x: p.x, y: p.y, height: p.z), connectionState: .confirmedByUser)
        }
    }
    private var selectedPoint: SpatialVector3 {
        nodes.first { $0.id == selected }?.position.map { SpeakerLayoutGeometry.vector($0) } ?? Self.zero
    }
    /// A selection belongs to the currently displayed source set. Derive a
    /// valid value before building the picker, including during a mode switch.
    private var selected: String? {
        nodes.first { $0.id == selectionPreference }?.id ?? nodes.first?.id
    }
    private var selectedPosition: SpatialPosition {
        let p = selectedPoint, l = listener
        return SpeakerLayoutGeometry.position(x: p.x - l.x, y: p.y - l.y, height: p.z - l.z)
    }
    private func speakerName(_ role: ChannelRole) -> String {
        role == .lowFrequencyEffects ? role.groupName : role.displayName
    }
    private var scopeLabel: String {
        switch draft.movie.scope {
        case .allApplications: return "All apps"
        case .selectedApplications(let ids): return "Selected apps (\(ids.count))"
        }
    }
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double? = nil, text: String) -> some View {
        HStack {
            Text(title).frame(width: 145, alignment: .leading)
            SteppedValueSlider(value: value, in: range, step: step, style: .preamp, onEditingChanged: { if !$0 { commit() } }).accessibilityLabel(title)
            Text(text).monospacedDigit().frame(width: 65, alignment: .trailing)
        }.uiInteractionAnchor("personal-spatial-\(title)")
    }
    private func moveSelected(azimuth: Float? = nil, distance: Float? = nil) {
        guard let selected else { return }
        var position = selectedPosition
        if let azimuth { position.azimuthDegrees = azimuth }
        if let distance { position.distanceMeters = distance }
        let v = SpeakerLayoutGeometry.vector(position), l = listener
        move(selected, to: .init(x: v.x + l.x, y: v.y + l.y, z: v.z + l.z))
    }
    private func move(_ id: String?, to point: SpatialVector3) {
        if listening { _ = draft.listening.move(id.map { AudioChannelID(rawValue: $0) }, to: point, layout: draft.inputLayout) }
        else { _ = draft.scene.move(id.flatMap(ChannelRole.init(rawValue:)), to: point) }
    }
    private var canvas: some View {
        let points = nodes.compactMap(\.position).map { SpeakerLayoutGeometry.vector($0) } + [listener]
        let front = points.map(\.y).max() ?? 0, back = points.map(\.y).min() ?? 0
        return SpeakerSceneCanvas(nodes: nodes, listener: listener, selected: selected, playing: audition?.sourceID,
            extent: 5.5, locked: false, listeningOnly: false,
            select: { selectionPreference = $0 }, audition: { play($0) },
            moveSpeaker: { move($0, to: $1) }, moveListener: { move(nil, to: $0) }, allowsPositionEditing: adjustable,
            frontReferenceY: front + max(1, (front - back) * 0.45), rulerReference: listener,
            allowsScrollPanning: false, fitsAllContent: true,
            viewportResetRevision: viewportResetRevision, zoom: zoom, zoomChanged: { zoom = $0 },
            editingChanged: { if $0 { stopAudition() } else { commit() } })
    }
    private func resetViewport() {
        zoom = 1
        viewportResetRevision &+= 1
    }
    private func updateInputEvidence() {
        guard active else { return }
        // Remember verified source roles through quiet passages. Saved placement
        // is not evidence that a source actually supplied a channel.
        var roles = knownRoles
        var channels = Set<Int>()
        for diagnostics in state.perAppAudio.spatialInputDiagnostics.values {
            if diagnostics.declaredLayout.signalSignature == draft.inputLayout.signalSignature {
                channels.formUnion(diagnostics.activeChannels)
            }
            for index in diagnostics.provenChannels where diagnostics.declaredLayout.roles.indices.contains(index) {
                let role = diagnostics.declaredLayout.roles[index]
                if VirtualSpeakerScene.roles.contains(role) { roles.insert(role) }
            }
        }
        if roles != knownRoles { knownRoles = roles }
        if channels != activeInputChannels { activeInputChannels = channels }
    }
    private func commit() {
        guard pendingSettings == nil, let saved = currentProfile, draft != saved.personalSpatial else { return }
        stopAudition()
        let value = draft
        pendingSettings = value
        error = nil
        Task {
            do {
                try await state.setPersonalSpatial(profileID: saved.id, settings: value, expectedContext: saved.deviceTypeConfigurationKey)
            } catch {
                self.error = error.localizedDescription
            }
            // Read the transaction's final stored value, including rollback or
            // a newer external edit. A captured profile can be out of date here.
            if let saved = currentProfile {
                draft = saved.personalSpatial
                if active { state.pcmRouter.setPersonalRoom(draft.room) }
            }
            pendingSettings = nil
        }
    }
    private func stopAudition() {
        if let audition { state.endSpatialCalibration(id: audition.context.id) }
        audition = nil
    }
    private func play(_ id: String) {
        let stop = audition?.sourceID == id
        stopAudition()
        guard !stop, canAudition else { return }
        guard let context = state.beginSpatialCalibration(profileID: profile.id) else {
            error = state.errorMessage ?? "Speaker testing is unavailable while the audio route is changing."
            return
        }
        error = nil
        let layout = listening ? draft.inputLayout : LPCMChannelLayout.sevenPointOne
        let channel = listening ? listeningSources.first(where: { $0.id.rawValue == id })?.inputIndex
            : ChannelRole(rawValue: id).flatMap { layout.roles.firstIndex(of: $0) }
        guard let channel else { state.endSpatialCalibration(id: context.id); return }
        audition = Audition(context: context, sourceID: id)
        Task {
            let clip = await Task.detached(priority: .userInitiated) {
                SpatialCalibrationClip(spatialCheck: channel, layout: layout, sampleRate: context.sampleRate)
            }.value
            guard audition?.context.id == context.id else { return }
            guard let clip else { stopAudition(); return }
            if !state.playSpatialCalibration(context: context, clip: clip, completion: {
                Task { @MainActor in if audition?.context.id == context.id { stopAudition() } }
            }) {
                stopAudition()
                error = "The audio route changed before the speaker test could start."
            }
        }
    }
}
