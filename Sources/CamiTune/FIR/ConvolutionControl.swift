import CamiTuneDomain
import SwiftUI

@MainActor
struct ConvolutionControl: View {
    let title: String?
    let context: ConvolutionEditingContext
    @Binding var convolution: ConvolutionProcessor?
    @Binding var isEnabled: Bool
    let onCommit: @MainActor () -> Void
    let onAssign: @MainActor (ImpulseResponseAsset, [ImpulseResponseAssignment]) throws -> Void
    let onError: @MainActor (Error) -> Void
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var assignmentAsset: ImpulseResponseAsset?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || convolution != nil {
                HStack {
                    if let title { Text(title).font(.title3.bold()) }
                    Spacer()
                    if convolution != nil {
                        Toggle("Enable", isOn: Binding(get: { isEnabled }, set: { isEnabled = $0; onCommit() }))
                            .toggleStyle(.switch)
                    }
                }
            }
            if let value = convolution {
                assetDetails(value)
                if value.asset.channelCount > 1 {
                    Picker("Impulse channel", selection: Binding(get: { convolution?.impulseChannel ?? 0 }, set: {
                        convolution?.impulseChannel = $0; onCommit()
                    })) {
                        ForEach(0..<value.asset.channelCount, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                    }.frame(maxWidth: 280)
                }
                if value.asset.sampleRate != context.sampleRate {
                    Label("This WAV does not match the profile's \(context.sampleRate) Hz rate. Replace it before activation.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !(0..<value.asset.channelCount).contains(value.impulseChannel) {
                    Label("Select a valid impulse channel before activation.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Button("Import Impulse Response…") { showImporter = true }
            }
            if isImporting { ProgressView("Analyzing impulse response…").controlSize(.small) }
        }
        .disabled(isImporting)
        .modifier(ConvolutionImporter(isPresented: $showImporter, isImporting: $isImporting,
            context: context, onImported: imported, onError: onError))
        .sheet(isPresented: Binding(get: { assignmentAsset != nil }, set: { if !$0 { assignmentAsset = nil } })) {
            if let asset = assignmentAsset {
                ImpulseResponseAssignmentSheet(asset: asset, channels: context.channels, sampleRate: context.sampleRate,
                    onSingle: { channel in useSingle(asset, channel: channel); assignmentAsset = nil },
                    onAssign: { assignments in try onAssign(asset, assignments); assignmentAsset = nil },
                    onCancel: { assignmentAsset = nil })
            }
        }
        .onChange(of: context) { _ in assignmentAsset = nil }
    }

    private func assetDetails(_ value: ConvolutionProcessor) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform.path").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(value.asset.displayName).font(.headline)
                Text("\(value.asset.sampleRate) Hz · \(value.asset.frameCount) taps · \(value.asset.channelCount) channels")
                    .font(.caption).foregroundStyle(.secondary)
                if let maximum = value.asset.maximumMagnitudeDB(forChannel: value.impulseChannel) {
                    Text("Measured maximum: \(maximum, format: .number.precision(.fractionLength(2))) dB")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu("WAV") {
                Button("Replace WAV…") { showImporter = true }
                if value.asset.channelCount > 1 && !context.channels.isEmpty {
                    Button("Assign to Speakers…") { assignmentAsset = value.asset }
                }
            }.fixedSize()
            Button("Remove", role: .destructive) { convolution = nil; isEnabled = false; onCommit() }
        }
    }

    private func imported(_ asset: ImpulseResponseAsset) {
        if asset.channelCount > 1 && !context.channels.isEmpty { assignmentAsset = asset }
        else { useSingle(asset, channel: 0) }
    }
    private func useSingle(_ asset: ImpulseResponseAsset, channel: Int) {
        convolution = .init(asset: asset, impulseChannel: channel)
        isEnabled = true
        onCommit()
    }
}
