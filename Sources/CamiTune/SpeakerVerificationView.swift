import AppKit
import SwiftUI

@MainActor
struct SpeakerVerificationView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    var previewOnly = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audition = SpeakerOutputAudition()
    @State private var session: SpeakerVerificationSession?
    @State private var original: DeviceProfile?
    @State private var played: PhysicalOutputID?
    @State private var wrongSpeaker = false
    @State private var heard: PhysicalOutputID?
    @State private var message: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Verify Speakers").font(.title2.bold()); Spacer(); Button("Close") { dismiss() } }
            if let session {
                Text(previewOnly ? "Simulated verification. Speaker tests are silent." : "Listen to each test and confirm which speaker plays.")
                    .foregroundStyle(.secondary)
                if let current = session.current {
                    Text(current.displayName).font(.title.bold())
                    Text("Hardware output \(current.id.channelIndex + 1) · \(session.confirmed.count + 1) of \(session.outputs.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(audition.output == current.id ? "Stop Test" : "Play Again") { play(current.id, topology: session.topology) }
                        .disabled(audition.preparing)
                    HStack {
                        Button("Wrong Speaker") { wrongSpeaker = true; heard = session.outputs.first { $0.id != current.id }?.id }
                        Button("Correct") {
                            audition.stop(); self.session?.confirm(); played = nil; wrongSpeaker = false; message = nil
                        }.disabled(played != current.id || audition.preparing || audition.message != nil)
                    }
                    if wrongSpeaker {
                        if profile.multichannel.crossover.enabled {
                            Text("Review the active hardware map and protection settings before correcting driver assignments.")
                                .foregroundStyle(.orange)
                        } else {
                            Picker("Which speaker played?", selection: $heard) {
                                ForEach(session.outputs.filter { $0.id != current.id }) { Text($0.displayName).tag(Optional($0.id)) }
                            }
                            Button("Swap speaker assignments") {
                                do {
                                    guard let heard else { return }
                                    audition.stop(); try self.session?.correctAssignment(heard: heard)
                                    played = nil; wrongSpeaker = false; message = "Assignments updated. Test both speakers again before saving."
                                } catch { message = error.localizedDescription }
                            }.disabled(heard == nil)
                        }
                    }
                } else if session.isComplete {
                    Text("All \(session.outputs.count) speakers confirmed.").font(.headline)
                    Button("Save verification") { save() }.disabled(saving)
                } else {
                    Text("Enable physical speakers before starting verification.").foregroundStyle(.secondary)
                }
            }
            if audition.preparing || saving { ProgressView().controlSize(.small) }
            if let message = message ?? audition.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(24).frame(minWidth: 520, minHeight: 360)
        .onAppear {
            original = profile
            if let topology = profile.speakerTopology { session = .init(topology: topology) }
        }
        .onDisappear { audition.stop() }
    }

    private func play(_ id: PhysicalOutputID, topology: SpeakerTopology) {
        played = id; message = nil
        if previewOnly { message = "Simulated test selected: hardware output \(id.channelIndex + 1)" }
        else { audition.toggle(id, topology: topology, audio: state.coreAudio, profile: profile) }
    }

    private func save() {
        guard let session, session.isComplete, let original else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let record = try SpeakerVerificationRecord(topology: session.topology, simulated: previewOnly)
                if previewOnly {
                    profile.speakerTopology = session.topology; profile.speakerVerification = record
                    state.profiles.update(profile)
                } else {
                    var settings = ProfileSettingsDraft(profile: original, activation: state.profiles.activationMode(for: original))
                    settings.speakerTopology = session.topology; settings.speakerVerification = record
                    try await state.saveProfileSettings(settings)
                    profile = try state.historyProfile(original.id)
                }
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}

extension AppState {
    func exportRuntimePlan(profile: DeviceProfile, previewOnly: Bool) async throws {
        let topology: SpeakerTopology
        if previewOnly {
            guard let simulated = profile.speakerTopology else { throw SpeakerTopologyError.invalidDeviceUID }
            topology = simulated
        } else {
            guard let device = await coreAudio.resolveDeviceWithoutBlockingUI(uid: profile.outputDeviceUID) else {
                throw ProfileSettingsError.runtime("Connect the profile's output before exporting its runtime plan.")
            }
            topology = try await Task.detached(priority: .userInitiated) { try SpeakerTopologyProbe().probe(device) }.value
        }
        let data = try await Task.detached(priority: .userInitiated) {
            let plan = try AudioRuntimePlanCompiler().compile(profile: profile, detectedHardware: topology)
            return try AudioRuntimePlanDiagnostic(plan: plan, profile: profile, simulated: previewOnly).json()
        }.value
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CamiTune-Runtime-Plan.json"
        panel.allowedContentTypes = [.json]
        guard await panel.begin() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }
}
