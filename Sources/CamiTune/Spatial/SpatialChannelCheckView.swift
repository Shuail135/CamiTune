import SwiftUI

@MainActor
struct SpatialChannelCheckView: View {
    @ObservedObject var state: AppState
    let context: SpatialCalibrationContext
    let headphones: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var playing: ChannelRole?
    @State private var error: String?
    @State private var requestID = UUID()
    private var roles: [ChannelRole] {
        headphones ? VirtualSpeakerLayout.cinema.speakers.map(\.role) : [.left, .center, .right]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check speaker positions").font(.title2.bold())
            Text(headphones ? "Listen for front, side and rear directions. A generic head model may place some sounds differently for you." : "Check left, centre and right from your usual seat. Use the listening-position balance adjustment if the centre sounds off to one side.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                ForEach(roles, id: \.self) { role in
                    Button(role.displayName) { play(role) }.disabled(playing != nil)
                }
            }
            if let playing {
                HStack {
                    Text("Playing \(playing.displayName)…")
                    Button("Stop") { stop() }
                }
            }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack { Spacer(); Button("Done") { dismiss() } }
        }.padding(24).frame(width: 440)
        .onChange(of: state.spatialCalibrationContext?.id) { id in if id != context.id { dismiss() } }
        .onDisappear { stop(); state.endSpatialCalibration(id: context.id) }
    }
    private func play(_ role: ChannelRole) {
        let request = UUID(); requestID = request
        playing = role
        let rate = context.sampleRate
        Task {
            let prepared = await Task.detached(priority: .userInitiated) {
                SpatialCalibrationClip(spatialCheck: role, sampleRate: rate)
            }.value
            guard requestID == request else { return }
            guard let clip = prepared else { playing = nil; error = "This sample rate is not supported for the check."; return }
            if !state.playSpatialCalibration(context: context, clip: clip, tuning: .neutral, completion: {
                Task { @MainActor in if requestID == request { playing = nil } }
            }) { playing = nil; error = "The output changed. Reopen the check." }
        }
    }
    private func stop() {
        requestID = UUID(); playing = nil
        state.pcmRouter.stopSpatialCalibrationSample(id: context.id)
    }
}
