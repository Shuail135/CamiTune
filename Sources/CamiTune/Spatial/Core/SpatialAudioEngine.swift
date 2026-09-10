import Foundation

/// Confined to the PCM writer worker. No UI thread may mutate its DSP state.
final class SpatialAudioEngine {
    private var binauralBanks: [Double: VirtualSpeakerBinauralizer] = [:]
    private var binaural: VirtualSpeakerBinauralizer?
    private var binauralIsRunning = false
    private var discreteBlend = SpatialScalarSmoother()
    private let hrtfProfile: String?
    private let headphones = HeadphoneSpatialRenderer()
    private let speakers = SpeakerSpatialRenderer()
    private let downmixer = MovieDownmixer()
    private let seatAligner = SpatialSeatAligner()
    private let energy = ChannelEnergyDetector()
    private var layout: LPCMChannelLayout?
    private var mapper = SemanticChannelMapper(layout: .stereo)
    private var rate: Double = 0
    private var content: SpatialContentKind = .music
    private var candidate: SpatialContentKind = .music
    private var candidateSeconds: Double = 0
    private var amount = SpatialScalarSmoother()
    private var cinema = SpatialScalarSmoother()
    private var headphoneMix = SpatialScalarSmoother()
    private var dialogue = SpatialScalarSmoother()
    private var safety = SpatialPeakSafety()
    private(set) var diagnostics = SpatialRenderDiagnostics()

    /// PCMRouter constructs this on its lifecycle worker, before starting audio.
    /// All six HRTF banks are prepared here, never during per-frame rendering.
    init(hrtfDatabase: BundledHRTFDatabase? = BundledHRTFDatabase.shared) {
        hrtfProfile = hrtfDatabase?.manifest.name
        if let database = hrtfDatabase {
            for rate in database.manifest.rates {
                binauralBanks[rate.sampleRate] = try? VirtualSpeakerBinauralizer(database: database, sampleRate: rate.sampleRate)
            }
        }
    }

    func reset() {
        binaural?.reset(); binaural = nil; binauralIsRunning = false; discreteBlend.reset()
        seatAligner.reset()
        headphones.reset(); speakers.reset(); downmixer.reset(); safety.reset()
        amount.reset(); cinema.reset(); dialogue.reset(); headphoneMix.reset()
        content = .music; candidate = .music; candidateSeconds = 0
        layout = nil; rate = 0
        diagnostics = SpatialRenderDiagnostics()
    }

