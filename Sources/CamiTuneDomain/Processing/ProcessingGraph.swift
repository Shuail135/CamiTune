import Foundation

package struct ProcessingGraph: Hashable, Sendable {
    package static let automaticHeadroomStageID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 1
    ))
    package static let automaticHeadroomProcessorID = "system_automatic_headroom"

    package var title: String
    package var inputFormat: AudioFormatDescriptor
    package var outputFormat: AudioFormatDescriptor
    package var sampleRate: Int {
        get { inputFormat.sampleRate }
        set {
            inputFormat = .init(sampleRate: newValue, channels: inputFormat.channels)
            outputFormat = .init(sampleRate: newValue, channels: outputFormat.channels)
        }
    }
    package var chunkSize: Int
    /// Backend projection of the runtime plan's delivery configuration.
    package var camillaQueueLimit: Int = 4
    /// Compatibility spelling for capture width. Hardware width is outputFormat.
    package var channelCount: Int { inputFormat.channelCount }
    package var capture: CaptureEndpoint
    package var playback: PlaybackEndpoint {
        didSet {
            if playback.channelCount != oldValue.channelCount || playback.deviceUID != oldValue.deviceUID {
                outputFormat = Self.hardwareFormat(sampleRate: sampleRate, deviceUID: playback.deviceUID,
                    count: playback.channelCount ?? outputFormat.channelCount)
            }
        }
    }
    /// Runtime-only protection derived from response-shaping and per-channel
    /// processing. Intentional user-preamp gain is kept independent, and this
    /// value is deliberately not part of the persisted processing profile.
    package var automaticHeadroomDB: Double
    package var processors: [Processor]
    package var mixers: [Mixer]
    package var pipeline: [PipelineStep]

    package init(title: String, sampleRate: Int, chunkSize: Int, channelCount: Int,
         capture: CaptureEndpoint, playback: PlaybackEndpoint, automaticHeadroomDB: Double,
         processors: [Processor], mixers: [Mixer], pipeline: [PipelineStep],
         inputFormat: AudioFormatDescriptor? = nil, outputFormat: AudioFormatDescriptor? = nil) {
        self.title = title; self.chunkSize = chunkSize; self.capture = capture; self.playback = playback
        self.inputFormat = inputFormat ?? .init(sampleRate: sampleRate, channels: (0..<max(0, channelCount)).map {
            .init(id: .source($0), kind: .source)
        })
        self.outputFormat = outputFormat ?? Self.hardwareFormat(sampleRate: sampleRate,
            deviceUID: playback.deviceUID, count: playback.channelCount ?? channelCount)
        self.automaticHeadroomDB = automaticHeadroomDB; self.processors = processors
        self.mixers = mixers; self.pipeline = pipeline
    }

    private static func hardwareFormat(sampleRate: Int, deviceUID: String, count: Int) -> AudioFormatDescriptor {
        .init(sampleRate: sampleRate, channels: (0..<max(0, count)).map {
            let id = PhysicalOutputID(deviceUID: deviceUID, channelIndex: $0)
            return .init(id: .hardware(id), kind: .hardwareSlot, physicalOutputID: id)
        })
    }

    package struct CaptureEndpoint: Hashable, Sendable {
        package init(format: SampleFormat) {
            self.format = format
        }

        package var format: SampleFormat
    }

    package struct PlaybackEndpoint: Hashable, Sendable {
        package init(deviceUID: String, channelCount: Int? = nil, exclusive: Bool) {
            self.deviceUID = deviceUID
            self.channelCount = channelCount
            self.exclusive = exclusive
        }

        package var deviceUID: String
        package var channelCount: Int? = nil
        package var exclusive: Bool
    }

    package enum SampleFormat: String, Hashable, Sendable {
        case interleavedFloat32LittleEndian
    }

    package struct Processor: Identifiable, Hashable, Sendable {
        package init(id: String, sourceStageID: UUID, implementation: Implementation) {
            self.id = id
            self.sourceStageID = sourceStageID
            self.implementation = implementation
        }

        package var id: String
        package var sourceStageID: UUID
        package var implementation: Implementation

        package enum Implementation: Hashable, Sendable {
            case gain(db: Double)
            case biquad(EQBand)
            case convolution(Convolution)
            case delay(milliseconds: Double, subsample: Bool)
            case firstOrderLowpass(frequency: Double)
            case crossfeedGain(db: Double, muted: Bool, maximumBoostDB: Double)
            case limiter(LimiterProcessor)

            package struct Convolution: Hashable, Sendable {
                package init(filePath: String, channel: Int, maximumMagnitudeDB: Double, contentSHA256: String? = nil) {
                    self.filePath = filePath
                    self.channel = channel
                    self.maximumMagnitudeDB = maximumMagnitudeDB
                    self.contentSHA256 = contentSHA256
                }

                package var filePath: String
                package var channel: Int
                package var maximumMagnitudeDB: Double
                package var contentSHA256: String? = nil
            }
        }
    }

    package struct Mixer: Identifiable, Hashable, Sendable {
        package init(
            id: String,
            sourceStageID: UUID,
            inputChannelCount: Int,
            outputChannelCount: Int,
            mappings: [Mapping]
        ) {
            self.id = id
            self.sourceStageID = sourceStageID
            self.inputChannelCount = inputChannelCount
            self.outputChannelCount = outputChannelCount
            self.mappings = mappings
        }

        package var id: String
        package var sourceStageID: UUID
        package var inputChannelCount: Int
        package var outputChannelCount: Int
        package var mappings: [Mapping]

        package struct Mapping: Hashable, Sendable {
            package init(destination: Int, sources: [Source]) {
                self.destination = destination
                self.sources = sources
            }

            package var destination: Int
            package var sources: [Source]
        }

        package struct Source: Hashable, Sendable {
            package init(channel: Int, gainDB: Double = 0, inverted: Bool = false, muted: Bool = false) {
                self.channel = channel
                self.gainDB = gainDB
                self.inverted = inverted
                self.muted = muted
            }

            package var channel: Int
            package var gainDB: Double = 0
            package var inverted = false
            package var muted = false
        }
    }

    package struct PipelineStep: Identifiable, Hashable, Sendable {
        package init(id: UUID, kind: Kind = .filter, scope: Scope, channels: [Int], processorIDs: [String]) {
            self.id = id
            self.kind = kind
            self.scope = scope
            self.channels = channels
            self.processorIDs = processorIDs
        }

        package var id: UUID
        package var kind: Kind = .filter
        package var scope: Scope
        package var channels: [Int]
        package var processorIDs: [String]

        package enum Kind: Hashable, Sendable {
            case filter
            case mixer(id: String)
        }

        package enum Scope: Hashable, Sendable {
            case global
            case channel(index: Int, role: ChannelRole)
            case group(SpeakerGroupID)
        }
    }
}
