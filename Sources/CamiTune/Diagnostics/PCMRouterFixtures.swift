import CamiTuneDomain
import Foundation

extension PCMRouter {
    /// Historical renderer fixtures may omit plan preparation. Production callers
    /// use start() with the acknowledged plan's renderer and delivery values.
    /// A one-frame backend chunk represents the unframed file sinks used by
    /// most fixtures; backend alignment tests supply the actual engine chunk.
    func startFixture(
        camillaSink: FileHandle,
        activeRoute: ActiveAudioRoute? = nil,
        renderConfiguration: RenderConfiguration? = nil,
        deliveryConfiguration: PCMDeliveryConfiguration? = nil,
        backendChunkFrames: Int = 1,
        configurationObserver: (@Sendable (RenderConfiguration) -> Void)? = nil,
        spatialRenderingMode: SpatialRenderingMode = .standard,
        spatialListenerTuning: SpatialListenerTuning = .neutral,
        spatialContentMode: SpatialContentMode = .automatic,
        spatialSettings: SpatialRenderSettings = .init(),
        spatialOutput: SpatialOutputKind = .speakers,
        referenceTopology: SpeakerTopology? = nil,
        playbackMode: PlaybackMode? = nil,
        referenceCorrection: DeviceCorrectionProfile? = nil,
        meterConsumer: MeterConsumer? = nil,
        analyzerConsumer: AnalyzerConsumer? = nil
    ) async {
        let render = renderConfiguration ?? .init(mode: spatialRenderingMode, tuning: spatialListenerTuning,
            content: spatialContentMode, settings: spatialSettings, output: spatialOutput,
            playback: playbackMode ?? (referenceTopology != nil ? .referencePlayback : spatialRenderingMode == .standard ? .direct : .spatialRender),
            correction: referenceCorrection)
        await start(camillaSink: camillaSink, activeRoute: activeRoute,
            renderConfiguration: render,
            deliveryConfiguration: deliveryConfiguration ?? .legacy(sampleRate: Double(activeRoute?.sourceFormat.sampleRate ?? 48_000), chunkSize: 1024),
            backendChunkFrames: backendChunkFrames,
            configurationObserver: configurationObserver, referenceTopology: referenceTopology,
            meterConsumer: meterConsumer, analyzerConsumer: analyzerConsumer)
    }
}

extension RenderConfiguration {
    // Compatibility for isolated renderer fixtures; runtime paths use plans.
    init(mode: SpatialRenderingMode = .standard, tuning: SpatialListenerTuning = .neutral,
         content: SpatialContentMode = .automatic, settings: SpatialRenderSettings = .init(),
         output: SpatialOutputKind = .speakers, playback: PlaybackMode = .direct,
         correction: DeviceCorrectionProfile? = nil) {
        let revision = RuntimeIntentRevision(profileID: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), generation: 0)
        self.init(profile: DeviceProfile(id: revision.profileID, name: "Fixture",
            outputDeviceUID: "fixture-output", outputDeviceName: "Fixture", processing: .defaultStereo), revision: revision)
        spatialRenderingMode = mode == .standard ? .standard : .spatialAudio
        spatialListenerTuning = tuning.validated; spatialContentMode = content
        spatialSettings = settings
        if mode == .frontStage || mode == .virtualSurround { spatialSettings.enabled = true }
        spatialOutput = output; playbackMode = playback; referenceCorrection = correction
        virtualSurroundLayout = .standard
    }
}
