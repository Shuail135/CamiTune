import Foundation
import Accelerate

final class SpectrumAnalyzer: ObservableObject, @unchecked Sendable {
    @Published private(set) var points: [SpectrumPoint] = []
    @Published private(set) var status: String = "Analyzer idle"
    @Published private(set) var activeSession: AudioRuntimeSession?

    var activeProfileID: UUID? { activeSession?.profileID }

    private var fftSetup: FFTSetup?
    private let fftSize = 4096
    private let fftHopSize = 2048
    private let log2n: vDSP_Length = 12
    private var lastPublish = Date.distantPast
    private var lastPointsPublication = Date.distantPast
    private var smoothedDB: [Double] = []
    private let displayBinCount = 180
    private let stateLock = NSLock()
    private let processingLock = NSLock()
    private var pendingSamples: [Float] = []
    private var receivedBuffer = false
    private var analysisSessionID: UUID?
    private var presentedProfileID: UUID?
    private var pendingPointsPublication: ([SpectrumPoint], AudioRuntimeSession)?
    private var pointsPublicationScheduled = false
    private var pointsPublicationGeneration: UInt64 = 0
    private var sourceName = "System Audio Bridge"

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    @MainActor
    func start(session: AudioRuntimeSession, sourceName: String) async {
        await stopWithoutBlockingUI()
        stateLock.withLock {
            analysisSessionID = session.id
            pendingPointsPublication = nil
            pointsPublicationScheduled = false
            pointsPublicationGeneration &+= 1
        }
        activeSession = session
        lastPointsPublication = .distantPast
        self.sourceName = sourceName
        if fftSetup == nil { fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) }
        resetReceivedBuffer()
        status = "Waiting for audio from \(sourceName)…"
    }

    /// FFT work exists only to drive profile-editor visuals. Keep the audio
    /// route independent and discard observation frames while that profile is
    /// not being presented.
    @MainActor
    func setPresentationActive(_ active: Bool, profileID: UUID) {
        stateLock.lock()
        let previous = presentedProfileID
        if active {
            presentedProfileID = profileID
        } else if presentedProfileID == profileID {
            presentedProfileID = nil
        }
        let shouldReset = previous != presentedProfileID
        if shouldReset {
            pendingPointsPublication = nil
            pointsPublicationScheduled = false
            pointsPublicationGeneration &+= 1
        }
        stateLock.unlock()
        guard shouldReset else { return }
        points = []
        lastPointsPublication = .distantPast
        Task.detached(priority: .utility) { [weak self] in
            self?.resetProcessingState()
        }
    }

    func ingest(
        interleaved: [Float],
        channelCount: Int,
        sampleRate: Double,
        session: AudioRuntimeSession
    ) {
        guard channelCount > 0,
              sampleRate > 0,
              interleaved.count >= channelCount else { return }
        guard accepts(session: session) else { return }
        processingLock.lock()
        defer { processingLock.unlock() }
        guard accepts(session: session) else { return }
        analyze(
            interleaved: interleaved,
            channelCount: channelCount,
            sampleRate: sampleRate,
            session: session
        )
    }

    private func analyze(
        interleaved: [Float],
        channelCount: Int,
        sampleRate: Double,
        session: AudioRuntimeSession
    ) {
        let frameCount = interleaved.count / channelCount
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += interleaved[frame * channelCount + channel]
            }
            mono[frame] = sum / Float(channelCount)
        }
        accept(
            mono: mono,
            sampleRate: sampleRate,
            session: session
        )
    }

    @MainActor
    func stopWithoutBlockingUI() async {
        invalidateSessionAndPresentation()
        activeSession = nil
        lastPointsPublication = .distantPast
        points = []
        status = "Analyzer idle"
        await Task.detached(priority: .utility) { [self] in
            resetProcessingState()
        }.value
    }

    /// Synchronous teardown is retained for process termination and targeted
    /// tests. Normal runtime transitions should await stopWithoutBlockingUI().
    @MainActor
    func stop() {
        invalidateSessionAndPresentation()
        activeSession = nil
        lastPointsPublication = .distantPast
        points = []
        resetProcessingState()
        status = "Analyzer idle"
    }

    private func invalidateSessionAndPresentation() {
        stateLock.lock()
        analysisSessionID = nil
        pendingPointsPublication = nil
        pointsPublicationScheduled = false
        pointsPublicationGeneration &+= 1
        stateLock.unlock()
    }

    private func resetProcessingState() {
        processingLock.lock()
        pendingSamples.removeAll(keepingCapacity: true)
        smoothedDB.removeAll(keepingCapacity: true)
        processingLock.unlock()
        resetReceivedBuffer()
    }

    private func accept(
        mono: [Float],
        sampleRate: Double,
        session: AudioRuntimeSession
    ) {
        if markFirstBufferReceived() {
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeSession == session,
                      self.accepts(session: session) else { return }
                self.status = "Live FFT from \(self.sourceName)"
            }
        }
        pendingSamples.append(contentsOf: mono)
        guard pendingSamples.count >= fftSize else {
            return
        }
        let samples = Array(pendingSamples.prefix(fftSize))
        // Keep half the window for the next analysis frame. The 50% overlap
        // provides about 23 spectrum frames per second at 48 kHz, making
        // musical changes visible without sacrificing frequency resolution.
        pendingSamples.removeFirst(fftHopSize)
        process(
            samples: samples,
            sampleRate: sampleRate,
            session: session
        )
    }

    private func process(
        samples input: [Float],
        sampleRate: Double,
        session: AudioRuntimeSession
    ) {
        // Update often enough for continuous motion, while using a slower
        // envelope below so the graph remains useful as an EQ tuning guide.
        // Audio continues to CamillaDSP at full rate.
        let now = Date()
        guard now.timeIntervalSince(lastPublish) >= 0.05 else { return }
        lastPublish = now

        var samples = input
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        guard let setup = fftSetup else { return }
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress,
                      let imaginaryBase = imagPtr.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                var convertedSamples = false
                samples.withUnsafeBytes { raw in
                    guard let baseAddress = raw.baseAddress else { return }
                    let complex = baseAddress.assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    convertedSamples = true
                }
                guard convertedSamples else { return }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                var mags = [Float](repeating: 0, count: half)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                let scale = 1.0 / Float(fftSize * fftSize)
                let minimumFrequency = 20.0
                let maximumFrequency = min(20_000.0, sampleRate / 2)
                let frequencyPerBin = sampleRate / Double(fftSize)
                var current = [Double](repeating: -120, count: displayBinCount)

                // Collapse the linear FFT into evenly spaced logarithmic bins.
                // Taking the strongest component in each band keeps musical
                // fundamentals visible without drawing thousands of flickering
                // one-pixel spikes.
                for displayIndex in 0..<displayBinCount {
                    let lowerT = Double(displayIndex) / Double(displayBinCount)
                    let upperT = Double(displayIndex + 1) / Double(displayBinCount)
                    let lowerFrequency = minimumFrequency * pow(maximumFrequency / minimumFrequency, lowerT)
                    let upperFrequency = minimumFrequency * pow(maximumFrequency / minimumFrequency, upperT)
                    let lowerBin = max(1, Int(floor(lowerFrequency / frequencyPerBin)))
                    let upperBin = min(half - 1, max(lowerBin, Int(ceil(upperFrequency / frequencyPerBin))))
                    guard lowerBin <= upperBin else { continue }
                    var strongest: Float = 0
                    for fftIndex in lowerBin...upperBin { strongest = max(strongest, mags[fftIndex]) }
                    current[displayIndex] = max(-120, 10 * log10(Double(max(strongest * scale, 1e-12))))
                }

                // Five-point frequency-domain averaging removes narrow-bin
                // sparkle while preserving broad tonal shapes used for EQ.
                if current.count > 4 {
                    var spatial = current
                    for index in 2..<(current.count - 2) {
                        spatial[index] = current[index - 2] * 0.08
                            + current[index - 1] * 0.22
                            + current[index] * 0.40
                            + current[index + 1] * 0.22
                            + current[index + 2] * 0.08
                    }
                    current = spatial
                }

                if smoothedDB.count != current.count {
                    smoothedDB = current
                } else {
                    for index in current.indices {
                        let rising = current[index] > smoothedDB[index]
                        let difference = abs(current[index] - smoothedDB[index])
                        // React strongly to meaningful musical changes while
                        // retaining gentler motion for tiny bin fluctuations.
                        let amount: Double
                        if rising {
                            amount = difference > 8 ? 0.42 : (difference > 3 ? 0.30 : 0.18)
                        } else {
                            amount = difference > 8 ? 0.18 : (difference > 3 ? 0.12 : 0.07)
                        }
                        smoothedDB[index] += (current[index] - smoothedDB[index]) * amount
                    }
                }

                let mapped = smoothedDB.enumerated().map { index, db in
                    let t = (Double(index) + 0.5) / Double(displayBinCount)
                    let frequency = minimumFrequency * pow(maximumFrequency / minimumFrequency, t)
                    return SpectrumPoint(frequency: frequency, db: db)
                }
                schedulePointsPublication(mapped, session: session)
            }
        }
    }

    /// Keep only the newest FFT result while MainActor is occupied. Without
    /// this gate, scrolling can leave a tail of obsolete graph updates that
    /// continues invalidating the view after the interaction has finished.
    private func schedulePointsPublication(
        _ points: [SpectrumPoint],
        session: AudioRuntimeSession
    ) {
        stateLock.lock()
        guard analysisSessionID == session.id,
              presentedProfileID == session.profileID else {
            stateLock.unlock()
            return
        }
        pendingPointsPublication = (points, session)
        guard !pointsPublicationScheduled else {
            stateLock.unlock()
            return
        }
        pointsPublicationScheduled = true
        let generation = pointsPublicationGeneration
        stateLock.unlock()

        Task { @MainActor [weak self] in
            self?.publishPendingPoints(generation: generation)
        }
    }

    @MainActor
    private func publishPendingPoints(generation: UInt64) {
        stateLock.lock()
        guard pointsPublicationGeneration == generation else {
            stateLock.unlock()
            return
        }
        let publication = pendingPointsPublication
        pendingPointsPublication = nil
        pointsPublicationScheduled = false
        stateLock.unlock()

        guard let (mapped, session) = publication,
              activeSession == session,
              accepts(session: session) else { return }
        let now = Date()
        guard UIRenderPerformance.allowsSpectrumPublication(
            since: lastPointsPublication,
            now: now
        ) else { return }
        lastPointsPublication = now
        points = mapped
    }

    private func markFirstBufferReceived() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !receivedBuffer else { return false }
        receivedBuffer = true
        return true
    }

    private func resetReceivedBuffer() {
        stateLock.lock()
        receivedBuffer = false
        stateLock.unlock()
    }

    private func accepts(session: AudioRuntimeSession) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return analysisSessionID == session.id
            && presentedProfileID == session.profileID
    }

}
