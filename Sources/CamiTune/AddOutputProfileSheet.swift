import SwiftUI

@MainActor
struct AddOutputProfileSheet: View {
    @ObservedObject var coreAudio: CoreAudioManager
    @Binding var selectedUID: String?
    let onCancel: @MainActor () -> Void
    let onAdd: @MainActor () -> Void

    private var devices: [AudioDeviceInfo] {
        coreAudio.physicalOutputDevices
    }

    private var selectedDevice: AudioDeviceInfo? {
        devices.first(where: { $0.id == selectedUID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Add Output Profile")
                .font(.largeTitle.bold())
            Text("Choose the physical audio device that this profile will play through.")
                .foregroundStyle(.secondary)

            GroupBox {
                if devices.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "speaker.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No physical audio outputs are connected.")
                            .font(.headline)
                        Text("Connect an output device, then try again.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(selection: $selectedUID) {
                        ForEach(devices) { device in
                            HStack(spacing: 12) {
                                Image(systemName: "speaker.wave.2")
                                    .frame(width: 24)
                                Text(device.name)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .tag(device.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            } label: {
                Text("Audio outputs")
                    .font(.title3.bold())
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Profile") {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedDevice == nil)
            }
        }
        .padding(32)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 440, idealHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