    func render(frame: PCMFrame, settings: SpatialRenderSettings,
                detectedOutput: SpatialOutputKind) -> PCMFrame? {
        guard frame.channelCount > 0, frame.channelCount <= 32,
              frame.channelLayout.channelCount == frame.channelCount,
              frame.interleaved.count.isMultiple(of: frame.channelCount),
              frame.sampleRate.isFinite, (8000...384000).contains(frame.sampleRate) else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        let output: SpatialOutputKind
        switch settings.outputSelection {
        case .automatic: output = detectedOutput
        case .headphones: output = .headphones
        case .speakers: output = .speakers
        }
        if rate != frame.sampleRate || layout != frame.channelLayout {
            reset()
            rate = frame.sampleRate; layout = frame.channelLayout
            mapper = SemanticChannelMapper(layout: frame.channelLayout)
            binaural = binauralBanks[rate]
            binaural?.configure(layout: frame.channelLayout)
            discreteBlend.prepare(sampleRate: rate)
            seatAligner.prepare(sampleRate: rate)
            headphones.prepare(sampleRate: rate); speakers.prepare(sampleRate: rate)
            downmixer.prepare(sampleRate: rate); safety.prepare(rate: rate)
            amount.prepare(sampleRate: rate)
            dialogue.prepare(sampleRate: rate)
            cinema.prepare(sampleRate: rate, seconds: 0.15)
            headphoneMix.prepare(sampleRate: rate, seconds: 0.15)
            headphoneMix.reset(to: output == .headphones ? 1 : 0)
        }
        guard frame.frameCount > 0 else {
            return PCMFrame(interleaved: [], channelCount: 2, sampleRate: rate,
                            sourceBufferedFrames: frame.sourceBufferedFrames,
                            sourceCapacityFrames: frame.sourceCapacityFrames)
        }
        let hasDiscreteContent = energy.hasDiscreteContent(frame)
        switch settings.contentSelection {
        case .music: content = .music; candidateSeconds = 0
        case .cinema: content = .cinema; candidateSeconds = 0
        case .automatic:
            let next: SpatialContentKind = hasDiscreteContent ? .cinema : .music
            if next != candidate { candidate = next; candidateSeconds = 0 }
            candidateSeconds += Double(frame.frameCount) / rate
            if candidateSeconds >= 3 { content = candidate }
        }
        let context = SpatialRenderContext(output: output, content: content,
            amount: settings.enabled ? SpatialSafety.unit(content == .music ? settings.music.amount : settings.cinema.amount) : 0,
            dialogueFocus: settings.enabled && content == .cinema ? SpatialSafety.unit(settings.cinema.dialogueFocus) : 0,
            channelLayout: frame.channelLayout, sampleRate: rate)
        let seat = settings.seating
        let alignment = settings.enabled && seat?.enabled == true && output == .speakers
            ? seat!.alignment : (leftDelay: 0.0, rightDelay: 0.0, leftGain: Float(1), rightGain: Float(1))
        var samples = [Float](repeating: 0, count: frame.frameCount * 2)
        var inputPeak: Float = 0, outputPeak: Float = 0
        var ll = Double.zero, rr = Double.zero, lr = Double.zero
        var invalid: UInt64 = 0
        frame.interleaved.withUnsafeBufferPointer { source in
            samples.withUnsafeMutableBufferPointer { destination in
                for i in 0..<frame.frameCount {
                    let offset = i * frame.channelCount
                    for ch in 0..<frame.channelCount {
                        let x = source[offset + ch]
                        if !x.isFinite { invalid &+= 1 }
                        inputPeak = max(inputPeak, abs(SpatialSafety.sample(x)))
                    }
                    let a = amount.next(context.amount)
                    let c = cinema.next(content == .cinema ? 1 : 0)
                    let h = headphoneMix.next(output == .headphones ? 1 : 0)
                    let d = dialogue.next(context.dialogueFocus)
                    let direct = downmixer.process(source: source, offset: offset, map: mapper,
                        surroundAmount: a * c * (1 - h), dialogue: d)
                    // Keep both short stateful branches warm for output crossfades.
                    let sp = speakers.process(left: direct.0, right: direct.1, amount: a, cinema: c)
                    var hp = headphones.process(left: direct.0, right: direct.1, amount: a, cinema: c)
                    let discrete = discreteBlend.next(hasDiscreteContent ? 1 : 0)
                    if let binaural, output == .headphones || h > 0.0001 {
                        if !binauralIsRunning { binaural.reset(); binauralIsRunning = true }
                        let ears = binaural.process(source: source, offset: offset, lfeIndex: mapper.lfe, dialogue: d)
                        let dry = binaural.alignDirect(hp.0, hp.1)
                        // Music remains mostly direct. Real cinema channels can
                        // use the full virtual array; stereo cinema stays blended.
                        let musicWet = 0.12 * a * a
                        let cinemaWet = (1 - discrete) * 0.4 * a + discrete * min(1, a * 2)
                        let wet = musicWet + c * (cinemaWet - musicWet)
                        hp = (dry.0 + wet * (ears.0 - dry.0), dry.1 + wet * (ears.1 - dry.1))
                    } else { binauralIsRunning = false }
                    let aligned = seatAligner.process(sp.0, sp.1, alignment: alignment)
                    let safe = safety.process(aligned.0 + h * (hp.0 - aligned.0), aligned.1 + h * (hp.1 - aligned.1))
                    destination[2 * i] = safe.0; destination[2 * i + 1] = safe.1
                    outputPeak = max(outputPeak, max(abs(safe.0), abs(safe.1)))
                    ll += Double(safe.0) * Double(safe.0)
                    rr += Double(safe.1) * Double(safe.1)
                    lr += Double(safe.0) * Double(safe.1)
                }
            }
        }
        diagnostics = SpatialRenderDiagnostics(renderer: output, content: content,
            inputChannels: frame.channelCount, inputPeak: inputPeak, outputPeak: outputPeak,
            correlation: ll * rr > 1e-20 ? Float(max(-1, min(1, lr / sqrt(ll * rr)))) : 0,
            appliedHeadroomDB: 20 * log10(max(1e-9, safety.gain)),
            expectedGainDB: 20 * log10(max(frame.channelCount > 2 ? Float(12) : Float(2),
                output == .headphones ? (binaural?.expectedPeakGain ?? 1) : 1)),
            processingTimeMicroseconds: (ProcessInfo.processInfo.systemUptime - start) * 1e6,
            invalidSamples: diagnostics.invalidSamples &+ invalid,
            algorithmicLatencyFrames: output == .headphones ? (binaural?.latencyFrames ?? 0) : Int(ceil(max(alignment.leftDelay, alignment.rightDelay) * rate)),
            hrtfProfile: output == .headphones && binaural != nil ? hrtfProfile : nil)
        return PCMFrame(interleaved: samples, channelCount: 2, sampleRate: rate, channelLayout: .stereo,
            sourceBufferedFrames: frame.sourceBufferedFrames, sourceCapacityFrames: frame.sourceCapacityFrames)
    }
}
