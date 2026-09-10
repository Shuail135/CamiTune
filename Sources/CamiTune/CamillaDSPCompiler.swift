import Foundation

struct CamillaDSPConfiguration: Hashable, Sendable {
    var yaml: String
}

struct CamillaDSPRuntimePatch: Hashable, Sendable {
    var filters: [String: Filter]

    struct Filter: Hashable, Sendable {
        var type: String
        var parameters: [String: Parameter]
    }

    enum Parameter: Hashable, Sendable {
        case number(Double)
        case integer(Int)
        case boolean(Bool)
        case string(String)
        case null

        var foundationValue: Any {
            switch self {
            case .number(let value): return value
            case .integer(let value): return value
            case .boolean(let value): return value
            case .string(let value): return value
            case .null: return NSNull()
            }
        }
    }

    /// JSON Merge Patch payload accepted by CamillaDSP's PatchConfig command.
    var foundationObject: [String: Any] {
        [
            "filters": filters.mapValues { filter in
                [
                    "type": filter.type,
                    "parameters": filter.parameters.mapValues(\.foundationValue)
                ] as [String: Any]
            }
        ]
    }
}

/// The only layer that knows how a ProcessingGraph maps to CamillaDSP's full
/// configuration and runtime filter-patch formats.
struct CamillaDSPCompiler: Sendable {
    func compile(_ graph: ProcessingGraph) -> CamillaDSPConfiguration {
        let filters = graph.processors.map(yamlFilter)
        let filterSection = filters.isEmpty
            ? "filters: {}"
            : "filters:\n" + filters.joined(separator: "\n")
        let mixers = graph.mixers.map(yamlMixer)
        let mixerSection = mixers.isEmpty
            ? "mixers: {}"
            : "mixers:\n" + mixers.joined(separator: "\n")

        let pipelineSection: String
        if graph.pipeline.isEmpty {
            pipelineSection = "pipeline: []"
        } else {
            pipelineSection = "pipeline:\n" + graph.pipeline.map { step in
                switch step.kind {
                case .filter:
                    return """
  - type: Filter
    channels: [\(step.channels.map(String.init).joined(separator: ", "))]
    names:
\(step.processorIDs.map { "      - \($0)" }.joined(separator: "\n"))
"""
                case .mixer(let mixerID):
                    return """
  - type: Mixer
    name: \(mixerID)
"""
                }
            }.joined(separator: "\n")
        }

        return CamillaDSPConfiguration(yaml: """
---
title: "\(yamlEscape(graph.title))"
devices:
  samplerate: \(graph.sampleRate)
  chunksize: \(graph.chunkSize)
  # CamiTune's PCM writer owns the sample-continuous system-volume ramp.
  # Camilla's RPC master stays at 0 dB during keyboard changes so media-key
  # repeats never enter its control socket or rebuild the processing graph.
  volume_ramp_time: 80.0
  volume_limit: 0.0
  capture:
    type: Stdin
    channels: \(graph.channelCount)
    format: \(captureFormat(graph.capture.format))
  playback:
    type: CoreAudio
    channels: \(graph.channelCount)
    device: "\(yamlEscape(graph.playback.deviceUID))"
    exclusive: \(graph.playback.exclusive)
\(filterSection)
\(mixerSection)
\(pipelineSection)
""")
    }

    func compileRuntimePatch(
        processors: [ProcessingGraph.Processor]
    ) -> CamillaDSPRuntimePatch {
        CamillaDSPRuntimePatch(filters: Dictionary(
            processors.map { ($0.id, runtimeFilter($0)) },
            uniquingKeysWith: { _, latest in latest }
        ))
    }

    private func runtimeFilter(
        _ processor: ProcessingGraph.Processor
    ) -> CamillaDSPRuntimePatch.Filter {
        switch processor.implementation {
        case .gain(let db):
            return .init(
                type: "Gain",
                parameters: ["gain": .number(db), "scale": .string("dB")]
            )
        case .biquad(let band):
            var parameters: [String: CamillaDSPRuntimePatch.Parameter] = [
                "type": .string(camillaType(band.kind)),
                "freq": .number(band.frequency),
                // JSON Merge Patch preserves keys that are omitted. Explicit
                // nulls remove parameters left behind by the previous kind.
                "gain": .null,
                "q": .null,
                "bandwidth": .null
            ]
            if usesGain(band.kind), let gain = band.gain {
                parameters["gain"] = .number(gain)
            }
            if let q = band.q { parameters["q"] = .number(q) }
            else if let bandwidth = band.bandwidth {
                parameters["bandwidth"] = .number(bandwidth)
            } else if needsDefaultQ(band.kind) {
                parameters["q"] = .number(0.70710678)
            }
            return .init(type: "Biquad", parameters: parameters)
        case .convolution(let convolution):
            return .init(
                type: "Conv",
                parameters: [
                    "type": .string("Wav"),
                    "filename": .string(convolution.filePath),
                    "channel": .integer(convolution.channel)
                ]
            )
        case .delay(let milliseconds, let subsample):
            return .init(
                type: "Delay",
                parameters: [
                    "delay": .number(milliseconds),
                    "unit": .string("ms"),
                    "subsample": .boolean(subsample)
                ]
            )
        case .firstOrderLowpass(let frequency):
            return .init(
                type: "Biquad",
                parameters: [
                    "type": .string("LowpassFO"),
                    "freq": .number(frequency)
                ]
            )
        case .crossfeedGain(let db, let muted, _):
            return .init(
                type: "Gain",
                parameters: [
                    "gain": .number(db),
                    "scale": .string("dB"),
                    "mute": .boolean(muted)
                ]
            )
        case .limiter(let limiter):
            return .init(
                type: "Limiter",
                parameters: [
                    "soft_clip": .boolean(limiter.softClip),
                    "clip_limit": .number(limiter.clipLimitDB)
                ]
            )
        }
    }

