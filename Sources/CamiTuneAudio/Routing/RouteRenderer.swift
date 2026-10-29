import CamiTuneDomain
import Foundation

/// Writer-owned route DSP and format validation. Resource loading, lifecycle,
/// calibration scheduling, queueing, and publication belong to its caller.
package final class RouteRenderer {
    private let activeRoute: ActiveAudioRoute?
    private var directMapper: DirectChannelMapper?
    private let sourceRouter = SpatialSourceRouter()
    private var contentAnalyzer = SpatialContentAnalyzer()
    private let spatialEngine = StereoSpeakerSpatialEngine()
    private var personal: PersonalSpatialTransition?
    private var alignedDirect: [Float] = []
    private var alignedReference: [Float] = []
    private var directDelayCursor = 0, referenceDelayCursor = 0
    package private(set) var retiredPersonalBank: PersonalSpatialRenderBank?
    private var physicalModeRenderer: PhysicalSpeakerModeRenderer?
    private var correctionBank = PerAppFilterBank()
    private var correctionSignature: DeviceCorrectionProfile?
    private var correctionGain: Float = 1
    private var busSafetyGain: Float = 1
    private var lastSourceFormat: SpatialSourceFormat?
    private var renderedModeBuses: Set<ProcessingCohort> = []
    private let directCrossfeed = HeadphoneCrossfeed()
    private let referenceCrossfeed = HeadphoneCrossfeed()
    private var lastSingleMode: PlaybackMode?
    private let referenceTopology: SpeakerTopology?
    package let expectedOutputChannelCount: Int
    private struct DrainContext {
        var template: PCMFrame
        let mode: PlaybackMode
        let settings: SpatialRenderSettings
        let output: SpatialOutputKind
        let correction: DeviceCorrectionProfile?
        let crossfeed: CrossfeedProcessor?
        let bypassCrossfeed: Bool
        let personalSettings: PersonalSpatialSettings?
    }
    private var drainContext: DrainContext?

    /// END authorizes a bounded drain. Finite delays/convolution always finish;
    /// recursive tails settle below -140 dB or stop after one additional second.
    /// Retiring all history afterward prevents replay in the next producer epoch.
    package func finishProducer(discard: Bool, consume: (PCMFrame) throws -> Void) throws {
        defer {
            drainContext = nil
            spatialEngine.reset(); personal?.reset(); physicalModeRenderer?.reset()
            directCrossfeed.reset(); referenceCrossfeed.reset()
            correctionBank = PerAppFilterBank()
            resetAlignment()
            contentAnalyzer.reset(); renderedModeBuses.removeAll()
            lastSingleMode = nil; lastSourceFormat = nil; busSafetyGain = 1
        }
        guard !discard, let context = drainContext else { return }
        let modes = context.template.cohortSamples.isEmpty
            ? Set([ProcessingCohort(context.mode)]) : renderedModeBuses
        guard modes.contains(.spatialRender) || modes.contains(.spatialMovie) || personal != nil || context.crossfeed != nil ||
              (modes.contains(.referencePlayback) && context.correction?.isEnabled == true) else { return }
        let rate = context.template.sampleRate
        // The extra 50 ms covers short delay networks and bypass ramps before
        // silence can establish completion; HRTF gaps cannot end the drain early.
        let minimum = max(personal?.active.tailFrames ?? spatialEngine.finiteTailFrames, Int(ceil(rate * 0.05)))
        let maximum = minimum + Int(ceil(rate))
        var emitted = 0, quietFrames = 0
        while emitted < maximum {
            let count = min(256, maximum - emitted)
            var silence = context.template
            silence.interleaved = .init(repeating: 0, count: count * silence.channelCount)
            for mode in silence.cohortSamples.keys {
                silence.cohortSamples[mode] = silence.interleaved
            }
            guard let frame = render(silence, mode: context.mode, settings: context.settings,
                output: context.output, correction: context.correction, physicalOutput: nil,
                analyzeContent: false, resetContent: false, resetPCM: false, resetSpatial: false,
                crossfeed: context.crossfeed, bypassCrossfeed: context.bypassCrossfeed, personalSettings: context.personalSettings) else { return }
            try consume(frame)
            emitted += count
            quietFrames = frame.interleaved.allSatisfy { abs($0) < 1e-7 } ? quietFrames + count : 0
            if emitted >= minimum && quietFrames >= 512 { break }
        }
    }

    package init(activeRoute: ActiveAudioRoute?, referenceTopology: SpeakerTopology?, personalBank: PersonalSpatialRenderBank?) {
        self.activeRoute = activeRoute
        self.referenceTopology = referenceTopology
        expectedOutputChannelCount = activeRoute?.dspInputFormat.channelCount ?? referenceTopology?.declaredChannelCount ?? 2
        physicalModeRenderer = referenceTopology.flatMap { try? PhysicalSpeakerModeRenderer(topology: $0) }
        if let personalBank {
            personal = PersonalSpatialTransition(personalBank)
            alignedDirect = .init(repeating: 0, count: personalBank.latency * 2)
            alignedReference = alignedDirect
        }
    }

    /// Returns whether a transition must finish before preparing another scene.
    package func installPersonalBank(_ bank: PersonalSpatialRenderBank, sourceIsStopped: Bool) -> Bool {
        if let personal, !sourceIsStopped {
            precondition(personal.replace(bank), "Scene preparation must remain serialized")
            return true
        }
        // A completed source has already drained. A completed/stopped test clip
        // also owns no future input. Publish its replacement without inventing
        // PCM intervals merely to advance a warmup and fade through silence.
        retiredPersonalBank = personal?.active
        personal = PersonalSpatialTransition(bank)
        alignedDirect = .init(repeating: 0, count: bank.latency * 2)
        alignedReference = alignedDirect
        return false
    }
    package var personalIntent: PersonalSpatialRenderIntent? { personal?.active.intent }
    package func takeRetiredPersonalBank() -> PersonalSpatialRenderBank? {
        let bank = retiredPersonalBank; retiredPersonalBank = nil; return bank
    }
    private func resetAlignment() {
        for i in alignedDirect.indices { alignedDirect[i] = 0; alignedReference[i] = 0 }
        directDelayCursor = 0; referenceDelayCursor = 0
    }
    private func align(_ samples: inout [Float], buffer: inout [Float], cursor: inout Int) {
        guard !buffer.isEmpty else { return }
        for i in samples.indices { let x = samples[i]; samples[i] = buffer[cursor]; buffer[cursor] = x; cursor = (cursor + 1) % buffer.count }
    }

    /// Reads only immutable route values; safe for the control-side admission check.
    package func acceptsCalibrationClip(_ clip: SpatialCalibrationClip) -> Bool {
        if let reference = clip.measurementReferenceOutput {
            guard referenceTopology?.endpoints.contains(where: { $0.id == reference && !$0.isSubwooferLike && $0.connectionState != .disabledByUser }) == true,
                  activeRoute.map({ route in route.dspInputFormat.channels.contains { $0.physicalOutputID == reference } }) ?? true else { return false }
        }
        if let activeRoute, clip.sampleRate != Double(activeRoute.dspInputFormat.sampleRate) { return false }
        if let physical = clip.physicalOutput {
            guard physical.deviceUID == referenceTopology?.deviceUID,
                  clip.sampleRate == referenceTopology?.sampleRate,
                  clip.channelCount == referenceTopology?.declaredChannelCount,
                  activeRoute.map({ route in route.dspInputFormat.channels.contains { $0.physicalOutputID == physical } }) ?? true,
                  referenceTopology?.endpoints.contains(where: { $0.id == physical && $0.connectionState != .disabledByUser }) == true else { return false }
        } else if referenceTopology != nil && clip.isAcousticMeasurement {
            return false
        }
        return true
    }

    package var contentEstimate: SpatialContentEstimate { contentAnalyzer.estimate }
    package var referenceDiagnostics: ReferenceSpeakerDiagnostics? { physicalModeRenderer?.diagnostics }
    package var renderDiagnostics: SpatialRenderDiagnostics? { physicalModeRenderer?.spatialDiagnostics ?? personal.map {
        SpatialRenderDiagnostics(renderer: .headphones, algorithmicLatencyFrames: $0.active.latency,
            hrtfProfile: $0.active.ordinary.coefficients.profileName)
    } ?? spatialEngine.diagnostics }

    package func render(_ frame: PCMFrame, mode: PlaybackMode, settings: SpatialRenderSettings,
                        output: SpatialOutputKind, correction: DeviceCorrectionProfile?,
                        physicalOutput: PhysicalOutputID?, analyzeContent: Bool,
                        resetContent: Bool, resetPCM: Bool, resetSpatial: Bool,
                        crossfeed: CrossfeedProcessor? = nil, bypassCrossfeed: Bool = false, personalSettings: PersonalSpatialSettings? = nil, movieScores: MovieContentScores? = nil) -> PCMFrame? {
        if resetContent || resetPCM || resetSpatial || lastSourceFormat != frame.sourceFormat {
            contentAnalyzer.reset()
        }
        if analyzeContent { contentAnalyzer.ingest(frame) }
        else { contentAnalyzer.reset() }
        if resetPCM {
            resetAlignment()
            spatialEngine.reset(); personal?.reset(); physicalModeRenderer?.reset(); correctionBank = PerAppFilterBank()
            renderedModeBuses.removeAll()
        }
        if resetPCM || resetSpatial || bypassCrossfeed || lastSourceFormat != frame.sourceFormat {
            directCrossfeed.reset(); referenceCrossfeed.reset()
            lastSingleMode = nil
        }
        if resetSpatial && personal == nil {
            spatialEngine.reset(); physicalModeRenderer?.reset()
            renderedModeBuses.removeAll()
        }
        lastSourceFormat = frame.sourceFormat
        let rendered: PCMFrame?
        if let physicalOutput {
            // Physical audition is already mapped to hardware channels.
            if physicalOutput.deviceUID == referenceTopology?.deviceUID,
               frame.channelCount == referenceTopology?.declaredChannelCount {
                if let activeRoute { rendered = try? activeRoute.preparePhysicalCompatibilityFrame(frame) }
                else { rendered = frame }
            } else { rendered = nil }
        } else {
            rendered = renderModeBuses(frame, mode: mode, settings: settings, output: output,
                                      correction: correction, crossfeed: crossfeed, bypassCrossfeed: bypassCrossfeed, personalSettings: personalSettings, movieScores: movieScores)
        }
        guard let rendered, rendered.channelCount == expectedOutputChannelCount else { return nil }
        if let activeRoute, (try? activeRoute.validateDSPFrame(rendered)) == nil { return nil }
        if physicalOutput == nil {
            var template = PCMFrame(interleaved: [], channelCount: frame.channelCount,
                                    sampleRate: frame.sampleRate, channelLayout: frame.channelLayout)
            template.cohortSamples = frame.cohortSamples.mapValues { _ in [] }
            drainContext = DrainContext(template: template, mode: mode, settings: settings,
                output: output, correction: correction, crossfeed: crossfeed, bypassCrossfeed: bypassCrossfeed, personalSettings: personalSettings)
        }
        return rendered
    }

    private func renderModeBuses(_ frame: PCMFrame, mode: PlaybackMode, settings: SpatialRenderSettings,
                                 output: SpatialOutputKind, correction: DeviceCorrectionProfile?,
                                 crossfeed: CrossfeedProcessor?, bypassCrossfeed: Bool, personalSettings: PersonalSpatialSettings?, movieScores: MovieContentScores?) -> PCMFrame? {
        let modes: [ProcessingCohort]
        if frame.cohortSamples.isEmpty {
            if lastSingleMode != mode {
                directCrossfeed.reset(); referenceCrossfeed.reset()
            }
            lastSingleMode = mode
            modes = [ProcessingCohort(mode)]
        } else {
            if lastSingleMode != nil {
                directCrossfeed.reset(); referenceCrossfeed.reset()
                lastSingleMode = nil
            }
            // Continue previously used buses for filter/reverb tails, but do
            // not run unused Reference/Spatial renderers for Direct playback.
            renderedModeBuses.formUnion(frame.cohortSamples.keys)
            modes = ProcessingCohort.allCases.filter { renderedModeBuses.contains($0) }
        }
        var sum: PCMFrame?
        for cohort in modes {
            let busMode = cohort.mode
            var bus = frame
            bus.cohortSamples = [:]
            if !frame.cohortSamples.isEmpty {
                bus.interleaved = frame.cohortSamples[cohort] ?? [Float](repeating: 0, count: frame.interleaved.count)
            }
            let rendered: PCMFrame?
            if activeRoute?.usesSourceProcessingBus == true && busMode != .direct { return nil }
            if let route = activeRoute, route.usesPhysicalSpeakerBus, busMode == .direct {
                if directMapper?.sourceLayout != bus.channelLayout {
                    directMapper = try? route.directMapper(for: bus.channelLayout)
                }
                rendered = try? directMapper?.prepare(bus)
            } else if let renderer = physicalModeRenderer {
                let physical = try? renderer.render(bus, mode: busMode, settings: settings)
                if let route = activeRoute, let physical {
                    rendered = try? route.preparePhysicalCompatibilityFrame(physical)
                } else { rendered = physical }
            } else if busMode == .spatialRender {
                if output == .headphones {
                    guard let personal, let personalSettings else { return nil }
                    rendered = personal.render(bus, cohort: cohort, settings: personalSettings, movieScores: movieScores)
                } else {
                    var enabled = settings; enabled.enabled = true
                    rendered = spatialEngine.render(frame: bus, settings: enabled)
                }
            } else {
                rendered = sourceRouter.stereoFallback(for: bus)
            }
            guard var rendered else { return nil }
            if busMode == .referencePlayback, physicalModeRenderer == nil {
                if correctionSignature != correction {
                    correctionSignature = correction
                    correctionGain = Float(pow(10, ReferenceCorrection.headroomDB(correction, sampleRate: frame.sampleRate) / 20))
                    correctionBank = PerAppFilterBank()
                }
                if let correction, correction.isEnabled {
                    correctionBank.process(&rendered.interleaved, channelCount: rendered.channelCount,
                        sampleRate: rendered.sampleRate, bands: correction.filters, settingsRevision: 0)
                    for i in rendered.interleaved.indices { rendered.interleaved[i] *= correctionGain }
                }
            }
            // Apply only to personal stereo buses, before summing them with
            // HRTF output. Each bus owns its history, including during bypass.
            if !bypassCrossfeed, rendered.channelCount == 2, physicalModeRenderer == nil,
               activeRoute?.usesPhysicalSpeakerBus != true, busMode != .spatialRender {
                let processor = busMode == .referencePlayback ? referenceCrossfeed : directCrossfeed
                processor.process(&rendered.interleaved, sampleRate: rendered.sampleRate, settings: crossfeed)
            }
            if personal != nil && busMode != .spatialRender {
                if busMode == .direct { align(&rendered.interleaved, buffer: &alignedDirect, cursor: &directDelayCursor) }
                else { align(&rendered.interleaved, buffer: &alignedReference, cursor: &referenceDelayCursor) }
            }
            if sum == nil { sum = rendered }
            else {
                guard sum!.interleaved.count == rendered.interleaved.count else { return nil }
                for i in rendered.interleaved.indices { sum!.interleaved[i] += rendered.interleaved[i] }
            }
        }
        if let retired = personal?.finishInterval(frames: frame.frameCount) { retiredPersonalBank = retired }
        guard var result = sum else { return nil }
        // Linked sample-wise safety after summing buses, with release independent of block size.
        let release = Float(1 - exp(-1 / (frame.sampleRate * 0.2)))
        for f in 0..<result.frameCount {
            let offset = f * result.channelCount
            var peak: Float = 1
            for c in 0..<result.channelCount { peak = max(peak, abs(SpatialSafety.sample(result.interleaved[offset + c]))) }
            let target = 1 / peak
            busSafetyGain = target < busSafetyGain ? target : busSafetyGain + release * (target - busSafetyGain)
            for c in 0..<result.channelCount { result.interleaved[offset + c] = SpatialSafety.sample(result.interleaved[offset + c]) * busSafetyGain }
        }
        return result
    }
}
