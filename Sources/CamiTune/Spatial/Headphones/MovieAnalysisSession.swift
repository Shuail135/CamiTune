import AVFoundation
import CamiTuneAudio
import CamiTuneDomain
import Combine
import Foundation
import SoundAnalysis

/// One serialized worker for this router, including retired model calls. A slow
/// platform call cannot create another worker when the audio route is replaced.
final class MovieAnalysisSession: @unchecked Sendable {
    let changes = PassthroughSubject<MovieAnalysisStatus, Never>()
    private let control = NSLock()
    private enum Selection {
        case off, analysis(MovieAnalysisExchange), unavailable
        var exchange: MovieAnalysisExchange? { if case .analysis(let exchange) = self { return exchange }; return nil }
        var status: MovieAnalysisStatus {
            switch self {
            case .off: return .off
            case .analysis(let exchange): return exchange.presentationStatus()
            case .unavailable: return .unavailable("Analysis cannot use this input format. Playback and manual enhancement continue.")
            }
        }
    }
    private var current = Selection.off
    private var presentationEnabled = false
    private var mainPublicationPending = false
    private let queue = DispatchQueue(label: "CamiTune.MovieAnalysis", qos: .utility)
    private let wake: DispatchSourceUserDataAdd
    private let presentationDeadline: DispatchSourceTimer
    // Worker-owned model, buffers and presentation deadline.
    private var context: MovieAnalysisContext?
    private var lastPublication: UInt64 = 0
    private var lastStatus: MovieAnalysisStatus?

    init() {
        wake = DispatchSource.makeUserDataAddSource(queue: queue)
        presentationDeadline = DispatchSource.makeTimerSource(queue: queue)
        wake.setEventHandler { [weak self] in self?.drain() }
        presentationDeadline.setEventHandler { [weak self] in self?.publishStatus() }
        wake.resume(); presentationDeadline.resume()
    }
    deinit { wake.cancel(); presentationDeadline.cancel() }

    func makeExchange(rate: Double, layout: LPCMChannelLayout) -> MovieAnalysisExchange? {
        let source = wake
        do {
            let next = try MovieAnalysisExchange(rate: rate, layout: layout, wake: { source.add(data: 1) })
            replace(with: .analysis(next))
            return next
        } catch { replace(with: .unavailable); return nil }
    }
    func stop() { replace(with: .off) }
    private func replace(with next: Selection) {
        control.lock()
        let previous = current
        current = next
        control.unlock()
        previous.exchange?.retire()
        wake.add(data: 1)
    }
    func setPresentationEnabled(_ enabled: Bool) {
        control.lock()
        let changed = presentationEnabled != enabled
        presentationEnabled = enabled
        control.unlock()
        if changed { wake.add(data: 1) }
    }
    var status: MovieAnalysisStatus {
        control.lock(); let exchange = current; control.unlock()
        return exchange.status
    }

    private func drain() {
        control.lock(); let exchange = current.exchange; control.unlock()
        guard let exchange else { context = nil; publishStatus(); return }
        var request = exchange.request()
        if context?.exchange !== exchange || context?.generation != request.generation || request.phase != .running {
            context = nil
            publishStatus()
            if request.phase == .preparing, let intent = request.intent {
                do {
                    let prepared = try MovieAnalysisContext(exchange: exchange, generation: request.generation, detector: intent.detector)
                    if exchange.begin(generation: request.generation) { context = prepared }
                } catch { exchange.fail(.modelFailure, generation: request.generation) }
            }
        }
        while let context, context.exchange === exchange {
            request = exchange.request()
            guard request.phase == .running, request.generation == context.generation else { self.context = nil; break }
            guard context.consume() else { break }
        }
        publishStatus()
    }

    /// At most two visible updates per second. The one-shot deadline preserves
    /// the final stopped/failure status without a polling timer or hidden work.
    private func publishStatus() {
        presentationDeadline.schedule(deadline: .distantFuture)
        control.lock()
        let visible = presentationEnabled, exchange = current
        control.unlock()
        guard visible else { lastStatus = nil; return }
        let value = exchange.status
        guard value != lastStatus else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let earliest = lastPublication + 500_000_000
        guard now >= earliest else {
            presentationDeadline.schedule(deadline: .init(uptimeNanoseconds: earliest), leeway: .milliseconds(50))
            return
        }
        lastStatus = value; lastPublication = now
        control.lock()
        guard !mainPublicationPending else { control.unlock(); return }
        mainPublicationPending = true
        control.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.control.lock()
            self.mainPublicationPending = false
            let visible = self.presentationEnabled, current = self.current
            self.control.unlock()
            if visible { self.changes.send(current.status) }
        }
    }
}

