import CamiTuneDomain
import SwiftUI
import AppKit

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
    private func select(_ page: DeviceCorrectionPage) {
        guard selection != page else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        selection = page
    }

    @ViewBuilder
    private var automaticEQ: some View {
        if profile.effectiveEndpointKind == .speakers {
            SpeakerAutoEQEditorView(state: state, profile: $profile)
                .id("\(profile.id)-speaker")
        } else {
            AutoEQCorrectionView(state: state, profile: $profile)
                .id("\(profile.id)-\(profile.effectiveEndpointKind.rawValue)")
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Device Correction").font(.title3.bold())
                AdaptiveEditorLayout {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(pages) { page in
                            Button { select(page) } label: {
                                Text(title(page)).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 9).padding(.vertical, 7)
                                    .background(selected == page ? Color.accentColor.opacity(0.18) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .uiInteractionAnchor("correction-page-\(page.rawValue)")
                            .accessibilityIdentifier("correction-page-\(page.rawValue)")
                            .accessibilityAddTraits(selected == page ? .isSelected : [])
                        }
                    }.accessibilityLabel("Correction method")
                } compactSelector: {
                    Picker("Correction method", selection: Binding(get: { selected }, set: { select($0) })) {
                        ForEach(pages) { page in Text(title(page)).tag(page) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                } content: {
                    SelectedEditorPageLayout(selection: selected == .automaticEQ ? 0 : 1) {
                        // Keep the expensive Auto EQ editor and its unfinished
                        // draft mounted when visiting FIR or Crossfeed.
                        VStack {
                            if pages.contains(.automaticEQ) { automaticEQ }
                        }
                            .opacity(selected == .automaticEQ ? 1 : 0)
                            .allowsHitTesting(selected == .automaticEQ)
                            .accessibilityHidden(selected != .automaticEQ)
                        VStack(alignment: .leading, spacing: 12) {
                            switch selected {
                            case .automaticEQ: EmptyView()
                            case .convolution:
                                DeviceCorrectionSectionHeader(title: "FIR / Convolution",
                                    hint: "Apply an imported impulse response, including externally measured room correction.")
                                if !profile.isPersonalListening {
                                    JoinedSegmentedControl(options: [false, true], selection: $perChannel,
                                        title: { $0 ? "Per Speaker" : "All Speakers" })
                                        .frame(width: 240).accessibilityLabel("FIR correction channels")
                                }
                                if perChannel && !profile.isPersonalListening {
                                    PerChannelProcessingView(state: state, profile: $profile, convolutionOnly: true)
                                } else {
                                    ConvolutionEditorView(state: state, profile: $profile, targetName: "All Channels", showsTitle: false)
                                        .uiInteractionAnchor("correction-fir-all-channels")
                                }
                            case .crossfeed: CrossfeedEditorView(state: state, profile: $profile)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .clipped()
                    .uiInteractionAnchor("correction-content-\(selected.rawValue)")
                }
            }.padding(6)
        }
        .onChange(of: profile.id) { _ in selection = pages.first ?? .convolution; perChannel = false }
    }
}
