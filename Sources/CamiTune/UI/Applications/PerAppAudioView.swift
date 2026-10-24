import CamiTuneDomain
import AppKit
import SwiftUI

@MainActor
struct PerAppAudioView: View {
    @ObservedObject var state: AppState
    let profile: DeviceProfile?
    private let controller: PerAppAudioController
    @StateObject private var audioPresentation: PerAppAudioPresentation

    init(state: AppState, profile: DeviceProfile? = nil) {
        self.state = state
        self.profile = profile
        controller = state.perAppAudio
        _audioPresentation = StateObject(wrappedValue: PerAppAudioPresentation(controller: state.perAppAudio))
    }

    var body: some View {
        let scope = controller.resolvedSettingsScope(profile.map { .profile($0.id) } ?? .global)
        ScopedPerAppAudioView(state: state, profile: profile, scope: scope,
            audioPresentation: audioPresentation, presentation: controller.presentationStore(for: scope))
            .id(scope)
            .onAppear { controller.setMeterPresentationActive(true, source: "main") }
            .onDisappear { controller.setMeterPresentationActive(false, source: "main") }
    }
}

@MainActor
private struct ScopedPerAppAudioView: View {
    @ObservedObject var state: AppState
    let profile: DeviceProfile?
    let scope: PerAppSettingsScope
    @ObservedObject var audioPresentation: PerAppAudioPresentation
    @ObservedObject var presentation: AppPresentationStore
    @State private var showingOrder = false
    @StateObject private var reorder: MenuAppReorderCoordinator
    private var controller: PerAppAudioController { state.perAppAudio }

    init(state: AppState, profile: DeviceProfile?, scope: PerAppSettingsScope,
         audioPresentation: PerAppAudioPresentation, presentation: AppPresentationStore) {
        self.state = state
        self.profile = profile
        self.scope = scope
        self.audioPresentation = audioPresentation
        self.presentation = presentation
        _reorder = StateObject(wrappedValue: MenuAppReorderCoordinator(store: presentation))
    }

    private var applications: [PerAppAudioApplication] {
        let rows = profile == nil
            ? audioPresentation.editableApplications(in: presentation.snapshot)
            : audioPresentation.applications.filter(\.isActive)
        return rows.map { application in
            var application = application
            application.settings = controller.settings(for: application.id, scope: scope)
            return application
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("App Audio").font(.title3.bold())
                    Spacer()
                    Button { showingOrder = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("App Order")
                    if let profile {
                        JoinedSegmentedControl(options: [true, false], selection: Binding(
                            get: { controller.usesGlobalSettings(for: profile.id) },
                            set: { controller.setUsesGlobalSettings($0, for: profile.id) }
                        ), title: { $0 ? "Global" : "This Profile" })
                        .frame(width: 260)
                        .accessibilityLabel("App Audio scope")
                    }
                }
                Label("Press ⌘ and drag an app to reorder.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = audioPresentation.persistenceError ?? presentation.persistenceError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                if applications.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "speaker.slash").font(.largeTitle)
                        Text("No application audio detected").font(.headline)
                        Text("Play audio in an application to add it here.").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    PerAppAudioList(applications: applications, controller: controller,
                        meters: audioPresentation, presentation: presentation, reorder: reorder,
                        playbackContext: profile.map(PerAppPlaybackContext.init(profile:)),
                        sampleRate: Double(profile?.sampleRate ?? 48_000), controlsEnabled: !state.transitionInProgress,
                        scope: scope, allowsStoredModeSelection: profile == nil, scrolls: false)
                        .id(scope)
                }
            }.padding(6)
        }
        .sheet(isPresented: $showingOrder) { AppOrderView(store: presentation, controller: controller) }
        .onDisappear { reorder.cancel() }
    }
}

