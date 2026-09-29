import CamiTuneDomain
import SwiftUI

@MainActor
struct DeviceCorrectionSectionView: View {
    let state: AppState
    @Binding var profile: DeviceProfile
    @State private var selection: DeviceCorrectionPage = .automaticEQ
    @State private var perChannel = false
    private var pages: [DeviceCorrectionPage] { profile.availableDeviceCorrectionPages }
    private var selected: DeviceCorrectionPage { pages.contains(selection) ? selection : .convolution }
    private func title(_ page: DeviceCorrectionPage) -> String {
        switch page {
        case .automaticEQ: return "Auto EQ"
        case .convolution: return "FIR / Convolution"
        case .crossfeed: return "Crossfeed"
        }
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Device Correction").font(.title3.bold())
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(pages) { page in
                            Button { selection = page } label: {
                                Text(title(page)).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 9).padding(.vertical, 7)
                                    .background(selected == page ? Color.accentColor.opacity(0.18) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityAddTraits(selected == page ? .isSelected : [])
                        }
                    }.frame(width: 160).accessibilityLabel("Correction method")
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        switch selected {
                        case .automaticEQ:
                            if profile.effectiveEndpointKind == .speakers {
                                SpeakerAutoEQEditorView(state: state, profile: $profile)
                                    .id("\(profile.id)-speaker")
                            } else {
                                AutoEQCorrectionView(state: state, profile: $profile)
                                    .id("\(profile.id)-\(profile.effectiveEndpointKind.rawValue)")
                            }
                        case .convolution:
                            DeviceCorrectionSectionHeader(title: "FIR / Convolution",
                                hint: "Apply an imported impulse response, including externally measured room correction.")
                            if profile.isPersonalListening {
                                DisclosureGroup("Advanced") {
                                    Toggle("Use different impulse responses for Left / Right", isOn: $perChannel)
                                }
                            } else {
                                JoinedSegmentedControl(options: [false, true], selection: $perChannel,
                                    title: { $0 ? "Per Speaker" : "All Speakers" })
                                    .frame(width: 240).accessibilityLabel("FIR correction channels")
                            }
                            if perChannel {
                                PerChannelProcessingView(state: state, profile: $profile, convolutionOnly: true)
                            } else {
                                ConvolutionEditorView(state: state, profile: $profile, targetName: "All Channels", showsTitle: false)
                            }
                        case .crossfeed: CrossfeedEditorView(state: state, profile: $profile)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true)
            }.padding(6)
        }
        .onChange(of: profile.id) { _ in selection = pages.first ?? .convolution; perChannel = false }
    }
}
