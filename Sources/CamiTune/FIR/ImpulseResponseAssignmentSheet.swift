import CamiTuneDomain
import SwiftUI

@MainActor
struct ImpulseResponseAssignmentSheet: View {
    let asset: ImpulseResponseAsset
    let channels: [ConfiguredProcessingChannel]
    let sampleRate: Int
    let onSingle: @MainActor (Int) -> Void
    let onAssign: @MainActor ([ImpulseResponseAssignment]) throws -> Void
    let onCancel: @MainActor () -> Void
    @State private var assignSpeakers = false
    @State private var impulseChannel = 0
    @State private var assignments: [ImpulseResponseAssignment] = []
    @State private var errorMessage: String?

    private var validationError: String? {
        do {
            try ImpulseResponseAssignmentPlanner().validate(assignments, asset: asset, channels: channels, sampleRate: sampleRate)
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Impulse Response").font(.title2.bold())
            Text("\(asset.displayName) · \(asset.channelCount) WAV channels").foregroundStyle(.secondary)
            Picker("Use", selection: $assignSpeakers) {
                Text("Use one impulse channel").tag(false)
                Text("Assign WAV channels to speakers").tag(true)
            }.pickerStyle(.radioGroup)
            if assignSpeakers {
                Text("Destinations follow physical speaker order. Assigned speakers' existing FIRs will be replaced; unassigned speakers keep their current FIRs.")
                    .font(.caption).foregroundStyle(.secondary)
                if asset.channelCount != channels.count {
                    Label("This WAV has \(asset.channelCount) channels and the profile has \(channels.count) configured speakers. Review the mapping before applying.", systemImage: "info.circle")
                        .font(.caption)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(0..<asset.channelCount, id: \.self) { impulse in
                            HStack {
                                Text("WAV Channel \(impulse + 1)").frame(width: 120, alignment: .leading)
                                Image(systemName: "arrow.right")
                                Picker("Destination for WAV channel \(impulse + 1)", selection: destination(for: impulse)) {
                                    Text("Do not assign").tag(-1)
                                    ForEach(channels) { channel in Text(channel.displayName).tag(channel.index) }
                                }.labelsHidden()
                            }
                        }
                    }
                }.frame(maxHeight: 310)
                if let message = validationError { Text(message).font(.caption).foregroundStyle(.orange) }
            } else {
                Picker("Impulse channel", selection: $impulseChannel) {
                    ForEach(0..<asset.channelCount, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    do {
                        if assignSpeakers { try onAssign(assignments) }
                        else { onSingle(impulseChannel) }
                    } catch { errorMessage = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(assignSpeakers && validationError != nil)
            }
        }
        .padding(24).frame(width: 540)
        .onAppear {
            assignments = ImpulseResponseAssignmentPlanner().defaultAssignments(asset: asset, channels: channels)
        }
    }

    private func destination(for impulse: Int) -> Binding<Int> {
        Binding(get: { assignments.first { $0.impulseChannel == impulse }?.outputChannel ?? -1 }, set: { output in
            assignments.removeAll { $0.impulseChannel == impulse }
            if output >= 0 { assignments.append(.init(impulseChannel: impulse, outputChannel: output)) }
            assignments.sort { $0.impulseChannel < $1.impulseChannel }
            errorMessage = nil
        })
    }
}
