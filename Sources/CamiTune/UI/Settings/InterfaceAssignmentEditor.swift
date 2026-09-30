import CamiTuneDomain
import SwiftUI
import AppKit

@MainActor
struct InterfaceAssignmentEditor: View {
    let state: AppState
    let output: PhysicalOutputIdentity
    let sampleRate: Int
    @Binding var assignment: AudioInterfaceConfiguration?
    @Binding var topology: SpeakerTopology?
    @State private var discovering = false
    @State private var error: String?
    private var matches: Bool { assignment?.deviceUID == output.uid }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !matches { Text("Discover this interface to configure its channels.").foregroundStyle(.secondary) }
            if let value = assignment, matches {
                Picker("Connected Device", selection: Binding(get: { value.connectedEndpoint }, set: { assignment?.connectedEndpoint = $0 })) {
                    ForEach(ProfileEndpointKind.allCases.filter { $0 != .audioInterface }, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Hardware Channels").font(.headline)
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(0..<value.hardwareChannelCount, id: \.self) { index in
                            Toggle("Channel \(index + 1)", isOn: Binding(
                                get: { assignment?.hardware.enabledHardwareOutputs.contains(index) == true },
                                set: { selected in
                                    guard var next = assignment else { return }
                                    if selected { next.hardware.enabledHardwareOutputs.insert(index) }
                                    else { next.hardware.enabledHardwareOutputs.remove(index) }
                                    next.finishMigration()
                                    assignment = next
                                    if let endpoint = topology?.endpoints.firstIndex(where: { $0.id.channelIndex == index }) {
                                        topology?.endpoints[endpoint].connectionState = selected ? .confirmedByUser : .disabledByUser
                                    }
                                }))
                        }
                    }
                }.frame(maxHeight: 180)
                if value.connectedEndpoint != .speakers {
                    stereoAssignment(.left, title: "Left")
                    stereoAssignment(.right, title: "Right")
                }
                if let problem = validationProblem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Discover Channels") { discover() }.disabled(discovering)
                if discovering { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
    }
    private var validationProblem: String? {
        do { try assignment?.validate(deviceUID: output.uid); return nil }
        catch { return error.localizedDescription }
    }

    private func stereoAssignment(_ role: ChannelRole, title: String) -> some View {
        Picker(title, selection: Binding<Int?>(get: {
            topology?.endpoints.first {
                $0.role == role && assignment?.hardware.enabledHardwareOutputs.contains($0.id.channelIndex) == true
            }?.id.channelIndex
        }, set: { physical in
            guard var topology else { return }
            for index in topology.endpoints.indices where topology.endpoints[index].role == role {
                topology.endpoints[index].role = .unknown
            }
            if let physical, let endpoint = topology.endpoints.first(where: { $0.id.channelIndex == physical }) {
                SpeakerLayoutGeometry.setRole(role, for: endpoint.id, in: &topology)
            }
            self.topology = topology
        })) {
            Text("Choose an output").tag(Int?.none)
            ForEach(assignment?.hardware.enabledHardwareOutputs.sorted() ?? [], id: \.self) {
                Text("Output \($0 + 1)").tag(Optional($0))
            }
        }
    }
    private func discover() {
        discovering = true; error = nil
        let requested = output
        Task {
            defer { discovering = false }
            do {
                guard let device = await state.coreAudioService.resolveDeviceWithoutBlockingUI(uid: requested.uid) else { throw SpeakerTopologyError.invalidDeviceUID }
                var found = try await state.coreAudioService.probeSpeakerTopology(uid: device.id)
                guard output.uid == requested.uid else { return }
                found.sampleRate = Double(sampleRate)
                if assignment?.deviceUID != requested.uid || assignment?.hardwareChannelCount != found.declaredChannelCount {
                    assignment = AudioInterfaceConfiguration(hardware: HardwareOutputConfiguration(deviceUID: requested.uid,
                        hardwareChannelCount: found.declaredChannelCount, enabledHardwareOutputs: []), connectedEndpoint: .custom)
                }
                if topology == nil || (try? topology?.validateHardware(found)) == nil {
                    topology = SpeakerLayoutGeometry.arrangedForEditing(found, previous: topology)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
