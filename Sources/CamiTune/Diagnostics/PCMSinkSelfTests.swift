import CamiTuneAudio
import CamiTuneDomain
import Foundation
import Darwin

extension DeveloperSelfTests {
    static func preparedBufferHandoffCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String,
                   _ body: @escaping @MainActor (DiagnosticSandbox) async throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "Prepared Buffer Handoff", name: name, safety: .simulated) {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                try await body(box); return .init(summary: name)
            }
        }
        return [
            check("AB19", "Prepared sink preserves exact PCM and plug-in state; resumed input wins the race") { box in
                func open(_ name: String) throws -> (URL, FileHandle, CamillaPCMSink) {
                    let url = box.directory.appendingPathComponent(name)
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: url)
                    return (url, handle, try CamillaPCMSink(duplicating: handle.fileDescriptor))
                }
                let (referenceURL, referenceFile, referenceSink) = try open("reference.pcm")
                let (oldURL, oldFile, oldSink) = try open("old.pcm")
                let (newURL, newFile, newSink) = try open("prepared.pcm")
                let referencePlugin = BufferHandoffPlugin(), switchedPlugin = BufferHandoffPlugin()
                func pipeline(_ sink: CamillaPCMSink, _ plugin: BufferHandoffPlugin) -> CamillaDeliveryPipeline {
                    CamillaDeliveryPipeline(sink: sink, hrtfDatabase: nil, performanceSource: .init(), activeRoute: nil,
                        renderConfiguration: .init(), deliveryConfiguration: .legacy(sampleRate: 48000, chunkSize: 128),
                        backendChunkFrames: 128, configurationObserver: nil, systemMaster: .init(),
                        referenceTopology: nil, pluginProcessor: plugin)
                }
                let reference = pipeline(referenceSink, referencePlugin), switched = pipeline(oldSink, switchedPlugin)
                defer {
                    reference.stop(); switched.stop(); newSink.finish()
                    try? referenceFile.close(); try? oldFile.close(); try? newFile.close()
                }
                reference.start(); switched.start()
                func drain(_ pipeline: CamillaDeliveryPipeline, samples: [Float], count: UInt64) async throws {
                    pipeline.enqueue(.init(interleaved: samples, channelCount: 2, sampleRate: 48000))
                    pipeline.enqueueProducerEnd()
                    let until = PerformanceClock.now().advanced(seconds: 2)
                    while pipeline.statisticsSnapshot().delivery.drains.completedDrains < count, PerformanceClock.now() < until {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    try diagnosticRequire(pipeline.statisticsSnapshot().delivery.drains.completedDrains == count, "Fixture did not drain")
                }
                let zero = [Float](repeating: 0, count: 512)
                try await drain(reference, samples: zero, count: 1)
                try await drain(switched, samples: zero, count: 1)
                let quietNow = PerformanceClock.now().advanced(seconds: 4)
                guard let token = switched.bufferHandoffToken(seconds: 3, now: quietNow) else {
                    throw DiagnosticFailure(message: "Silent writer did not issue a handoff token")
                }
                // A ready engine has consumed its priming zeros before the switch.
                let prefix = try Data(contentsOf: referenceURL).count
                let oldCount = try Data(contentsOf: oldURL).count
                guard let retired = switched.replaceBackendIfQuiet(newSink, token: token, chunkFrames: 256,
                    configuration: .legacy(sampleRate: 48000, chunkSize: 256), clocks: [], quietSeconds: 3, now: quietNow) else {
                    throw DiagnosticFailure(message: "Prepared silent handoff failed")
                }
                retired.finish()
                let tone = (0..<1024).map { Float(sin(Double($0) * 0.173) * 0.4) }
                try await drain(reference, samples: tone, count: 2)
                try await drain(switched, samples: tone, count: 2)
                let expected = try Data(contentsOf: referenceURL).dropFirst(prefix)
                let actual = try Data(contentsOf: newURL)
                try diagnosticRequire(actual == Data(expected) && !actual.isEmpty,
                    "Buffer switch changed, duplicated, held back or truncated source PCM")
                let oldAfter = try Data(contentsOf: oldURL).count
                try diagnosticRequire(oldAfter == oldCount,
                    "Audio after commit was sent to the retired sink")
                try diagnosticRequire(referencePlugin.resetCount == 1 && switchedPlugin.resetCount == 1,
                    "Handoff reset the live plug-in or added a transition")
                try diagnosticRequire(!switched.acceptsBufferHandoff(token), "An old token survived new audio")
                // Conversely, input that arrives before the atomic commit must
                // continue on the old path, even after the earlier silence read.
                let later = PerformanceClock.now().advanced(seconds: 4)
                guard let next = switched.bufferHandoffToken(seconds: 3, now: later) else {
                    throw DiagnosticFailure(message: "Second silent interval was unavailable")
                }
                switched.enqueue(.init(interleaved: [Float](repeating: 0.001, count: 512), channelCount: 2, sampleRate: 48000))
                let rejected = switched.replaceBackendIfQuiet(referenceSink, token: next, chunkFrames: 128,
                    configuration: .legacy(sampleRate: 48000, chunkSize: 128), clocks: [], quietSeconds: 3, now: later)
                try diagnosticRequire(rejected == nil && switched.statisticsSnapshot().delivery.droppedFrames == 0,
                    "Resumed input lost the handoff race or was discarded")
            },
            check("AB20", "Stop during standby preparation discards it without reviving playback") { box in
                var profile = DiagnosticSandbox.profile(); profile.audioBufferOverride = .automatic
                box.profiles.profiles = [profile]
                let gate = DiagnosticManualGate()
                let fake = DiagnosticRuntimeFakes(.init(bufferPreparationGate: gate))
                var frames = 1024
                var services = fake.services(); services.automaticBufferSize = { _ in frames }
                services.automaticBufferIsQuiet = { true }
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                defer { gate.release(); state.shutdownSynchronously() }
                await state.activate(profile: profile); frames = 512
                let change = Task { await state.runtimeCoordinator.applyAutomaticBufferIfQuiet() }
                try await gate.waitUntilEntered()
                let generation = state.runtimeCoordinator.desiredRuntime.generation
                let stop = Task { await state.deactivate(manual: true) }
                let deadline = PerformanceClock.now().advanced(seconds: 2)
                while state.runtimeCoordinator.desiredRuntime.generation == generation, PerformanceClock.now() < deadline {
                    await Task.yield()
                }
                try diagnosticRequire(state.runtimeCoordinator.desiredRuntime.generation != generation, "Stop was not submitted")
                gate.release(); await change.value; await stop.value
                try diagnosticRequire(!state.isActive && !fake.events.contains("commit buffer engine")
                    && fake.events.filter { $0 == "start engine" }.count == 1, "Standby superseded Stop")
            },
            check("AB21", "A failed final commit never falls back to a restart") { box in
                var profile = DiagnosticSandbox.profile(); profile.audioBufferOverride = .automatic
                box.profiles.profiles = [profile]
                let fake = DiagnosticRuntimeFakes(.init(bufferCommitSucceeds: false))
                var frames = 1024
                var services = fake.services(); services.automaticBufferSize = { _ in frames }
                services.automaticBufferIsQuiet = { true }
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                defer { state.shutdownSynchronously() }
                await state.activate(profile: profile); frames = 512
                let session = state.activeSession?.id
                await state.runtimeCoordinator.applyAutomaticBufferIfQuiet()
                try diagnosticRequire(state.activeSession?.id == session && state.runtimeCoordinator.appliedProfile?.chunkSize == 1024
                    && !fake.events.contains("stop engine") && !fake.events.contains("stop PCM"),
                    "Rejected atomic handoff used the disruptive restart path")
            },
            check("AB22", "A blocked standby pipe times out and restores normal descriptor flags") { _ in
                let pipe = Pipe(), bytes = Data(count: 2 * 1024 * 1024)
                let sink = try CamillaPCMSink(duplicating: pipe.fileHandleForWriting.fileDescriptor)
                defer { sink.finish(); try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                let flags = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETFL)
                let start = PerformanceClock.now()
                do {
                    try await Task.detached {
                        try sink.writeForPreparation(bytes, deadline: PerformanceClock.now().advanced(seconds: 0.05))
                    }.value
                    throw DiagnosticFailure(message: "A full standby pipe did not time out")
                } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ETIMEDOUT) { }
                let elapsed = PerformanceClock.milliseconds(start, PerformanceClock.now())
                let restoredFlags = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETFL)
                // Darwin also exposes internal flags that can change after a
                // write. Compare the flags governing public I/O semantics.
                let ioFlags = O_ACCMODE | O_NONBLOCK | O_APPEND | O_ASYNC | O_SYNC
                try diagnosticRequire(elapsed < 1000 && restoredFlags & ioFlags == flags & ioFlags,
                    "Preparation took \(elapsed) ms; descriptor flags \(flags) became \(restoredFlags)")
            }
        ]
    }

    static func pcmSinkCases() -> [DiagnosticCase] {
        func check(_ id: String, _ name: String,
                   _ body: @escaping @MainActor () async throws -> Void) -> DiagnosticCase {
            .init(id: id, suite: "PCM Sink Ownership", name: name, safety: .simulated) {
                try await body()
                return .init(summary: name)
            }
        }
        return [
            check("PD38", "Sink preserves exact Float32 bytes") {
                let pipe = Pipe()
                let sink = try CamillaPCMSink(duplicating: pipe.fileHandleForWriting.fileDescriptor)
                defer { sink.finish(); try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                let values: [Float] = [0, -0.0, 0.125, -1, Float.leastNonzeroMagnitude]
                let bytes = values.withUnsafeBytes { Data($0) }
                try sink.write(bytes)
                let read = try pipe.fileHandleForReading.read(upToCount: bytes.count)
                try diagnosticRequire(read == bytes, "Sink changed PCM bytes")
            },
            check("PD39", "Sink survives closing the engine's original handle") {
                let pipe = Pipe()
                let sink = try CamillaPCMSink(duplicating: pipe.fileHandleForWriting.fileDescriptor)
                defer { sink.finish(); try? pipe.fileHandleForReading.close() }
                try pipe.fileHandleForWriting.close()
                let bytes = Data([1, 2, 3, 4])
                try sink.write(bytes)
                sink.finish()
                let read = try pipe.fileHandleForReading.readToEnd()
                try diagnosticRequire(read == bytes, "Engine handle closure invalidated sink ownership")
            },
            check("PD40", "Finishing a sink preserves the original descriptor") {
                let pipe = Pipe()
                defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                let sink = try CamillaPCMSink(duplicating: pipe.fileHandleForWriting.fileDescriptor)
                sink.finish(); sink.finish()
                let bytes = Data([5, 6])
                try pipe.fileHandleForWriting.write(contentsOf: bytes)
                let read = try pipe.fileHandleForReading.read(upToCount: bytes.count)
                try diagnosticRequire(read == bytes, "Sink closed the engine's descriptor")
                do { try sink.write(bytes) }
                catch { return }
                throw DiagnosticFailure(message: "A finished sink accepted another write")
            },
            check("PD41", "Descriptor duplication failure is reported") {
                do { _ = try CamillaPCMSink(duplicating: -1) }
                catch { return }
                throw DiagnosticFailure(message: "Invalid descriptor was accepted")
            },
            check("PD42", "Broken pipe is a Swift error rather than SIGPIPE") {
                let pipe = Pipe()
                let sink = try CamillaPCMSink(duplicating: pipe.fileHandleForWriting.fileDescriptor)
                defer { sink.finish(); try? pipe.fileHandleForWriting.close() }
                try pipe.fileHandleForReading.close()
                do { try sink.write(Data([1])) }
                catch { return }
                throw DiagnosticFailure(message: "Broken pipe did not report a failure")
            },
            check("PD43", "Blocked writer stop is bounded and its sink retires after drain") {
                let pipe = Pipe(), router = PCMRouter()
                defer { router.stop(); try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                let configuration = PCMDeliveryConfiguration(queue: .init(sampleRate: 48_000,
                    operatingTargetFrames: 512, recoveryTargetFrames: 0, hardLimitFrames: 4800,
                    recoveryStrategy: .clearAll, rateTargetMode: .configuredWhenQueued), camillaQueueLimit: 4)
                await router.startFixture(camillaSink: pipe.fileHandleForWriting, deliveryConfiguration: configuration)
                try pipe.fileHandleForWriting.close()
                // Larger than the platform pipe capacity, with no reader yet.
                router.route(.init(interleaved: Array(repeating: 0.125, count: 131_072),
                                   channelCount: 2, sampleRate: 48_000))
                let deadline = PerformanceClock.now().advanced(seconds: 3)
                var ready = false
                while PerformanceClock.now() < deadline {
                    var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    ready = Darwin.poll(&descriptor, 1, 0) > 0 && descriptor.revents & Int16(POLLIN) != 0
                    if ready { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                try diagnosticRequire(ready, "Writer never entered the pipe")
                let before = PerformanceClock.now()
                await router.stopWithoutBlockingUI()
                try diagnosticRequire(PerformanceClock.milliseconds(before, PerformanceClock.now()) < 1_000,
                                      "Blocked sink made shutdown unbounded")
                let reader = pipe.fileHandleForReading
                // Bounded drain: a regression must fail the suite rather than
                // leave readToEnd waiting forever for a leaked duplicate.
                let bytes = try await Task.detached { () throws -> Data in
                    let fd = reader.fileDescriptor
                    var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
                    let until = PerformanceClock.now().advanced(seconds: 3)
                    while PerformanceClock.now() < until {
                        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                        if Darwin.poll(&descriptor, 1, 50) <= 0 { continue }
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        if count == 0 { return result }
                        guard count > 0 else { throw DiagnosticFailure(message: "Pipe drain failed") }
                        result.append(contentsOf: buffer.prefix(count))
                    }
                    throw DiagnosticFailure(message: "Writer did not release its sink after draining")
                }.value
                // Neutral correction retains two cubic look-ahead frames. All
                // other constant samples must survive the blocked Foundation
                // write, byte-for-byte, including its internal partial writes.
                let expected = Array<Float>(repeating: 0.125, count: 131_072 - 4).withUnsafeBytes { Data($0) }
                try diagnosticRequire(bytes == expected, "In-flight stereo write was truncated or reordered")
            },
            check("PD79", "Writer pipe failures publish a session health fault") {
                let pipe = Pipe(), router = PCMRouter()
                defer { router.stop(); try? pipe.fileHandleForWriting.close() }
                try pipe.fileHandleForReading.close()
                await router.startFixture(camillaSink: pipe.fileHandleForWriting)
                router.route(.init(interleaved: Array(repeating: 0.125, count: 1024),
                    channelCount: 2, sampleRate: 48_000))
                let deadline = PerformanceClock.now().advanced(seconds: 2)
                while router.statistics.deliveryError == nil && PerformanceClock.now() < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let statistics = router.statistics
                try diagnosticRequire(statistics.camillaWriteFailures == 1
                    && statistics.deliveryError?.contains("input pipe failed") == true,
                    "The writer stopped without reporting its failure to runtime health")
            },
            check("PD80", "A blocked retired writer cannot fault its replacement") {
                let oldPipe = Pipe(), newPipe = Pipe(), router = PCMRouter()
                defer {
                    router.stop()
                    try? oldPipe.fileHandleForReading.close(); try? oldPipe.fileHandleForWriting.close()
                    try? newPipe.fileHandleForReading.close(); try? newPipe.fileHandleForWriting.close()
                }
                await router.startFixture(camillaSink: oldPipe.fileHandleForWriting)
                router.route(.init(interleaved: Array(repeating: 0.125, count: 131_072),
                    channelCount: 2, sampleRate: 48_000))
                let deadline = PerformanceClock.now().advanced(seconds: 2)
                var readable = false
                while PerformanceClock.now() < deadline {
                    var descriptor = pollfd(fd: oldPipe.fileHandleForReading.fileDescriptor,
                        events: Int16(POLLIN), revents: 0)
                    readable = Darwin.poll(&descriptor, 1, 0) > 0
                    if readable { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                try diagnosticRequire(readable, "Old writer did not enter its blocked write")
                await router.startFixture(camillaSink: newPipe.fileHandleForWriting)
                // The old sink now gets EPIPE after the replacement was published.
                try oldPipe.fileHandleForReading.close()
                let samples = Array<Float>(repeating: 0.25, count: 32)
                router.route(.init(interleaved: samples, channelCount: 2, sampleRate: 48_000))
                router.finishProducerEpoch()
                let until = PerformanceClock.now().advanced(seconds: 2)
                while router.statistics.producerDrains.completedDrains == 0 && PerformanceClock.now() < until {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try await Task.sleep(for: .milliseconds(100))
                let statistics = router.statistics
                try diagnosticRequire(statistics.producerDrains.completedDrains == 1
                    && statistics.camillaWriteFailures == 0 && statistics.deliveryError == nil,
                    "Retired delivery state contaminated the replacement")
                let bytes = try newPipe.fileHandleForReading.read(upToCount: samples.count * 4)
                try diagnosticRequire(bytes == samples.withUnsafeBytes { Data($0) }, "Replacement PCM changed")
            },
            check("PD81", "Producer completion preserves the running renderer's filter history") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let correction = DeviceCorrectionProfile(deviceName: "History fixture", policy: .recommended,
                    measurement: .flat(), target: .flat(), curve: .init(points: []),
                    filters: [.init(kind: .peaking, frequency: 1000, gain: -6, q: 0.707)], preampDB: 0)
                var first = Array<Float>(repeating: 0, count: 32)
                first[0] = 0.25; first[1] = -0.25
                let second = Array<Float>(repeating: 0, count: 128)
                func render(sealBetween: Bool) async throws -> [Float] {
                    let path = box.directory.appendingPathComponent("history-\(sealBetween).pcm")
                    FileManager.default.createFile(atPath: path.path, contents: nil)
                    let file = try FileHandle(forWritingTo: path), router = PCMRouter()
                    defer { router.stop(); try? file.close() }
                    let delivery = PCMDeliveryConfiguration(queue: .init(sampleRate: 48_000,
                        operatingTargetFrames: 512, recoveryTargetFrames: 0, hardLimitFrames: 4800,
                        recoveryStrategy: .clearAll, rateTargetMode: .configuredWhenQueued), camillaQueueLimit: 4)
                    await router.startFixture(camillaSink: file, deliveryConfiguration: delivery,
                        playbackMode: .referencePlayback, referenceCorrection: correction)
                    func deliver(_ samples: [Float], drain: UInt64) async throws {
                        router.route(.init(interleaved: samples, channelCount: 2, sampleRate: 48_000))
                        router.finishProducerEpoch()
                        let until = PerformanceClock.now().advanced(seconds: 2)
                        while router.statistics.producerDrains.completedDrains < drain && PerformanceClock.now() < until {
                            try await Task.sleep(for: .milliseconds(5))
                        }
                        try diagnosticRequire(router.statistics.producerDrains.completedDrains == drain,
                            "Renderer history fixture did not drain")
                    }
                    if sealBetween {
                        try await deliver(first, drain: 1)
                        try await deliver(second, drain: 2)
                    } else { try await deliver(first + second, drain: 1) }
                    let bytes = try Data(contentsOf: path)
                    return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                }
                let continuous = try await render(sealBetween: false)
                let segmented = try await render(sealBetween: true)
                try diagnosticRequire(continuous.suffix(second.count).contains { abs($0) > 0.00001 },
                    "Fixture did not exercise retained filter state")
                try diagnosticRequire(segmented == continuous,
                    "A normal producer end discarded renderer history or changed accepted samples")
            },
            check("PD74", "Producer seal drains cubic lookahead without borrowing the next sound") {
                for count in [1, 2, 3, 16, 512] {
                    var resampler = AdaptivePCMResampler()
                    let samples = (0..<(count * 2)).map { Float($0 + 1) / 2048 }
                    let frame = PCMFrame(interleaved: samples, channelCount: 2, sampleRate: 48_000)
                    let first = resampler.process(frame, adjustmentPPM: 0)
                    let tail = resampler.finish(adjustmentPPM: 0)
                    try diagnosticRequire(first.interleaved + (tail?.interleaved ?? []) == samples,
                        "Seal lost, duplicated or changed a \(count)-frame sound")
                    try diagnosticRequire(resampler.finish(adjustmentPPM: 0) == nil && resampler.retainedSampleCount == 0,
                        "Repeated seal emitted PCM or retained history")
                }
            },
            check("PD75", "Producer seals share bounded FIFO ordering with PCM") {
                var queue = LowLatencyPCMQueue()
                queue.configure(.init(sampleRate: 48_000, operatingTargetFrames: 2, recoveryTargetFrames: 0,
                    hardLimitFrames: 8, recoveryStrategy: .clearAll, rateTargetMode: .configuredWhenQueued))
                let first = PCMFrame(interleaved: [0.25, 0.25], channelCount: 2, sampleRate: 48_000)
                _ = queue.enqueue(first)
                for _ in 0..<10_000 { try diagnosticRequire(queue.enqueueProducerEnd(), "Consecutive seals did not coalesce") }
                _ = queue.enqueue(first)
                try diagnosticRequire(queue.bufferCount == 3 && queue.queuedFrames == 2 && queue.allocatedSlotCount == 16,
                    "Empty epochs created unbounded queue storage")
                guard case .audio? = queue.removeNext(), case .producerEnd? = queue.removeNext(),
                      case .audio? = queue.removeNext() else { throw DiagnosticFailure(message: "Seal crossed PCM") }
                _ = queue.enqueue(first); _ = queue.enqueueProducerEnd(); _ = queue.reset(reason: .runtimeReset)
                try diagnosticRequire(queue.isEmpty, "Discontinuity retained a stale seal")
            },
            check("PD76", "Writer delivers exact short sounds across producer epochs") {
                let pipe = Pipe(), router = PCMRouter()
                defer { router.stop(); try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                let configuration = PCMDeliveryConfiguration(queue: .init(sampleRate: 48_000,
                    operatingTargetFrames: 512, recoveryTargetFrames: 0, hardLimitFrames: 4800,
                    recoveryStrategy: .clearAll, rateTargetMode: .configuredWhenQueued), camillaQueueLimit: 4)
                await router.startFixture(camillaSink: pipe.fileHandleForWriting, deliveryConfiguration: configuration,
                    backendChunkFrames: 512)
                let first: [Float] = [0.125, -0.125]
                router.route(.init(interleaved: first, channelCount: 2, sampleRate: 48_000))
                router.finishProducerEpoch()
                let second = Array<Float>(repeating: 0.25, count: 32)
                router.route(.init(interleaved: second, channelCount: 2, sampleRate: 48_000))
                router.finishProducerEpoch()
                let expectedSamples = first + Array<Float>(repeating: 0, count: 1022)
                    + second + Array<Float>(repeating: 0, count: 992)
                let expected = expectedSamples.withUnsafeBytes { Data($0) }
                let actual = try await Task.detached { () throws -> Data in
                    let fd = pipe.fileHandleForReading.fileDescriptor
                    var result = Data(), buffer = [UInt8](repeating: 0, count: expected.count)
                    let until = PerformanceClock.now().advanced(seconds: 3)
                    while result.count < expected.count && PerformanceClock.now() < until {
                        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        if Darwin.poll(&descriptor, 1, 50) <= 0 { continue }
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        guard count > 0 else { throw DiagnosticFailure(message: "Short-sound pipe failed") }
                        result.append(contentsOf: buffer.prefix(count))
                    }
                    return result
                }.value
                try diagnosticRequire(actual == expected && router.statistics.camillaWriteFailures == 0,
                    "Writer lost the tail or mixed resampler history between sounds")
                let until = PerformanceClock.now().advanced(seconds: 2)
                while router.statistics.producerDrains.completedDrains < 2 && PerformanceClock.now() < until {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try diagnosticRequire(router.statistics.producerDrains == .init(completedDrains: 2,
                    resamplerTailFrames: 3, backendPaddingFrames: 1007),
                    "Backend alignment silence was not accounted separately from accepted PCM")
            },
            check("PD78", "An aligned producer tail does not append another backend chunk") {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let path = box.directory.appendingPathComponent("aligned-tail.pcm")
                FileManager.default.createFile(atPath: path.path, contents: nil)
                let file = try FileHandle(forWritingTo: path), router = PCMRouter()
                defer { router.stop(); try? file.close() }
                let configuration = PCMDeliveryConfiguration(queue: .init(sampleRate: 48_000,
                    operatingTargetFrames: 512, recoveryTargetFrames: 0, hardLimitFrames: 4800,
                    recoveryStrategy: .clearAll, rateTargetMode: .configuredWhenQueued), camillaQueueLimit: 4)
                await router.startFixture(camillaSink: file, deliveryConfiguration: configuration, backendChunkFrames: 512)
                let samples = Array<Float>(repeating: 0.125, count: 1024)
                router.route(.init(interleaved: samples, channelCount: 2, sampleRate: 48_000))
                router.finishProducerEpoch()
                let until = PerformanceClock.now().advanced(seconds: 2)
                while router.statistics.producerDrains.completedDrains == 0 && PerformanceClock.now() < until {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try diagnosticRequire(router.statistics.producerDrains == .init(completedDrains: 1,
                    resamplerTailFrames: 2, backendPaddingFrames: 0), "An aligned stream gained an extra chunk")
                let actual = try Data(contentsOf: path)
                try diagnosticRequire(actual == samples.withUnsafeBytes { Data($0) }, "Aligned input bytes changed")
            },
            check("PD77", "Writer cannot invent a delivery policy for an unplanned format") {
                let pipe = Pipe(), router = PCMRouter()
                defer { router.stop(); try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                await router.startFixture(camillaSink: pipe.fileHandleForWriting)
                router.route(.init(interleaved: Array(repeating: 0.125, count: 1024),
                    channelCount: 2, sampleRate: 44_100))
                let until = PerformanceClock.now().advanced(seconds: 2)
                while router.statistics.deliveryError == nil && PerformanceClock.now() < until {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try diagnosticRequire(router.statistics.deliveryError?.contains("prepared delivery policy") == true
                    && router.statistics.camillaWriteFailures == 0,
                    "Unplanned rate silently switched policy or became a pipe failure")
                var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                try diagnosticRequire(Darwin.poll(&descriptor, 1, 0) == 0, "Unplanned PCM reached the engine")
            },
            check("PD44", "Independent sinks retire without closing one another") {
                let pipe = Pipe()
                let first = try CamillaPCMSink(duplicating: pipe.fileHandleForWriting.fileDescriptor)
                let second = try CamillaPCMSink(duplicating: pipe.fileHandleForWriting.fileDescriptor)
                defer { first.finish(); second.finish(); try? pipe.fileHandleForReading.close() }
                try pipe.fileHandleForWriting.close()
                first.finish()
                let bytes = Data([9, 8, 7])
                try second.write(bytes)
                second.finish()
                let read = try pipe.fileHandleForReading.readToEnd()
                try diagnosticRequire(read == bytes, "Retiring one sink invalidated another")
            }
        ]
    }
}

private final class BufferHandoffPlugin: PluginAudioProcessor, @unchecked Sendable {
    let tailFrames = 0
    private let lock = NSLock()
    private var resets = 0
    var resetCount: Int { lock.lock(); defer { lock.unlock() }; return resets }
    func process(_ samples: inout [Float], sampleRate: Double, reset: Bool) -> Bool {
        if reset { lock.lock(); resets += 1; lock.unlock() }
        for index in samples.indices { samples[index] *= 0.5 }
        return true
    }
}