    private func yamlFilter(_ processor: ProcessingGraph.Processor) -> String {
        switch processor.implementation {
        case .gain(let db):
            return """
  \(processor.id):
    type: Gain
    parameters:
      gain: \(format(db))
      scale: dB
"""
        case .biquad(let band):
            var lines = [
                "  \(processor.id):",
                "    type: Biquad",
                "    parameters:",
                "      type: \(camillaType(band.kind))",
                "      freq: \(format(band.frequency))"
            ]
            if usesGain(band.kind), let gain = band.gain {
                lines.append("      gain: \(format(gain))")
            }
            if let q = band.q { lines.append("      q: \(format(q))") }
            else if let bandwidth = band.bandwidth {
                lines.append("      bandwidth: \(format(bandwidth))")
            } else if needsDefaultQ(band.kind) {
                lines.append("      q: 0.70710678")
            }
            return lines.joined(separator: "\n") + "\n"
        case .convolution(let convolution):
            return """
  \(processor.id):
    type: Conv
    parameters:
      type: Wav
      filename: "\(yamlEscape(convolution.filePath))"
      channel: \(convolution.channel)
"""
        case .delay(let milliseconds, let subsample):
            return """
  \(processor.id):
    type: Delay
    parameters:
      delay: \(format(milliseconds))
      unit: ms
      subsample: \(subsample)
"""
        case .firstOrderLowpass(let frequency):
            return """
  \(processor.id):
    type: Biquad
    parameters:
      type: LowpassFO
      freq: \(format(frequency))
"""
        case .crossfeedGain(let db, let muted, _):
            return """
  \(processor.id):
    type: Gain
    parameters:
      gain: \(format(db))
      scale: dB
      mute: \(muted)
"""
        case .limiter(let limiter):
            return """
  \(processor.id):
    type: Limiter
    parameters:
      soft_clip: \(limiter.softClip)
      clip_limit: \(format(limiter.clipLimitDB))
"""
        }
    }

    private func yamlMixer(_ mixer: ProcessingGraph.Mixer) -> String {
        let mappings = mixer.mappings.map { mapping in
            let sources = mapping.sources.map { source in
                """
          - channel: \(source.channel)
            gain: \(format(source.gainDB))
            scale: dB
"""
            }.joined(separator: "\n")
            return """
      - dest: \(mapping.destination)
        sources:
\(sources)
"""
        }.joined(separator: "\n")
        return """
  \(mixer.id):
    channels:
      in: \(mixer.inputChannelCount)
      out: \(mixer.outputChannelCount)
    mapping:
\(mappings)
"""
    }

    private func captureFormat(_ format: ProcessingGraph.SampleFormat) -> String {
        switch format {
        case .interleavedFloat32LittleEndian: return "F32_LE"
        }
    }

    private func camillaType(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "Peaking"
        case .lowShelf: return "Lowshelf"
        case .highShelf: return "Highshelf"
        case .lowPass: return "Lowpass"
        case .highPass: return "Highpass"
        case .notch: return "Notch"
        case .allPass: return "Allpass"
        }
    }

    private func needsDefaultQ(_ kind: EQBand.Kind) -> Bool {
        [.lowShelf, .highShelf, .lowPass, .highPass, .notch].contains(kind)
    }

    private func usesGain(_ kind: EQBand.Kind) -> Bool {
        [.peaking, .lowShelf, .highShelf].contains(kind)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func yamlEscape(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x00: result += "\\0"
            case 0x07: result += "\\a"
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0B: result += "\\v"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x1B: result += "\\e"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x01...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
                result += String(
                    format: "\\u%04X",
                    locale: Locale(identifier: "en_US_POSIX"),
                    scalar.value
                )
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// Source-compatible adapter for integrations that still provide a parsed APO
/// document. New code should build a ProcessingGraph and use CamillaDSPCompiler.
@available(*, deprecated, message: "Build a ProcessingGraph and use CamillaDSPCompiler")
struct CamillaConfigBuilder {
    func build(profile: DeviceProfile, parsed: ParsedEQ) -> String {
        var migrated = profile
        migrated.setGlobalEqualizer(
            preampDB: parsed.preampDB,
            bands: parsed.bands
        )
        do {
            let graph = try ProcessingGraphBuilder(channelCount: migrated.processingChannelCount).build(profile: migrated)
            return CamillaDSPCompiler().compile(graph).yaml
        } catch {
            assertionFailure("Invalid processing graph: \(error.localizedDescription)")
            return ""
        }
    }
}
