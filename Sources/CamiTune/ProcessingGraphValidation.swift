import Foundation

enum ProcessingGraphValidationError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return "Invalid audio graph: \(reason)" }; return nil }
}

extension ProcessingGraph {
    /// The ordered Camilla pipeline is a sequence of typed buses. Mixers create
    /// new buses; filters keep the current bus width, including expanded paths.
    func resolvedBuses() throws -> [AudioBus] {
        try inputFormat.validate(); try outputFormat.validate()
        guard inputFormat.sampleRate == outputFormat.sampleRate, chunkSize > 0,
              automaticHeadroomDB.isFinite else { throw invalid("inconsistent rates, block size or headroom") }
        guard outputFormat.channels.allSatisfy({ $0.kind == .hardwareSlot && $0.physicalOutputID?.deviceUID == playback.deviceUID }) else {
            throw invalid("output format does not belong to the playback device")
        }
        guard Set(processors.map(\.id)).count == processors.count,
              Set(mixers.map(\.id)).count == mixers.count,
              processors.allSatisfy({ !$0.id.isEmpty }), mixers.allSatisfy({ !$0.id.isEmpty }) else {
            throw invalid("duplicate or empty processor/mixer identity")
        }
        let processorIDs = Set(processors.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: mixers.map { ($0.id, $0) })
        for processor in processors {
            let valid: Bool
            switch processor.implementation {
            case .gain(let db): valid = db.isFinite
            case .biquad(let band):
                valid = band.frequency.isFinite && band.frequency > 0 && band.frequency < Double(sampleRate) / 2
                    && (band.gain?.isFinite ?? true) && (band.q.map { $0.isFinite && $0 > 0 } ?? true)
                    && (band.bandwidth.map { $0.isFinite && $0 > 0 } ?? true)
            case .convolution(let fir): valid = !fir.filePath.isEmpty && fir.channel >= 0 && fir.maximumMagnitudeDB.isFinite
            case .delay(let ms, _): valid = ms.isFinite && (0...100).contains(ms)
            case .firstOrderLowpass(let frequency): valid = frequency.isFinite && frequency > 0 && frequency < Double(sampleRate) / 2
            case .crossfeedGain(let db, _, let boost): valid = db.isFinite && boost.isFinite && boost >= 0
            case .limiter(let limiter): valid = limiter.clipLimitDB.isFinite && limiter.clipLimitDB <= 0
            }
            guard valid else { throw invalid("unsupported parameters for \(processor.id)") }
        }
        for mixer in mixers {
            guard mixer.inputChannelCount > 0, mixer.outputChannelCount > 0,
                  Set(mixer.mappings.map(\.destination)).count == mixer.mappings.count,
                  mixer.mappings.allSatisfy({ mapping in
                      (0..<mixer.outputChannelCount).contains(mapping.destination)
                          && Set(mapping.sources.map(\.channel)).count == mapping.sources.count
                          && mapping.sources.allSatisfy { (0..<mixer.inputChannelCount).contains($0.channel) && $0.gainDB.isFinite }
                  }) else { throw invalid("invalid dimensions or mappings for \(mixer.id)") }
        }
        var buses = [AudioBus(id: .init(rawValue: "capture"), name: "DSP input", format: inputFormat)]
        var width = inputFormat.channelCount
        for (index, step) in pipeline.enumerated() {
            switch step.kind {
            case .filter:
                guard !step.channels.isEmpty, Set(step.channels).count == step.channels.count,
                      step.channels.allSatisfy({ (0..<width).contains($0) }),
                      !step.processorIDs.isEmpty, step.processorIDs.allSatisfy({ processorIDs.contains($0) }) else {
                    throw invalid("filter at step \(index + 1) targets an unavailable channel or processor")
                }
            case .mixer(let id):
                guard let mixer = byID[id], mixer.inputChannelCount == width, mixer.outputChannelCount > 0,
                      step.processorIDs.isEmpty, step.channels.isEmpty else {
                    throw invalid("mixer at step \(index + 1) does not accept its input bus")
                }
                guard Set(mixer.mappings.map(\.destination)).count == mixer.mappings.count else {
                    throw invalid("duplicate mixer destination")
                }
                for mapping in mixer.mappings {
                    guard (0..<mixer.outputChannelCount).contains(mapping.destination),
                          Set(mapping.sources.map(\.channel)).count == mapping.sources.count,
                          mapping.sources.allSatisfy({ (0..<width).contains($0.channel) && $0.gainDB.isFinite }) else {
                        throw invalid("invalid mixer source, destination or gain")
                    }
                }
                width = mixer.outputChannelCount
                let busID = "mixer:\(index):\(id)"
                let format = AudioFormatDescriptor(sampleRate: sampleRate, channels: (0..<width).map {
                    .init(id: .init(rawValue: "\(busID):\($0)"), kind: .internalBus)
                })
                buses.append(AudioBus(id: .init(rawValue: busID), name: id, format: format))
            }
        }
        guard width == outputFormat.channelCount else { throw invalid("final bus width does not match hardware") }
        buses.append(AudioBus(id: .init(rawValue: "playback"), name: "Hardware output", format: outputFormat))
        for bus in buses { try bus.validate() }
        return buses
    }

    func validate() throws { _ = try resolvedBuses() }
    private func invalid(_ reason: String) -> ProcessingGraphValidationError { .invalid(reason) }
}

extension ProcessingGraphBuilder {
    /// Compile explicit N→M routing before physical per-output processing. The
    /// mappings use processing-bus indices; calibration stays keyed by output ID.
    func build(profile: DeviceProfile, inputFormat: AudioFormatDescriptor,
               mappings: [ProcessingGraph.Mixer.Mapping]) throws -> ProcessingGraph {
        try inputFormat.validate()
        guard inputFormat.sampleRate == profile.sampleRate else { throw ProcessingGraphError.invalidSampleRate }
        var graph = try build(profile: profile)
        let width = graph.inputFormat.channelCount
        graph.inputFormat = inputFormat
        let id = "source_to_processing"
        let stage = UUID(uuidString: "AD100000-0000-0000-0000-000000000001")!
        graph.mixers.insert(.init(id: id, sourceStageID: stage, inputChannelCount: inputFormat.channelCount,
            outputChannelCount: width, mappings: mappings), at: 0)
        graph.pipeline.insert(.init(id: stage, kind: .mixer(id: id), scope: .global, channels: [], processorIDs: []), at: 0)
        try graph.validate()
        graph.automaticHeadroomDB = ProcessingGraphHeadroomCalculator().calculate(for: graph,
            excludingGainStageIDs: [ProcessingProfile.userPreampStageID])
        if let index = graph.processors.firstIndex(where: { $0.id == ProcessingGraph.automaticHeadroomProcessorID }) {
            graph.processors[index].implementation = .gain(db: graph.automaticHeadroomDB)
        }
        try graph.validate()
        return graph
    }
}