/// Platform work and at most 100 ms of conversion scratch. SoundAnalysis owns
/// its supported one-second context and performs its native-rate conversion;
/// no decimation, skipped frames or playback resampling is involved here.
private final class MovieAnalysisContext {
    let exchange: MovieAnalysisExchange
    let generation: UInt64
    private var input: [Float]
    private var basic = SpatialContentAnalyzer()
    private let mixer: SpatialAnalysisMixer
    private let analyzer: SNAudioStreamAnalyzer?
    private let observer: MovieSoundObserver?
    private let mono: AVAudioPCMBuffer?
    private var silentFrames = 0

    init(exchange: MovieAnalysisExchange, generation: UInt64, detector: MovieDetector) throws {
        self.exchange = exchange; self.generation = generation
        input = .init(repeating: 0, count: exchange.batchFrames * exchange.layout.channelCount)
        mixer = .init(layout: exchange.layout, rate: exchange.rate)
        if detector == .localAI {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 1, preferredTimescale: CMTimeScale(exchange.rate))
            request.overlapFactor = 0
            guard (0.5...1.1).contains(request.windowDuration.seconds),
                  Set(["speech", "music", "singing"]).isSubset(of: Set(request.knownClassifications)),
                  let format = AVAudioFormat(standardFormatWithSampleRate: exchange.rate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(exchange.batchFrames)),
                  buffer.floatChannelData != nil else {
                throw CocoaError(.featureUnsupported)
            }
            let stream = SNAudioStreamAnalyzer(format: format)
            let receiver = MovieSoundObserver(exchange: exchange, generation: generation)
            try stream.add(request, withObserver: receiver)
            analyzer = stream; observer = receiver; mono = buffer
        } else { analyzer = nil; observer = nil; mono = nil }
    }
    deinit { analyzer?.removeAllRequests() }

    func consume() -> Bool {
        guard let batch = input.withUnsafeMutableBufferPointer({ exchange.readBatch(into: $0, generation: generation) }) else { return false }
        var energy: Double = 0
        if let analyzer, let observer, let mono {
            mono.frameLength = AVAudioFrameCount(batch.count)
            energy = input.withUnsafeBufferPointer {
                mixer.process($0, frameCount: batch.count, output: .init(start: mono.floatChannelData![0], count: batch.count))
            }
            observer.observeEnergy(start: batch.start, count: batch.count, mean: energy / Double(batch.count))
            analyzer.analyze(mono, atAudioFramePosition: AVAudioFramePosition(batch.start))
        } else {
            input.withUnsafeBufferPointer { storage in
                let samples = UnsafeBufferPointer(start: storage.baseAddress, count: batch.count * exchange.layout.channelCount)
                basic.ingest(samples, channelCount: exchange.layout.channelCount,
                    sampleRate: exchange.rate, layout: exchange.layout)
            }
            let estimate = basic.estimate
            let scores = MovieContentScores(speech: estimate.speech, music: estimate.music,
                events: max(estimate.ambience, estimate.impact), impact: estimate.impact, active: estimate.active)
            exchange.publish(.init(generation: generation, startFrame: batch.start,
                endFrame: batch.start + UInt64(batch.count), scores: scores))
            energy = estimate.active ? 1 : 0
        }
        silentFrames = energy > Double(batch.count) * 1e-8 ? 0 : silentFrames + batch.count
        if silentFrames >= Int(exchange.rate * 1.5) { exchange.markQuiet(generation: generation) }
        return true
    }
}

/// Callbacks can outlive a retired route. They retain only their own exchange,
/// and publish through its generation check, never through the router pointer.
private final class MovieSoundObserver: NSObject, SNResultsObserving {
    private struct EnergyWindow { let start: UInt64, end: UInt64; let mean: Double }
    private let exchange: MovieAnalysisExchange
    private let generation: UInt64
    private let lock = NSLock()
    private var energy: [EnergyWindow] = []
    init(exchange: MovieAnalysisExchange, generation: UInt64) {
        self.exchange = exchange; self.generation = generation
        energy.reserveCapacity(21)
    }
    func observeEnergy(start: UInt64, count: Int, mean: Double) {
        lock.lock(); defer { lock.unlock() }
        energy.append(.init(start: start, end: start + UInt64(count), mean: mean))
        let end = start + UInt64(count)
        energy.removeAll { end > $0.end && end - $0.end >= UInt64(exchange.rate * 2) }
    }
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let startSeconds = result.timeRange.start.seconds, endSeconds = CMTimeRangeGetEnd(result.timeRange).seconds
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0, endSeconds > startSeconds else { return }
        let start = UInt64((startSeconds * exchange.rate).rounded()), end = UInt64((endSeconds * exchange.rate).rounded())
        lock.lock()
        let windows = energy.filter { $0.end > start && $0.start < end }
        let active = windows.contains { $0.mean > 1e-8 }
        lock.unlock()
        let scores = MovieSoundLabels.scores(result.classifications.map { ($0.identifier, Float($0.confidence)) }, active: active)
        exchange.publish(.init(generation: generation, startFrame: start, endFrame: end, scores: scores))
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {
        exchange.fail(.modelFailure, generation: generation)
    }
}

