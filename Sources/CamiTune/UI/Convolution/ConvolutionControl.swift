import CamiTuneDomain
import SwiftUI

@MainActor
struct ConvolutionControl: View {
    let title: String?
    let context: ConvolutionEditingContext
    @Binding var convolution: ConvolutionProcessor?
    @Binding var isEnabled: Bool
    let onCommit: @MainActor () -> Void
    let onError: @MainActor (Error) -> Void
    @State private var showImporter = false
    @State private var isImporting = false
    @StateObject private var responseOperation = UIBackgroundOperation<[ImpulseResponseChannelAnalysis]>()
    @State private var analyzedAssetID: UUID?
    @State private var channelResponses: [ImpulseResponseChannelAnalysis] = []
    @State private var responseError: String?
    @State private var expandedChannels: Set<Int> = []

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
                Spacer()
                if convolution != nil {
                    Toggle("Enable FIR correction", isOn: Binding(get: { isEnabled }, set: { isEnabled = $0; onCommit() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    Button { convolution = nil; isEnabled = false; onCommit() } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
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
                    channelDetails(name: "WAV Channel \(value.impulseChannel + 1)", channel: value.impulseChannel, asset: value.asset) {
                        EmptyView()
                    }
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
        .onAppear { analyzeResponse() }
        .onChange(of: convolution?.asset) { _ in analyzeResponse() }
        .onDisappear { responseOperation.cancel() }
    }

    private func mappingControls(_ value: ConvolutionProcessor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                channelDetails(name: name, channel: assignment.impulseChannel, asset: value.asset, output: assignment.outputChannel) {
                        HStack(spacing: 12) {
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

    private func channelDetails<Trailing: View>(name: String, channel: Int, asset: ImpulseResponseAsset,
        output: Int = -1, @ViewBuilder controls: @escaping () -> Trailing) -> some View {
        // Keep expansion attached to the output when lazy rows leave the viewport
        // or a different WAV source is selected for the same speaker.
        DisclosureGroup(isExpanded: Binding(get: { expandedChannels.contains(output) }, set: { expanded in
            if expanded { expandedChannels.insert(output) } else { expandedChannels.remove(output) }
        })) {
            if !(0..<asset.channelCount).contains(channel) {
                Label("Select a valid WAV source to see its response.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            } else if analyzedAssetID == asset.id, channelResponses.indices.contains(channel) {
                ConvolutionChannelResponse(analysis: channelResponses[channel], name: name)
            } else if let responseError {
                Text(responseError).font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView("Analyzing impulse response…").controlSize(.small)
            }
        } label: {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 32, alignment: .leading)
        }
        .disclosureGroupStyle(SectionDisclosureStyle(trailing: controls))
    }

    private func analyzeResponse() {
        responseOperation.cancel()
        analyzedAssetID = nil
        channelResponses = []
        responseError = nil
        guard let asset = convolution?.asset else { return }
        responseOperation.run {
            try ImpulseResponseAnalyzer().analyze(asset)
        } completion: { result in
            guard convolution?.asset == asset else { return }
            switch result {
            case .success(let responses):
                analyzedAssetID = asset.id
                channelResponses = responses
            case .failure(let error):
                responseError = error.localizedDescription
            }
        }
    }

    private func assetDetails(_ value: ConvolutionProcessor) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform").font(.title2).foregroundStyle(.blue)
            HStack(spacing: 6) {
                Text(value.asset.displayName).font(.headline)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("\(value.asset.sampleRate) Hz · \(value.asset.frameCount) taps · \(value.asset.channelCount) source channels")
                    .accessibilityLabel("WAV file information")
                    .accessibilityValue("\(value.asset.sampleRate) Hz · \(value.asset.frameCount) taps · \(value.asset.channelCount) source channels")
            }
            Spacer()
        }
    }

    private func imported(_ asset: ImpulseResponseAsset) {
        var processor = ConvolutionProcessor(asset: asset, impulseChannel: 0)
        if supportsCorrespondingChannels,
           let assignments = try? ImpulseResponseAssignmentPlanner().correspondingAssignments(
               asset: asset, channels: context.channels, sampleRate: context.sampleRate) {
            processor.usesCorrespondingChannels = true
            processor.channelAssignments = assignments
        }
        convolution = processor
        isEnabled = true
        onCommit()
    }
}

private struct ConvolutionChannelResponse: View {
    let analysis: ImpulseResponseChannelAnalysis
    let name: String

    private var gainRange: ClosedRange<Double> {
        let gains = analysis.response.map(\.gainDB).filter(\.isFinite)
        guard let lower = gains.min(), let upper = gains.max() else { return -1...1 }
        // Fit this channel's curve, including responses offset from zero. Leave
        // a little breathing room and keep flat filters on a readable scale.
        let padding = max(0.5, (upper - lower) * 0.1)
        return (floor((lower - padding) * 2) / 2)...(ceil((upper + padding) * 2) / 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WrappingControlLayout {
                Text("Peak gain: \(analysis.peakGainDB, format: .number.precision(.fractionLength(2))) dB")
                if let latency = analysis.latencyMilliseconds {
                    Text("Latency: \(latency, format: .number.precision(.fractionLength(2))) ms")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Text("FIR frequency response").font(.caption.weight(.medium))
            LineGraph(points: analysis.response.map { ($0.frequency, $0.gainDB) },
                xRange: (analysis.response.first?.frequency ?? 20)...(analysis.response.last?.frequency ?? 20_000),
                yRange: gainRange, zeroLine: true, lineColor: CorrectionGraphPresentation.equalizerColor)
                .frame(height: 120)
                .accessibilityLabel("\(name) FIR frequency response")
        }
        .padding(.bottom, 8)
    }
}
