import CamiTuneDomain
import SwiftUI

@MainActor
struct ConvolutionControl: View {
    let title: String?
    let context: ConvolutionEditingContext
    let applicationDescription: String
    @Binding var convolution: ConvolutionProcessor?
    @Binding var isEnabled: Bool
    let onCommit: @MainActor () -> Void
    let onError: @MainActor (Error) -> Void
    @State private var showImporter = false
    @State private var isImporting = false

    private var supportsCorrespondingChannels: Bool {
        if case .profile = context.target { return true }
        return false
    }

    private var sourceSelection: Binding<Int> {
        Binding(get: {
            convolution?.usesCorrespondingChannels == true ? -1 : convolution?.impulseChannel ?? 0
        }, set: { source in
            if source == -1, let value = convolution, value.channelAssignments == nil {
                convolution?.channelAssignments = ImpulseResponseAssignmentPlanner().editableAssignments(
                    for: value, channels: context.channels)
            }
            convolution?.usesCorrespondingChannels = source == -1
            if source >= 0 { convolution?.impulseChannel = source }
            onCommit()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let title { Text(title).font(.title3.bold()) }
                Button("Import WAV…") { showImporter = true }
                    .help(convolution == nil ? "Import an impulse response" : "Replace the impulse response")
                Spacer()
                Toggle("Enable FIR correction", isOn: Binding(get: { isEnabled }, set: { isEnabled = $0; onCommit() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(convolution == nil)
                if convolution != nil {
                    Button { convolution = nil; isEnabled = false; onCommit() } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove impulse response")
                    .accessibilityLabel("Remove impulse response")
                }
            }
            if let value = convolution {
                assetDetails(value)
                if value.asset.channelCount > 1 || supportsCorrespondingChannels {
                    Picker("Source channel", selection: sourceSelection) {
                        if supportsCorrespondingChannels {
                            Text("Apply corresponding WAV channels").tag(-1)
                        }
                        ForEach(0..<value.asset.channelCount, id: \.self) { Text("WAV Channel \($0 + 1)").tag($0) }
                    }.frame(maxWidth: 400)
                }
                if value.usesCorrespondingChannels {
                    mappingControls(value)
                } else {
                    Text(applicationDescription).font(.caption).foregroundStyle(.secondary)
                }
                if value.asset.sampleRate != context.sampleRate {
                    Label("This WAV does not match the profile's \(context.sampleRate) Hz rate. Replace it before activation.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !(0..<value.asset.channelCount).contains(value.impulseChannel) {
                    Label("Select a valid impulse channel before activation.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if isImporting { ProgressView("Analyzing impulse response…").controlSize(.small) }
        }
        .disabled(isImporting)
        .modifier(ConvolutionImporter(isPresented: $showImporter, isImporting: $isImporting,
            context: context, onImported: imported, onError: onError))
    }

    private func mappingControls(_ value: ConvolutionProcessor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a WAV channel for each output. Switch an output off to bypass this FIR correction; its audio keeps playing.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Output").frame(maxWidth: .infinity, alignment: .leading)
                Text("WAV source").frame(width: 170, alignment: .leading)
                Spacer().frame(width: 44)
            }.font(.caption).foregroundStyle(.secondary)
            if context.channels.count > 6 {
                ScrollView {
                    mappingRows(value)
                }.frame(height: 240)
            } else {
                mappingRows(value)
            }
        }
    }

    private func mappingRows(_ value: ConvolutionProcessor) -> some View {
        LazyVStack(spacing: 6) {
            ForEach(ImpulseResponseAssignmentPlanner().editableAssignments(for: value, channels: context.channels)) { assignment in
                let name = context.channels.first { $0.index == assignment.outputChannel }?.displayName
                    ?? "Output \(assignment.outputChannel + 1)"
                HStack(spacing: 12) {
                    Text(name).lineLimit(1).help(name).frame(maxWidth: .infinity, alignment: .leading)
                    Picker("WAV source for \(name)", selection: Binding(get: { assignment.impulseChannel }, set: { source in
                        editMapping(output: assignment.outputChannel) { $0.impulseChannel = source }
                    })) {
                        ForEach(0..<value.asset.channelCount, id: \.self) { Text("WAV Channel \($0 + 1)").tag($0) }
                    }.labelsHidden().frame(width: 170)
                    Toggle("Apply FIR to \(name)", isOn: Binding(get: { assignment.isEnabled }, set: { enabled in
                        editMapping(output: assignment.outputChannel) { $0.isEnabled = enabled }
                    })).toggleStyle(.switch).labelsHidden().controlSize(.small).frame(width: 44)
                }.frame(height: 32)
            }
        }
    }

    private func editMapping(output: Int, update: (inout ImpulseResponseAssignment) -> Void) {
        guard var value = convolution else { return }
        var assignments = value.channelAssignments
            ?? ImpulseResponseAssignmentPlanner().editableAssignments(for: value, channels: context.channels)
        if !assignments.contains(where: { $0.outputChannel == output }) {
            assignments.append(.init(impulseChannel: 0, outputChannel: output, isEnabled: false))
        }
        guard let index = assignments.firstIndex(where: { $0.outputChannel == output }) else { return }
        update(&assignments[index])
        value.channelAssignments = assignments
        convolution = value
        onCommit()
    }

    private func measuredMaximum(_ value: ConvolutionProcessor) -> Double? {
        guard value.usesCorrespondingChannels else { return value.asset.maximumMagnitudeDB(forChannel: value.impulseChannel) }
        return ImpulseResponseAssignmentPlanner().editableAssignments(for: value, channels: context.channels)
            .filter(\.isEnabled).compactMap { value.asset.maximumMagnitudeDB(forChannel: $0.impulseChannel) }.max()
    }

    private func assetDetails(_ value: ConvolutionProcessor) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform.path").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(value.asset.displayName).font(.headline)
                Text("\(value.asset.sampleRate) Hz · \(value.asset.frameCount) taps · \(value.asset.channelCount) source channels")
                    .font(.caption).foregroundStyle(.secondary)
                if let maximum = measuredMaximum(value) {
                    Text("Measured maximum: \(maximum, format: .number.precision(.fractionLength(2))) dB")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func imported(_ asset: ImpulseResponseAsset) {
        // A WAV channel is one IR, not an output assignment. The editor's target
        // determines its destinations; a global FIR broadcasts this same IR.
        convolution = .init(asset: asset, impulseChannel: 0)
        isEnabled = true
        onCommit()
    }
}