/// Continuous, unframed rows, separate from AppState so they can also be
/// inspected with temporary application fixtures without starting audio routing.
@MainActor
struct PerAppAudioList: View {
    let applications: [PerAppAudioApplication]
    let controller: PerAppAudioController
    let meters: PerAppAudioPresentation
    @ObservedObject var presentation: AppPresentationStore
    @ObservedObject var reorder: MenuAppReorderCoordinator
    let playbackContext: PerAppPlaybackContext?
    let sampleRate: Double
    let controlsEnabled: Bool
    var scope: PerAppSettingsScope = .active
    var allowsStoredModeSelection = false
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollView { rows }.scrollBounceWhenNeeded()
        } else { rows }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AppAudioSection.allCases) { section in applicationSection(section) }
        }
    }

    private func applicationSection(_ section: AppAudioSection) -> some View {
        let ordered = presentation.orderedApplications(applications, in: section)
        return Section {
            ForEach(ordered) { application in
                VStack(alignment: .leading, spacing: 0) {
                    applicationRow(application)
                    if application.id != ordered.last?.id {
                        Divider().padding(.leading, 42)
                    }
                }
            }
        } header: {
            MenuAppDropBridge(section: section, sectionAppend: false, coordinator: reorder) {
                HStack(spacing: 8) {
                    Text(section.title).font(.headline)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 32)
            .overlay {
                MenuAppDropIndicator(feedback: reorder.feedback, section: section, sectionAppend: false)
            }
        } footer: {
            MenuAppDropBridge(section: section, coordinator: reorder) {
                Text(ordered.isEmpty
                    ? (section == .shown ? "Drag apps here to show them in the menu bar." : "Drag apps here to hide them from the menu bar. Audio settings still apply.")
                    : "")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }
            // Keep a compact append target after the last row, with full room
            // for the drop guidance when the section has no applications.
            .frame(height: ordered.isEmpty ? 52 : 8)
            .overlay {
                MenuAppDropIndicator(feedback: reorder.feedback, section: section, highlightsArea: true)
            }
        }
    }

    private func applicationRow(_ application: PerAppAudioApplication) -> some View {
        let name = presentation.displayName(for: application)
        return ApplicationEqualizerExpansion { expanded in
            VStack(alignment: .leading, spacing: 0) {
                MenuAppDropBridge(applicationID: application.id, section: presentation.snapshot.section(for: application.id), coordinator: reorder) {
                    HStack(spacing: 8) {
                        PerApplicationIdentityHeader(application: application, name: name, store: presentation, reorder: reorder)
                            .frame(minWidth: 120, idealWidth: 200, maxWidth: 200, alignment: .leading)
                        HStack(spacing: 8) {
                            Button {
                                controller.setMuted(!application.settings.isMuted, for: application.id, scope: scope)
                            } label: {
                                Image(systemName: application.settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .frame(width: 20)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(application.settings.isMuted ? "Unmute" : "Mute") \(name)")
                            LiveApplicationVolumeSlider(meter: meters.meter(for: application.id),
                                volume: application.settings.volume, isMuted: application.settings.isMuted) { volume, finished in
                                controller.setVolume(volume, for: application.id, scope: scope, interactionFinished: finished)
                            }
                            .frame(minWidth: 100, maxWidth: .infinity).frame(height: 24)
                            .accessibilityLabel("\(name) volume")
                            Text("\(Int((application.settings.volume * 100).rounded()))%")
                                .monospacedDigit().font(.caption).frame(width: 36, alignment: .trailing)
                            Button {
                                expanded.wrappedValue.toggle()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "slider.horizontal.3")
                                        .fontWeight(application.settings.isEqualizerActive ? .semibold : .regular)
                                        .foregroundStyle(application.settings.isEqualizerActive ? Color.accentColor : Color.secondary.opacity(0.5))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 34, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Equalizer for \(name)")
                            .accessibilityValue("\(application.settings.isEqualizerActive ? "Active" : "Inactive"), \(expanded.wrappedValue ? "expanded" : "collapsed")")
                            if playbackContext?.showsModeControls != false {
                                PerAppPlaybackModeMenu(application: application, displayedName: name,
                                    controller: controller, context: playbackContext, scope: scope,
                                    allowsStoredSelection: allowsStoredModeSelection)
                                    .frame(width: 30)
                            }
                        }
                        .controlSize(.small)
                        .disabled(!controlsEnabled)
                    }
                }
                .frame(height: 64)
                if expanded.wrappedValue {
                    PerApplicationEQControls(applicationID: application.id, displayedName: name, settings: application.settings,
                        sampleRate: sampleRate, controller: controller, presentationStore: presentation, scope: scope)
                        .equatable()
                        .disabled(!controlsEnabled)
                        .padding(12)
                        .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.secondary.opacity(0.18))
                                .frame(width: 2)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                        .padding(.leading, 42)
                        .padding(.bottom, 14)
                }
            }
            .contextMenu {
                if PerAppApplicationIdentityPolicy.isPersistentApplicationID(application.id) {
                    let section = presentation.snapshot.section(for: application.id)
                    Button(section == .shown ? "Hide from Menu Bar" : "Show in Menu Bar") {
                        presentation.moveApplication(application.id, to: section == .shown ? .hidden : .shown)
                    }
                }
            }
            .opacity(reorder.draggedApplicationID == application.id ? 0.6 : 1)
            .overlay {
                MenuAppDropIndicator(feedback: reorder.feedback, applicationID: application.id)
            }
        }
    }
}

/// Expansion belongs to its row; opening an EQ must not rebuild every native
/// application control in the list.
private struct ApplicationEqualizerExpansion<Content: View>: View {
    @State private var expanded = false
    @ViewBuilder var content: (Binding<Bool>) -> Content
    var body: some View { content($expanded) }
}

private struct PerApplicationIdentityHeader: View {
    let application: PerAppAudioApplication
    let name: String
    let store: AppPresentationStore
    let reorder: MenuAppReorderCoordinator
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool
    @FocusState private var nameFocused: Bool

    private var canRename: Bool { PerAppApplicationIdentityPolicy.isPersistentApplicationID(application.id) }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: PerAppIconCache.icon(for: application))
                .resizable().frame(width: 32, height: 32)
                .overlay {
                    if canRename && !editing {
                        MenuAppDragSource(application: application, displayedName: name, coordinator: reorder,
                            drawsIdentity: false, modifierOnlyHitTesting: true)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("Application name", text: $draft)
                        .font(.body.weight(.medium))
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focused($fieldFocused)
                        .background(OutsideClickObserver { finish(save: true) })
                        .onSubmit { finish(save: true) }
                        .onExitCommand { finish(save: false) }
                        .onChange(of: fieldFocused) { if !$0 { finish(save: true) } }
                } else if canRename {
                    Button {
                        draft = name
                        editing = true
                        DispatchQueue.main.async { fieldFocused = true }
                    } label: {
                        HStack(spacing: 5) {
                            Text(name).font(.body.weight(.medium)).lineLimit(1)
                            Image(systemName: "pencil")
                                .font(.caption).foregroundStyle(.secondary)
                                .opacity(hovering || nameFocused ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focused($nameFocused)
                    .accessibilityLabel("Rename \(name)")
                } else {
                    Text(name).font(.body.weight(.medium)).lineLimit(1)
                }
                if let bundleID = application.bundleID {
                    Text(bundleID).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if canRename && !editing {
                MenuAppDragSource(application: application, displayedName: name, coordinator: reorder,
                    drawsIdentity: false, modifierOnlyHitTesting: true)
                    .accessibilityHidden(true)
            }
        }
        .onHover { hovering = $0 }
        .onDisappear { finish(save: true) }
    }

    @MainActor
    private func finish(save: Bool) {
        guard editing else { return }
        editing = false
        fieldFocused = false
        if save { store.setAlias(draft, for: application.id) }
    }
}

private struct PerApplicationEQControls: View, Equatable {
    @ObservedObject private var presentationStore: AppPresentationStore
    @State private var simpleTone: SimpleToneSettings
    let applicationID: String
    let displayedName: String
    let settings: PerAppAudioSettings
    let sampleRate: Double
    let controller: PerAppAudioController
    let scope: PerAppSettingsScope
    @State private var editorProfileID = UUID()
    @State private var bands: [EQBand]
    @State private var toneIsEditing = false
    @State private var bandGainIsEditing = false
    @State private var automaticSystemHeadroomDB: Double?

    init(applicationID: String, displayedName: String, settings: PerAppAudioSettings, sampleRate: Double, controller: PerAppAudioController, presentationStore: AppPresentationStore, scope: PerAppSettingsScope = .active) {
        _presentationStore = ObservedObject(wrappedValue: presentationStore)
        _simpleTone = State(initialValue: settings.simpleTone)
        self.applicationID = applicationID
        self.displayedName = displayedName
        self.settings = settings
        self.sampleRate = sampleRate
        self.controller = controller
        self.scope = scope
        _bands = State(initialValue: settings.equalizerBands)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.applicationID == rhs.applicationID && lhs.displayedName == rhs.displayedName && lhs.sampleRate == rhs.sampleRate
            && lhs.settings.eqBypassed == rhs.settings.eqBypassed
            && lhs.settings.equalizerBands == rhs.settings.equalizerBands
            && lhs.settings.simpleTone == rhs.settings.simpleTone
    }

    private var presentation: EqualizerPresentation { presentationStore.snapshot.records[applicationID]?.equalizerPresentation ?? .bands }

    private struct HeadroomInput: Hashable {
        let tone: SimpleToneSettings
        let bands: [EQBand]
        let sampleRate: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Equalizer")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                JoinedSegmentedControl(
                    options: EqualizerPresentation.allCases,
                    selection: Binding(get: { presentation }, set: {
                        presentationStore.setEqualizerPresentation($0, for: applicationID)
                    }),
                    title: { $0.title }
                )
                .accessibilityLabel("Equalizer controls")
                .frame(width: 260)
                Toggle("Enable equalizer for \(displayedName)", isOn: Binding(
                    get: { !settings.eqBypassed },
                    set: { controller.setEQBypassed(!$0, for: applicationID, scope: scope) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            Group {
                if let headroom = automaticSystemHeadroomDB {
                    Text("Automatic Headroom: \(headroom, format: .number.precision(.fractionLength(2))) dB")
                        .font(.caption.monospacedDigit().weight(.medium))
                } else {
                    Text("Calculating headroom…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if presentation != .bands {
                HStack {
                    Spacer()
                    SectionResetButton("Reset Tone") {
                        simpleTone = SimpleToneSettings()
                        controller.editEqualizer(for: applicationID, scope: scope) { $0.simpleTone = simpleTone }
                    }
                    .disabled(simpleTone.isNeutral)
                }
                SimpleEQControlsView(settings: Binding(get: { simpleTone }, set: { tone in
                    simpleTone = tone
                    controller.editEqualizer(for: applicationID, scope: scope, interactionFinished: !toneIsEditing) { $0.simpleTone = tone }
                }), onEditingChanged: { editing in
                    toneIsEditing = editing
                    if !editing { controller.finishAudioInteraction(for: applicationID, scope: scope) }
                })
            }
            if presentation == .both { Divider() }
            if presentation != .simpleTone {
                HStack(spacing: 8) {
                    Text("Bands")
                    Picker("PEQ bands", selection: Binding(get: { bands.count }, set: {
                        setBands(EQEditorSupport.resizedBands(bands, count: $0))
                    })) {
                        ForEach(0...20, id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().frame(width: 64)
                    Spacer()
                    SectionResetButton("Reset Bands") { setBands(EQDefaults.bands) }
                }
                if bands.isEmpty {
                    Text("0 PEQ bands.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                } else {
                    EqualizerBandScrollView(bandCount: bands.count) { columnWidth in
                        GraphicEqualizerBands(bands: Binding(get: { bands }, set: { setBands($0) }),
                            profileID: editorProfileID, responsePoints: [], setKind: EQEditorSupport.setKind,
                            columnWidth: columnWidth, showsSpectrumLevels: false, onGainEditingChanged: { editing in
                                bandGainIsEditing = editing
                                if !editing { controller.finishAudioInteraction(for: applicationID, scope: scope) }
                            })
                    }
                }
            }
        }
        .onDisappear { controller.finishAudioInteraction(for: applicationID, scope: scope) }
        .onChange(of: settings.simpleTone) { if !toneIsEditing { simpleTone = $0 } }
        .onChange(of: settings.equalizerBands) { updated in
            guard !bandGainIsEditing else { return }
            bands = updated
        }
        .onChange(of: applicationID) { _ in
            toneIsEditing = false
            bandGainIsEditing = false
            simpleTone = settings.simpleTone
            bands = settings.equalizerBands
        }
        .task(id: HeadroomInput(tone: simpleTone, bands: bands, sampleRate: sampleRate)) {
            let input = HeadroomInput(tone: simpleTone, bands: bands, sampleRate: sampleRate)
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let headroom = await Task.detached(priority: .utility) {
                PerAppAudioSettings(eqBypassed: false, equalizerBands: input.bands, simpleTone: input.tone)
                    .automaticHeadroomDB(sampleRate: input.sampleRate)
            }.value
            guard !Task.isCancelled else { return }
            automaticSystemHeadroomDB = headroom
        }
    }

    private func setBands(_ updated: [EQBand]) {
        guard updated.allSatisfy({ $0.frequency.isFinite && $0.frequency > 0 && $0.frequency < sampleRate / 2 }) else { return }
        bands = updated
        controller.editEqualizer(for: applicationID, scope: scope, interactionFinished: !bandGainIsEditing) { $0.equalizerBands = updated }
    }
}

@MainActor
private struct LiveApplicationVolumeSlider: View {
    @ObservedObject var meter: PerAppMeterState
    let volume: Double
    let isMuted: Bool
    let onVolumeChange: (Double, Bool) -> Void

    var body: some View {
        MeteredApplicationVolumeSlider(volume: volume, level: meter.level,
            isMuted: isMuted, onVolumeChange: onVolumeChange)
    }
}

struct MeteredApplicationVolumeSlider: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var volume: Double
    var level: Double
    var isMuted: Bool
    var onVolumeChange: (Double, Bool) -> Void
    @State private var interactionVolume: Double?

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 9
            let trackHeight: CGFloat = 7
            let track = CGRect(
                x: inset,
                y: (geometry.size.height - trackHeight) / 2,
                width: max(1, geometry.size.width - 2 * inset),
                height: trackHeight
            )
            let meterAmount = isMuted ? 0 : min(1, max(0, level))
            let volumeAmount = min(1, max(0, interactionVolume ?? volume))
            let thumbX = track.minX + track.width * volumeAmount
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: track.width, height: track.height)
                    .position(x: track.midX, y: track.midY)
                Capsule()
                    .fill(.blue)
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: meterAmount, y: 1, anchor: .leading)
                    .position(x: track.midX, y: track.midY)
                    .animation(reduceMotion ? nil : .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration), value: meterAmount)
                SliderThumb(isPressed: interactionVolume != nil)
                    .position(x: thumbX, y: track.midY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
                let ratio = min(1, max(0, (value.location.x - track.minX) / track.width))
                let adjusted = (ratio * 100).rounded() / 100
                interactionVolume = adjusted
                onVolumeChange(adjusted, false)
            }.onEnded { value in
                let ratio = min(1, max(0, (value.location.x - track.minX) / track.width))
                let adjusted = (ratio * 100).rounded() / 100
                interactionVolume = adjusted
                onVolumeChange(adjusted, true)
                DispatchQueue.main.async {
                    interactionVolume = nil
                }
            })
        }
        .onDisappear {
            if let interactionVolume { onVolumeChange(interactionVolume, true) }
        }
        .focusable()
        .onMoveCommand { direction in
            let increment: Double
            switch direction {
            case .up, .right: increment = 0.01
            case .down, .left: increment = -0.01
            default: return
            }
            onVolumeChange(min(1, max(0, (interactionVolume ?? volume) + increment)), true)
            interactionVolume = nil
        }
        .accessibilityElement()
        .accessibilityLabel("Application volume")
        .accessibilityValue("\(Int(((interactionVolume ?? volume) * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let current = interactionVolume ?? volume
            let next: Double
            switch direction {
            case .increment: next = min(1, current + 0.01)
            case .decrement: next = max(0, current - 0.01)
            @unknown default: return
            }
            interactionVolume = next
            onVolumeChange(next, true)
            DispatchQueue.main.async { interactionVolume = nil }
        }
    }

}

@MainActor
enum PerAppIconCache {
    private static let maximumEntries = 128
    private static var images: [String: NSImage] = [:]
    private static var insertionOrder: [String] = []

    static func icon(for application: PerAppAudioApplication) -> NSImage {
        if let cached = images[application.id] { return cached }
        let resolved: NSImage
        if let bundleURL = application.bundleURL {
            resolved = NSWorkspace.shared.icon(forFile: bundleURL.path)
        } else if let bundleID = application.bundleID,
                    let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleID
                    ) {
            resolved = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            resolved = NSImage(
                systemSymbolName: "app.fill",
                accessibilityDescription: nil
            ) ?? NSImage()
        }
        if images.count >= maximumEntries, let oldest = insertionOrder.first {
            images.removeValue(forKey: oldest)
            insertionOrder.removeFirst()
        }
        images[application.id] = resolved
        insertionOrder.append(application.id)
        return resolved
    }
}
