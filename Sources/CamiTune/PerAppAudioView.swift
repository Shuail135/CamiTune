import AppKit
import SwiftUI

struct PerAppAudioView: View {
    @ObservedObject var state: AppState
    @ObservedObject var controller: PerAppAudioController

    init(state: AppState) {
        self.state = state
        controller = state.perAppAudio
    }

    private var activeApplications: [PerAppAudioApplication] {
        controller.applications.filter(\.isActive)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Application Audio").font(.largeTitle.bold())
                Text("Each application is processed and mixed independently before the active profile's global DSP.")
                    .foregroundStyle(.secondary)

                if !state.isActive {
                    inactiveRouteNotice
                }

                if activeApplications.isEmpty {
                    GroupBox {
                        VStack(spacing: 10) {
                            Image(systemName: "speaker.slash")
                                .font(.largeTitle)
                            Text("No application audio detected")
                                .font(.headline)
                            Text("Play audio in an application to add it here.")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }
                } else {
                    ForEach(activeApplications) { application in
                        applicationCard(application)
                            .disabled(!state.isActive)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onAppear {
            controller.setMeterPresentationActive(true, source: "main")
        }
        .onDisappear {
            controller.setMeterPresentationActive(false, source: "main")
        }
    }

    private var selectedProfile: DeviceProfile? {
        guard let profileID = state.profiles.selectedProfileID else { return nil }
        return state.profiles.profiles.first { $0.id == profileID }
    }

    private var inactiveRouteNotice: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activate a profile to control application audio")
                        .font(.headline)
                    Text("Per-app sensing, volume, and EQ operate on the active CamiTune audio route.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(6)
        }
    }

    private func applicationCard(_ application: PerAppAudioApplication) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    PerApplicationIdentityHeader(application: application)
                        .equatable()
                }

                HStack(spacing: 12) {
                    Button {
                        controller.setMuted(!application.settings.isMuted, for: application.id)
                    } label: {
                        Image(systemName: application.settings.isMuted
                            ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 20)
                    }
                    .buttonStyle(.borderless)
                    .help(application.settings.isMuted ? "Unmute application" : "Mute application")

                    Text("Volume")
                        .frame(width: 58, alignment: .leading)
                    MeteredApplicationVolumeSlider(
                        volume: application.settings.volume,
                        level: application.level,
                        isMuted: application.settings.isMuted,
                        onVolumeChange: { volume, interactionFinished in
                            controller.setVolume(
                                volume,
                                for: application.id,
                                interactionFinished: interactionFinished
                            )
                        }
                    )
                    .frame(height: 24)
                    Text("\(Int((application.settings.volume * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                Divider()

                PerApplicationEQControls(
                    applicationID: application.id,
                    settings: application.settings,
                    controller: controller
                )
                .equatable()

                Text("Application EQ is available only in the main CamiTune window. Menu-bar controls intentionally expose volume and mute only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(7)
        }
    }

}

private struct PerApplicationIdentityHeader: View, Equatable {
    let application: PerAppAudioApplication

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.application.id == rhs.application.id
            && lhs.application.bundleID == rhs.application.bundleID
            && lhs.application.bundleURL == rhs.application.bundleURL
            && lhs.application.processID == rhs.application.processID
            && lhs.application.displayName == rhs.application.displayName
    }

    var body: some View {
        Image(nsImage: PerAppIconCache.icon(for: application))
            .resizable()
            .frame(width: 36, height: 36)
        VStack(alignment: .leading, spacing: 2) {
            Text(application.displayName).font(.title3.bold())
            if let bundleID = application.bundleID {
                Text(bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        Spacer()
    }
}

private struct PerApplicationEQControls: View, Equatable {
    let applicationID: String
    let settings: PerAppAudioSettings
    let controller: PerAppAudioController
    @StateObject private var inactiveSpectrum = SpectrumAnalyzer()
    @State private var editorProfileID = UUID()
    @State private var bands: [EQBand]
    @State private var gainIsEditing = false

    init(
        applicationID: String,
        settings: PerAppAudioSettings,
        controller: PerAppAudioController
    ) {
        self.applicationID = applicationID
        self.settings = settings
        self.controller = controller
        _bands = State(initialValue: settings.equalizerBands.isEmpty
            ? EQDefaults.bands
            : settings.equalizerBands)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.applicationID == rhs.applicationID
            && lhs.settings.eqBypassed == rhs.settings.eqBypassed
            && lhs.settings.equalizerBands == rhs.settings.equalizerBands
    }

    private var eqEnabled: Bool {
        !settings.eqBypassed && !settings.equalizerBands.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Per-application EQ").font(.headline)
                Spacer()
                Toggle(
                    "Enable EQ",
                    isOn: Binding(
                        get: { eqEnabled },
                        set: { enabled in
                            if enabled && settings.equalizerBands.isEmpty {
                                bands = EQDefaults.bands
                                controller.setEqualizerBands(
                                    bands,
                                    for: applicationID
                                )
                            }
                            controller.setEQBypassed(!enabled, for: applicationID)
                        }
                    )
                )
            }

            if eqEnabled {
                HStack(spacing: 8) {
                    Text("Bands")
                    Picker("Bands", selection: Binding(
                        get: { bands.count },
                        set: { count in
                            bands = EQEditorSupport.resizedBands(bands, count: count)
                        }
                    )) {
                        ForEach(1...20, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 64)

                    Spacer()
                    Button("Reset Bands") { bands = EQDefaults.bands }
                }

                let columnWidth = 96.0
                let contentWidth = GraphicEqualizerBands.requiredContentWidth(
                    bandCount: bands.count,
                    columnWidth: columnWidth
                )
                OverflowAwareHorizontalScrollView(
                    contentWidth: contentWidth,
                    height: 402
                ) {
                    GraphicEqualizerBands(
                        bands: $bands,
                        spectrum: inactiveSpectrum,
                        profileID: editorProfileID,
                        responsePoints: [],
                        setKind: EQEditorSupport.setKind,
                        columnWidth: columnWidth,
                        showsSpectrumLevels: false,
                        onGainEditingChanged: { editing in
                            gainIsEditing = editing
                            if !editing {
                                controller.setEqualizerBands(
                                    bands,
                                    for: applicationID,
                                    interactionFinished: true
                                )
                            }
                        }
                    )
                }
            } else {
                Text("Enable EQ to edit this application's frequency bands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: bands) { updated in
            guard updated != settings.equalizerBands else { return }
            controller.setEqualizerBands(
                updated,
                for: applicationID,
                interactionFinished: !gainIsEditing
            )
        }
    }
}

struct MeteredApplicationVolumeSlider: View {
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
                    .fill(.green)
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: meterAmount, y: 1, anchor: .leading)
                    .position(x: track.midX, y: track.midY)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().stroke(Color.primary.opacity(0.75), lineWidth: 1.5))
                    .frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .position(x: thumbX, y: track.midY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(
                .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration),
                value: meterAmount
            )
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