/// Independent classifier families. Maxima avoid double-counting correlated
/// labels; events are explicit labels, never the complement of speech/music.
enum MovieSoundLabels {
    static let speech: Set<String> = ["speech", "whispering", "shout", "yell"]
    static let singing: Set<String> = ["singing", "choir_singing", "yodeling", "rapping", "humming"]
    static let impact: Set<String> = ["gunshot_gunfire", "artillery_fire", "fireworks", "firecracker", "eruption", "boom", "glass_breaking", "thump_thud"]
    static let events = impact.union(Set("""
        person_running person_shuffling person_walking finger_snapping clapping applause
        dog dog_bark dog_howl dog_bow_wow dog_growl dog_whimper cat cat_purr cat_meow
        horse_clip_clop horse_neigh cow_moo pig_oink sheep_bleat fowl chicken chicken_cluck
        rooster_crow turkey_gobble duck_quack goose_honk lion_roar bird bird_vocalization
        bird_chirp_tweet bird_squawk pigeon_dove_coo crow_caw owl_hoot bird_flapping insect
        cricket_chirp mosquito_buzz fly_buzz bee_buzz frog frog_croak snake_hiss snake_rattle
        whale_vocalization coyote_howl elk_bugle bell church_bell bicycle_bell wind_chime
        wind wind_rustling_leaves wind_noise_microphone thunderstorm thunder water rain
        raindrop stream_burbling waterfall ocean sea_waves gurgling fire fire_crackle
        boat_water_vehicle sailing rowboat_canoe_kayak motorboat_speedboat car_horn power_windows
        vehicle_skidding car_passing_by race_car truck air_horn reverse_beeps bus emergency_vehicle
        police_siren ambulance_siren fire_engine_siren motorcycle traffic_noise rail_transport
        train train_whistle train_horn railroad_car train_wheels_squealing subway_metro aircraft
        helicopter airplane bicycle skateboard engine lawn_mower chainsaw engine_knocking
        engine_starting engine_idling engine_accelerating_revving door door_bell door_sliding
        door_slam knock tap squeak drawer_open_close dishes_pots_pans cutlery_silverware
        chopping_food frying_food microwave_oven blender water_tap_faucet sink_filling_washing
        bathtub_filling_washing hair_dryer toilet_flush toothbrush vacuum_cleaner zipper
        keys_jangling coin_dropping scissors electric_shaver typing typewriter typing_computer_keyboard
        writing telephone telephone_bell_ringing ringtone alarm_clock siren civil_defense_siren
        smoke_detector foghorn ratchet_and_pawl clock tick tick_tock sewing_machine mechanical_fan
        air_conditioner printer camera hammer saw power_tool drill hedge_trimmer chopping_wood
        wood_cracking glass_clink liquid_splashing liquid_sloshing liquid_squishing liquid_dripping
        liquid_pouring liquid_trickle_dribble liquid_filling_container liquid_spraying water_pump
        boiling underwater_bubbling whoosh_swoosh_swish basketball_bounce slap_smack crushing
        crumpling_crinkling tearing beep click bowling_impact playing_badminton playing_hockey
        playing_squash playing_table_tennis playing_tennis playing_volleyball rope_skipping scuba_diving skiing
        """.split(whereSeparator: \.isWhitespace).map(String.init)))
    static func scores(_ labels: [(String, Float)], active: Bool) -> MovieContentScores {
        guard active else { return .init() }
        func maximum(_ family: Set<String>) -> Float { labels.reduce(0) { family.contains($1.0) ? max($0, $1.1) : $0 } }
        return .init(speech: maximum(speech), music: maximum(["music"]), singing: maximum(singing),
            events: maximum(events), impact: maximum(impact), active: true)
    }
}
