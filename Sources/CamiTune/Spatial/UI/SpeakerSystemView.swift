import SwiftUI

@MainActor
struct SpeakerSystemView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    var draftOnly = false
    var listeningOnly = false
    var newPosition = false
    var embedded = false
    var compact = false
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audition = SpeakerOutputAudition()
    @State private var historyBaseline: SpeakerSystemHistoryState?
    @State private var historyGestureActive = false
    @State private var draft: SpeakerTopology?
    @State private var seat: SpatialSeatingCalibration?
    @State private var originalSeat: SpatialSeatingCalibration?
    @State private var originalProfile: DeviceProfile?
    @State private var selected: PhysicalOutputID?
    @State private var busy = false
    @State private var message: String?
    @State private var confirmClose = false
    @State private var titleHovered = false
    @State private var renamingTitle = false
    @State private var titleDraft = ""
    @State private var renamingID: PhysicalOutputID?
    @State private var canvasID = UUID()
    @State private var graphZoom: CGFloat = 1.25
    @FocusState private var titleFocused: Bool
    @State private var boardExtent: Float = 1

    private var saved: Bool { draft == profile.speakerTopology && seat == originalSeat }
    private var editingLocked: Bool { busy || audition.output != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            // Profile Settings already supplies the section heading.
            if !compact || (!listeningOnly && (!draftOnly || draft == nil)) {
                HStack {
                    if !compact {
                        Text(listeningOnly ? "Listening Position" : "Speaker and Listening Position").font(.title3.bold())
                    }
                    Spacer()
                    if !listeningOnly && (!draftOnly || draft == nil) {
                        Button("Discover Channels") { discover() }.disabled(editingLocked)
                    }
                }
            }
            Text("Configure speaker position and user position for best performance.")
                .font(.callout).foregroundStyle(.secondary)
            if let draft {
                roomMap(draft)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        mapInstructions.fixedSize()
                        Spacer()
                        zoomControls
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        mapInstructions.fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            zoomControls
                        }
                    }
                }
                if !listeningOnly {
                    Text("If the default role is wrong, click the down arrow to change it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let index = draft.endpoints.firstIndex(where: { $0.id == selected }), !listeningOnly {
                    speakerTitle(draft.endpoints[index])
                    heightEditor(index: index)
                }
            } else {
                Text("Discover the physical channels to configure this room.").foregroundStyle(.secondary)
            }
            if audition.preparing { ProgressView("Preparing test…").controlSize(.small) }
            if busy { ProgressView().controlSize(.small) }
            if let detail = message ?? audition.message { Text(detail).font(.callout).foregroundStyle(.orange) }
            if !draftOnly {
                HStack {
                    Spacer()
                    Button("Save") { save(close: false) }.disabled(draft == nil || editingLocked || saved)
                    Button("Close") { close() }.disabled(busy).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            originalProfile = profile; draft = profile.speakerTopology
            let existing = profile.effectiveSpatialSettings.seating
            seat = newPosition ? SpatialSeatingCalibration(outputDeviceUID: profile.outputDeviceUID, name: "Default") : existing
            if seat == nil { seat = SpatialSeatingCalibration(outputDeviceUID: profile.outputDeviceUID, name: "Default") }
            if seat?.name == "Primary" || seat?.name == "My listening position" { seat?.name = "Default" }
            originalSeat = newPosition ? nil : existing
            if !draftOnly, let session = state.speakerEditSessions[profile.id] {
                draft = session.topology; seat = session.seat
            }
            historyBaseline = currentHistoryState
            selected = draft?.endpoints.first?.id
            if let draft { fitBoard(draft) }
            if newPosition { updateDistances() }
            publishDraft()
        }
        .onChange(of: state.historyReplayRevision) { _ in
            guard !draftOnly, let session = state.speakerEditSessions[profile.id] else { return }
            historyBaseline = session
            draft = session.topology; seat = session.seat
            originalProfile = profile
        }
        .onChange(of: selected) { _ in commitTitle() }
        .onChange(of: titleFocused) { focused in if !focused && renamingTitle { commitTitle() } }
        .onChange(of: draft) { _ in speakerEditChanged(); publishDraft() }
        .onChange(of: seat) { _ in speakerEditChanged(); publishDraft() }
        .onDisappear { finishHistoryGesture(); audition.stop() }
        .onChange(of: state.isSavingProfileSettings) { saving in if saving { audition.stop() } }
        .confirmationDialog("Save changes before closing?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Save Changes") { save(close: true) }
            Button("Discard Changes", role: .destructive) { draft = profile.speakerTopology; seat = originalSeat; speakerEditChanged(); finishClose() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func roomMap(_ topology: SpeakerTopology) -> some View {
        SpeakerRoomCanvas(topology: topology,
            listener: SpatialVector3(x: seat?.roomX ?? 0, y: seat?.roomY ?? 0, z: 0),
            selected: selected, playing: audition.output, extent: boardExtent,
            locked: busy, listeningOnly: listeningOnly,
            select: { selectSpeaker($0) },
            audition: { audition.toggle($0, topology: topology, audio: state.coreAudio) },
            moveSpeaker: { id, point in
                audition.stop()
                guard let index = draft?.endpoints.firstIndex(where: { $0.id == id }) else { return }
                draft?.endpoints[index].position = SpeakerLayoutGeometry.position(x: point.x, y: point.y, height: point.z)
                draft?.endpoints[index].positionSource = .userPlacement
                updateDistances()
            }, moveListener: { point in
                audition.stop()
                seat?.roomX = point.x; seat?.roomY = point.y
                seat?.useMeasuredAlignment = false
                updateDistances()
            }, assignRole: { id, role in audition.stop(); setRole(role, for: id) }, zoom: graphZoom, zoomChanged: { graphZoom = $0 }, editingChanged: historyEditingChanged)
            .id(canvasID)
            .frame(height: compact ? 270 : 370)
    }

    private var mapInstructions: some View {
        Text(listeningOnly ? "Drag the listener. Drag empty space to pan."
             : "Drag a speaker to place it. Click to test. Drag empty space to pan.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var zoomControls: some View {
        HStack {
            Button { graphZoom = max(0.25, graphZoom / 1.25) } label: {
                Image(systemName: "minus.magnifyingglass")
            }.help("Zoom out").accessibilityLabel("Zoom out").disabled(graphZoom <= 0.25)
            Text("\(Int((graphZoom * 100).rounded()))%")
                .font(.caption.monospacedDigit()).frame(width: 42)
            Button { graphZoom = min(4, graphZoom * 1.25) } label: {
                Image(systemName: "plus.magnifyingglass")
            }.help("Zoom in").accessibilityLabel("Zoom in").disabled(graphZoom >= 4)
            Button("Reset View") { graphZoom = 1.25; canvasID = UUID() }.controlSize(.small)
        }
        .fixedSize()
    }

    private func speakerTitle(_ endpoint: SpeakerEndpoint) -> some View {
        HStack {
            if renamingTitle {
                TextField("Speaker title", text: $titleDraft)
                    .font(.title2.bold()).textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    .onExitCommand { cancelTitle() }
            } else {
                Button {
                    renamingID = endpoint.id; titleDraft = endpoint.displayName; renamingTitle = true; titleFocused = true
                } label: {
                    HStack(spacing: 8) {
                        Text(endpoint.displayName).font(.title2.bold())
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                            .opacity(titleHovered ? 1 : 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).onHover { titleHovered = $0 }
                    .accessibilityLabel("Rename \(endpoint.displayName)")
                    .help("Rename this speaker")
            }
            Spacer()
        }.disabled(busy)
    }

    private func commitTitle() {
        guard renamingTitle else { return }
        let id = renamingID
        let title = String(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        cancelTitle()
        guard let index = draft?.endpoints.firstIndex(where: { $0.id == id }) else { return }
        if !title.isEmpty { draft?.endpoints[index].displayName = title }
    }
    private func cancelTitle() {
        renamingTitle = false
        renamingID = nil
        titleFocused = false
        titleDraft = ""
    }
    private func selectSpeaker(_ id: PhysicalOutputID?) {
        guard selected != id else { return }
        commitTitle()
        selected = id
    }
    private func setRole(_ role: ChannelRole?, for id: PhysicalOutputID) {
        commitTitle()
        guard var topology = draft else { return }
        SpeakerLayoutGeometry.setRole(role, for: id, in: &topology)
        draft = topology; selected = id
        updateDistances()
    }
    private func heightEditor(index: Int) -> some View {
        let height = Binding<Float>(get: { SpeakerLayoutGeometry.vector(draft?.endpoints[index].position).z }, set: { value in
            let point = SpeakerLayoutGeometry.vector(draft?.endpoints[index].position)
            draft?.endpoints[index].position = SpeakerLayoutGeometry.position(x: point.x, y: point.y, height: value)
            draft?.endpoints[index].positionSource = .userPlacement
            updateDistances()
        })
        return HStack {
            Text("Height relative to your head").font(.callout)
            Slider(value: height, in: -10...10, onEditingChanged: { historyEditingChanged($0) }).accessibilityLabel("Height relative to your head")
            Text(String(format: "%+.2f m", height.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 65)
        }.disabled(editingLocked)
    }
    private func updateDistances() {
        guard let draft else { return }
        for endpoint in draft.endpoints where endpoint.connectionState != .disabledByUser {
            let distance = SpeakerLayoutGeometry.distance(from: endpoint.position, listenerX: seat?.roomX ?? 0, listenerY: seat?.roomY ?? 0)
            if endpoint.role == .left { seat?.leftDistanceMeters = distance }
            if endpoint.role == .right { seat?.rightDistanceMeters = distance }
        }
    }
    private func fitBoard(_ topology: SpeakerTopology) {
        boardExtent = max(1, topology.endpoints.compactMap(\.position).map {
            let point = SpeakerLayoutGeometry.screenCoordinates(SpeakerLayoutGeometry.vector($0))
            return max(abs(point.x), abs(point.y)) + 0.25
        }.max() ?? 1)
    }
    private var currentHistoryState: SpeakerSystemHistoryState { SpeakerSystemHistoryState(topology: draft, seat: seat) }
    private var gestureKey: GestureKey { GestureKey(target: .speakerSystem(profile.id), control: "position") }
    private func speakerEditChanged() {
        guard !draftOnly, let before = historyBaseline else { return }
        let after = currentHistoryState
        state.speakerEditSessions[profile.id] = after
        guard !historyGestureActive else { return }
        state.history.record(actionName: "Edit Speaker Layout", contextName: profile.name, target: .speakerSystem(profile.id),
            before: .speakerSystem(before), after: .speakerSystem(after))
        historyBaseline = after
    }
    private func historyEditingChanged(_ editing: Bool) {
        guard !draftOnly else { return }
        if editing {
            guard !historyGestureActive else { return }
            historyGestureActive = true
            state.history.beginGesture(key: gestureKey, actionName: "Move Speaker or Listener", contextName: profile.name,
                target: .speakerSystem(profile.id), before: .speakerSystem(currentHistoryState))
        } else { finishHistoryGesture() }
    }
    private func finishHistoryGesture() {
        guard historyGestureActive else { return }
        historyGestureActive = false
        state.speakerEditSessions[profile.id] = currentHistoryState
        state.history.endGesture(key: gestureKey, after: .speakerSystem(currentHistoryState))
        historyBaseline = currentHistoryState
    }

    private func publishDraft() {
        guard draftOnly, let draft else { return }
        profile.speakerTopology = draft
        if let seat { profile.spatialSettings.seating = seat }
    }
    private func finishClose() { if let onClose { onClose() } else { dismiss() } }
    private func close() { if renamingTitle { commitTitle() }; audition.stop(); if saved { finishClose() } else { confirmClose = true } }

    private func save(close: Bool) {
        UIRenderPerformance.recordSpeakerSave()
        if renamingTitle { commitTitle() }
        audition.stop()
        guard var value = draft, let seat else { return }
        do {
            guard let originalProfile, originalProfile.id == profile.id,
                  originalProfile.outputDeviceUID == profile.outputDeviceUID,
                  originalProfile.speakerTopology == profile.speakerTopology,
                  originalProfile.spatialSettings == profile.spatialSettings else {
                throw ProfileSettingsError.runtime("The speaker configuration changed. Close and reopen this editor before saving.")
            }
            try value.validate()
            guard !seat.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfileSettingsError.runtime("Enter a listening-position name.")
            }
            if !listeningOnly { value.updatedAt = Date() }
            if draftOnly {
                profile.speakerTopology = value
                profile.spatialSettings.seating = seat
                draft = value; originalSeat = seat; self.originalProfile = profile
                if close { finishClose() }
            } else {
                var settings = ProfileSettingsDraft(profile: profile, activation: state.profiles.activationMode(for: profile))
                settings.speakerTopology = value
                settings.spatialSettings.seating = seat
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await state.saveProfileSettings(settings)
                        historyBaseline = SpeakerSystemHistoryState(topology: value, seat: seat)
                        state.speakerEditSessions[profile.id] = historyBaseline
                        draft = value; originalSeat = seat; self.originalProfile = state.profiles.profiles.first { $0.id == profile.id }
                        if close { finishClose() }
                    } catch { message = error.localizedDescription }
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func discover() {
        commitTitle()
        busy = true; message = nil
        let generation = state.editGeneration
        let uid = profile.outputDeviceUID
        Task {
            defer { busy = false }
            do {
                guard let device = await state.coreAudio.resolveDeviceWithoutBlockingUI(uid: uid) else {
                    throw SpeakerTopologyProbe.ProbeError.malformedProperty
                }
                var found = try await Task.detached(priority: .userInitiated) { try SpeakerTopologyProbe().probe(device) }.value
                guard generation == state.editGeneration, profile.outputDeviceUID == uid else { return }
                // Use the profile's requested processing rate; activation negotiates it.
                found.sampleRate = Double(profile.sampleRate)
                found = SpeakerLayoutGeometry.arrangedForEditing(found, previous: draft)
                draft = found; selected = found.endpoints.first?.id
                canvasID = UUID()
                fitBoard(found)
            } catch { message = error.localizedDescription }
        }
    }

}
