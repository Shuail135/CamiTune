import CamiTuneDomain
import Foundation

/// Writer-owned route DSP and format validation. Resource loading, lifecycle,
/// calibration scheduling, queueing, and publication belong to its caller.
package final class RouteRenderer {
    private let activeRoute: ActiveAudioRoute?
    private var directMapper: DirectChannelMapper?
    private let sourceRouter = SpatialSourceRouter()
    private var contentAnalyzer = SpatialContentAnalyzer()
    private let spatialEngine: SpatialAudioEngine
    private var physicalModeRenderer: PhysicalSpeakerModeRenderer?
    private var correctionBank = PerAppFilterBank()
    private var correctionSignature: DeviceCorrectionProfile?
    private var correctionGain: Float = 1
    private var busSafetyGain: Float = 1
    private var lastSourceFormat: SpatialSourceFormat?
    private var renderedModeBuses: Set<PlaybackMode> = []
    private let referenceTopology: SpeakerTopology?
    package let expectedOutputChannelCount: Int

    package init(activeRoute: ActiveAudioRoute?, referenceTopology: SpeakerTopology?, hrtfDatabase: (any HRTFDatabase)?) {
        self.activeRoute = activeRoute
        self.referenceTopology = referenceTopology
        expectedOutputChannelCount = activeRoute?.dspInputFormat.channelCount ?? referenceTopology?.declaredChannelCount ?? 2
        physicalModeRenderer = referenceTopology.flatMap { try? PhysicalSpeakerModeRenderer(topology: $0) }
        spatialEngine = SpatialAudioEngine(hrtfDatabase: hrtfDatabase)
    }

    /// Reads only immutable route values; safe for the control-side admission check.
    package func acceptsCalibrationClip(_ clip: SpatialCalibrationClip) -> Bool {
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
    package var renderDiagnostics: SpatialRenderDiagnostics? { physicalModeRenderer?.spatialDiagnostics ?? spatialEngine.diagnostics }

    package func render(_ frame: PCMFrame, mode: PlaybackMode, settings: SpatialRenderSettings,
                        output: SpatialOutputKind, correction: DeviceCorrectionProfile?,
                        physicalOutput: PhysicalOutputID?, analyzeContent: Bool,
                        resetContent: Bool, resetPCM: Bool, resetSpatial: Bool) -> PCMFrame? {
        if resetContent || resetPCM || resetSpatial || lastSourceFormat != frame.sourceFormat {
            contentAnalyzer.reset()
        }
        if analyzeContent { contentAnalyzer.ingest(frame) }
        else { contentAnalyzer.reset() }
        if resetPCM {
            spatialEngine.reset(); physicalModeRenderer?.reset(); correctionBank = PerAppFilterBank()
            renderedModeBuses.removeAll()
        }
        if resetSpatial {
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
            rendered = renderModeBuses(frame, mode: mode, settings: settings, output: output, correction: correction)
        }
        guard let rendered, rendered.channelCount == expectedOutputChannelCount else { return nil }
        if let activeRoute, (try? activeRoute.validateDSPFrame(rendered)) == nil { return nil }
        return rendered
    }

    private func renderModeBuses(_ frame: PCMFrame, mode: PlaybackMode, settings: SpatialRenderSettings,
                                 output: SpatialOutputKind, correction: DeviceCorrectionProfile?) -> PCMFrame? {
        let modes: [PlaybackMode]
        if frame.playbackModeSamples.isEmpty {
            modes = [mode]
        } else {
            // Continue previously used buses for filter/reverb tails, but do
            // not run unused Reference/Spatial renderers for Direct playback.
            renderedModeBuses.formUnion(frame.playbackModeSamples.keys)
            modes = PlaybackMode.allCases.filter { renderedModeBuses.contains($0) }
        }
        var sum: PCMFrame?
        for busMode in modes {
            var bus = frame
            bus.playbackModeSamples = [:]
            if !frame.playbackModeSamples.isEmpty {
                bus.interleaved = frame.playbackModeSamples[busMode] ?? [Float](repeating: 0, count: frame.interleaved.count)
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
                var enabled = settings; enabled.enabled = true
                rendered = spatialEngine.render(frame: bus, settings: enabled, detectedOutput: output)
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
            if sum == nil { sum = rendered }
            else {
                guard sum!.interleaved.count == rendered.interleaved.count else { return nil }
                for i in rendered.interleaved.indices { sum!.interleaved[i] += rendered.interleaved[i] }
            }
        }
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
