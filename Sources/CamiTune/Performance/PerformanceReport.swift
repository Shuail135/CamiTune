import Foundation

enum PerformanceAggregator {
    static func build(capture: AudioLatencyCapture, startedAt: Date, end: PerformanceTick,
                      options: PerformanceCaptureOptions, environment: PerformanceEnvironment,
                      observations: [PerformanceEnvironmentObservation], operations: [PerformanceOperationMeasurement],
                      drops: UInt64, stopReason: String) -> PerformanceBaseline {
        var packets: [PacketLatencySample] = []; var samples: [AudioLatencySample] = []; var recoveries: [PCMQueueRecoverySample] = []
        var queueEvents: [QueueTimingSample] = []
        var presentationSamples: [PresentationPerformanceSample] = []
        for event in capture.events() where event.timestamp <= end {
            switch event {
            case .packet(let packet): if packet.processed <= end { packets.append(packet) }
            case .audio(let sample): if sample.pipeWriteCompleted <= end { samples.append(sample) }
            case .recovery(let recovery): recoveries.append(recovery)
            case .queue(let timing): queueEvents.append(timing)
            case .presentation(let sample): if sample.ended <= end { presentationSamples.append(sample) }
            }
        }
        var values: [String: [Double]] = [:]
        func add(_ name: String, _ start: PerformanceTick?, _ end: PerformanceTick?) {
            guard let start, let end, end >= start else { return }
            values[name, default: []].append(PerformanceClock.milliseconds(start, end))
        }
        var packetSizes: [Int: Int] = [:]; var emittedSizes: [Int: Int] = [:]
        for packet in packets {
            add("Per-client processing", packet.received, packet.processed)
            packetSizes[packet.identity.frameCount, default: 0] += 1
        }
        var priorEntry: [String: PerformanceTick] = [:]; var priorDequeue: [String: PerformanceTick] = [:]
        for sample in samples.sorted(by: { $0.queueEntered < $1.queueEntered }) {
            add("Mixer policy wait", sample.packetProcessed, sample.mixEligible)
            add("Mixer emission work", sample.mixEligible, sample.mixEmitted)
            add("Idle flush wake lateness", sample.idleDeadline, sample.idleFlushStarted)
            add("Idle flush emission work", sample.idleFlushStarted, sample.mixEmitted)
            add("Route/enqueue overhead", sample.mixEmitted, sample.queueEntered)
            add("PCM queue residence", sample.queueEntered, sample.queueLeft)
            add("Rendering (including analysis/reset)", sample.queueLeft, sample.renderCompleted)
            add("Resampling/rate-match", sample.renderCompleted, sample.resampleCompleted)
            add("System master", sample.resampleCompleted, sample.masterCompleted)
            add("Payload preparation", sample.masterCompleted, sample.pipeWriteStarted)
            add("Pipe write", sample.pipeWriteStarted, sample.pipeWriteCompleted)
            add("Receipt → Camilla input", sample.packetReceived, sample.pipeWriteCompleted)
            add("Last processing → Camilla input", sample.packetProcessed, sample.pipeWriteCompleted)
            add("Writer execution", sample.queueLeft, sample.pipeWriteCompleted)
        }
        // Include entries later discarded by queue recovery, and dequeues whose writes fail.
        for event in queueEvents.sorted(by: { $0.timestamp < $1.timestamp }) {
            let id = event.identity
            let key = "\(id.runtimeSessionID)/\(id.transportGeneration)/\(id.streamEpoch)/\(id.deviceObjectID)/\(id.sampleRate)/\(id.channelCount)"
            if event.isEntry {
                emittedSizes[id.frameCount, default: 0] += 1
                add("Input block cadence", priorEntry[key], event.timestamp)
                priorEntry[key] = event.timestamp
            } else {
                add("Writer dequeue cadence", priorDequeue[key], event.timestamp)
                priorDequeue[key] = event.timestamp
            }
        }
        var interactions: [String: [Double]] = [:]; var transitions: [String: [Double]] = [:]
        func addOperation(_ name: String, _ start: PerformanceTick, _ end: PerformanceTick?, interaction: Bool) {
            guard let end, end >= start else { return }
            let duration = PerformanceClock.milliseconds(start, end)
            if interaction { interactions[name, default: []].append(duration) }
            else { transitions[name, default: []].append(duration) }
        }
        for operation in operations where operation.kind == "Live EQ apply" {
            addOperation("UI draft acceptance", operation.started, operation.phases.first { $0.name == "draft accepted" }?.timestamp, interaction: true)
            if operation.result == "success" {
                addOperation("Live EQ runtime acknowledgement", operation.started, operation.phases.first { $0.name == "backend acknowledged" }?.timestamp, interaction: true)
            }
        }
        for operation in operations where operation.result == "success" {
            let interaction = operation.kind == "Live EQ apply" || operation.kind == "Profile Save"
            addOperation("\(operation.kind): total", operation.started, operation.ended, interaction: interaction)
            var previous = operation.started
            for phase in operation.phases {
                addOperation("\(operation.kind): \(phase.name)", previous, phase.timestamp, interaction: interaction)
                previous = phase.timestamp
            }
        }
        var mismatches: Set<String> = []
        var recoveryDelta: UInt64 = 0; var dropDelta: UInt64 = 0; var transportDelta: UInt64 = 0
        var previous = environment
        for observation in observations {
            let current = observation.environment
            if let expected = options.scenario.expectedApplications, expected != current.activeApplications { mismatches.insert("Active application count differs from scenario") }
            if let expected = options.scenario.expectedSampleRate, expected != current.sampleRate { mismatches.insert("Sample rate differs from scenario") }
            if let expected = options.scenario.expectedPlaybackMode, expected != current.playbackMode { mismatches.insert("Playback mode differs from scenario") }
            if let expected = options.scenario.expectedProfileVisible, expected != current.profileVisible { mismatches.insert("Profile visibility differs from scenario") }
            if let expected = options.scenario.expectedWindowVisible, expected != current.windowVisible { mismatches.insert("Window visibility differs from scenario") }
            if let minimum = options.scenario.minimumApplications, current.activeApplications < minimum { mismatches.insert("Fewer active applications than requested") }
            if options.scenario.requiresNonDirectMode && (current.playbackMode == nil || current.playbackMode == PlaybackMode.direct.rawValue) { mismatches.insert("Scenario requires spatial/reference processing") }
            if options.scenario.requiresOtherSampleRate && (current.sampleRate == nil || current.sampleRate == 48_000) { mismatches.insert("Scenario requires a supported rate other than 48 kHz") }
            do {
                let same = current.sessionID == nil || current.sessionID == previous.sessionID
                recoveryDelta += same && current.recoveries >= previous.recoveries ? current.recoveries - previous.recoveries : current.recoveries
                dropDelta += same && current.droppedFrames >= previous.droppedFrames ? current.droppedFrames - previous.droppedFrames : current.droppedFrames
                transportDelta += same && current.transportDroppedFrames >= previous.transportDroppedFrames ? current.transportDroppedFrames - previous.transportDroppedFrames : current.transportDroppedFrames
            }
            previous = current
        }
        if options.scenario.requiresMixedPacketSizes && packetSizes.count < 2 { mismatches.insert("Mixed packet sizes were not observed") }
        recoveryDelta = max(recoveryDelta, UInt64(recoveries.count))
        dropDelta = max(dropDelta, recoveries.reduce(0) { $0 + UInt64(max(0, $1.droppedFrames)) })
        if Set(samples.map { $0.identity.runtimeSessionID }).count > 1 { mismatches.insert("Capture spans multiple runtime sessions; inspect individual identities") }
        if samples.isEmpty && options.detailedAudioTracing { mismatches.insert("No completed audio blocks were observed") }
        let duration = Double(PerformanceClock.duration(from: capture.start, to: end)) / 1e9
        let cpu = observations.last.map { max(0, $0.environment.processCPUSeconds - environment.processCPUSeconds) }
        var presentationValues: [String: [Double]] = [:]
        for sample in presentationSamples { presentationValues[sample.phase, default: []].append(PerformanceClock.milliseconds(sample.started, sample.ended)) }
        var baseline = PerformanceBaseline(captureID: capture.id, startedAt: startedAt, measurementStart: capture.start, ended: end,
            options: options, environment: environment, observations: observations,
            audio: values.mapValues(LatencyDistribution.init), interactions: interactions.mapValues(LatencyDistribution.init),
            transitions: transitions.mapValues(LatencyDistribution.init), packetSizes: packetSizes, emittedSizes: emittedSizes,
            packetFrameDistribution: FrameSizeDistribution(packets.map { $0.identity.frameCount }),
            emittedFrameDistribution: FrameSizeDistribution(queueEvents.filter(\.isEntry).map { $0.identity.frameCount }),
            queueOccupancy: LatencyDistribution(queueEvents.filter(\.isEntry).map { Double($0.queuedFrames) * 1000 / $0.identity.sampleRate }),
            samples: samples, packets: packets, queueEvents: queueEvents.sorted { $0.timestamp < $1.timestamp }, recoveries: recoveries.sorted { $0.timestamp < $1.timestamp }, operations: operations,
            telemetryDrops: drops, scenarioMismatches: mismatches.sorted(), recoveriesDuringCapture: recoveryDelta,
            droppedFramesDuringCapture: dropDelta, transportDroppedFramesDuringCapture: transportDelta,
            processCPUPercent: duration > 0 ? cpu.map { $0 / duration * 100 } : nil, stopReason: stopReason)
        baseline.presentation = .init(statistics: observations.last?.environment.presentationStatistics.map { $0.delta(since: environment.presentationStatistics ?? .init()) },
            durations: presentationValues.mapValues(LatencyDistribution.init), samples: presentationSamples)
        return baseline
    }
}

extension PerformanceBaseline {
    func redacted(_ redact: Bool) -> Self {
        guard redact else { return self }
        var copy = self
        copy.environment.outputName = "<redacted>"; copy.environment.outputUID = "<redacted>"
        copy.observations = observations.map { observation in
            var environment = observation.environment
            environment.outputName = "<redacted>"; environment.outputUID = "<redacted>"
            return .init(timestamp: observation.timestamp, environment: environment)
        }
        return copy
    }
    func json(redactNames: Bool = true) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(redacted(redactNames))
    }
    func report(redactNames: Bool = true) -> String {
        let baseline = redacted(redactNames)
        let env = baseline.environment
        func ms(_ value: Double) -> String { String(format: "%.3f", value) }
        var lines = ["CamiTune Performance Baseline", "Build: \(env.version) (\(env.build)) · \(env.configuration)",
            "macOS: \(env.macOS) · \(env.architecture)", "Commit: \(env.gitCommit ?? "Unavailable")",
            "Capture: \(captureID) · \(startedAt.ISO8601Format())",
            "Measured duration: \(ms(Double(PerformanceClock.duration(from: measurementStart, to: ended)) / 1e9)) s; warm-up: \(options.warmUp) s",
            "Scenario: \(options.scenario.label)", "Detailed audio tracing: \(options.detailedAudioTracing ? "ON" : "OFF (coarse counters and CPU only)")", "Stop: \(stopReason)",
            "Output: \(env.outputName ?? "Inactive") · UID: \(env.outputUID ?? "None")",
            "Session: \(env.sessionID?.uuidString ?? "Inactive")",
            "Format: \(env.sampleRate ?? 0) Hz / \(env.channelCount ?? 0) channels; mode: \(env.playbackMode ?? "Inactive"); spatial: \(env.spatialMode ?? "Inactive")",
            "Processing stages: \(env.processingStages ?? 0); Camilla chunk: \(env.chunkSize ?? 0) frames",
            "Applications: \(env.activeApplications); window visible: \(env.windowVisible); profile visible: \(env.profileVisible)",
            "Queue policy: 100 ms, at least one incoming block; clear on overflow/rate change",
            "Mixer policy: two largest packets held back; idle delay max(4 ms, 1.5 × packet duration)",
            "Telemetry drops: \(telemetryDrops)\(telemetryDrops > 0 ? " — MEASUREMENT INCOMPLETE" : "")",
            "Coverage: \(packets.count) packets; \(samples.count) completed writes; \(samples.filter { $0.packetReceived != nil }.count) full receipt traces",
            "In-process timing ends at Camilla input. It is not physical playback latency.", "",
            "Metric | count | median | p95 | p99 | max (ms)"]
        for (title, metrics) in [("Audio path", audio), ("Interactions", interactions), ("Transitions", transitions)] {
            lines.append(title)
            for name in metrics.keys.sorted() {
                let metric = metrics[name]!
                lines.append("\(name) | \(metric.sampleCount) | \(ms(metric.medianMilliseconds)) | \(ms(metric.p95Milliseconds)) | \(ms(metric.p99Milliseconds)) | \(ms(metric.maximumMilliseconds))")
            }
        }
        lines += ["", "Queue occupancy at entry (\(queueOccupancy.sampleCount) samples): median \(ms(queueOccupancy.medianMilliseconds)) ms; mean \(ms(queueOccupancy.meanMilliseconds)) ms",
                  "Recoveries during capture: \(recoveriesDuringCapture); dropped frames: \(droppedFramesDuringCapture); bridge drops: \(transportDroppedFramesDuringCapture)"]
        if let final = observations.last?.environment.queue {
            lines.append("Queue current: \(final.queuedFrames) frames / \(ms(final.durationMilliseconds)) ms @ \(final.sampleRate) Hz; capacity: \(final.capacityFrames) frames / \(ms(final.capacityMilliseconds)) ms")
            lines.append("Session queue peak: \(final.peakQueuedFrames) frames; peak duration: \(ms(final.peakDurationMilliseconds)) ms (may precede capture)")
        }
        for recovery in recoveries {
            lines.append("Recovery +\(ms(PerformanceClock.milliseconds(measurementStart, recovery.timestamp) / 1000)) s: \(recovery.queuedFramesBeforeRecovery) frames + \(recovery.incomingFrames), dropped \(recovery.droppedFrames) frames / \(ms(Double(recovery.droppedFrames) * 1000 / recovery.sampleRate)) ms @ \(recovery.sampleRate) Hz; writer block \(recovery.writerBlockInProgressFrames) frames")
            if let active = samples.first(where: { $0.identity.runtimeSessionID == recovery.runtimeSessionID && $0.queueLeft <= recovery.timestamp && $0.pipeWriteCompleted > recovery.timestamp }) {
                let phases: [(String, PerformanceTick, PerformanceTick)] = [
                    ("render", active.queueLeft, active.renderCompleted),
                    ("resample", active.renderCompleted, active.resampleCompleted),
                    ("master", active.resampleCompleted, active.masterCompleted),
                    ("payload", active.masterCompleted, active.pipeWriteStarted),
                    ("pipe write", active.pipeWriteStarted, active.pipeWriteCompleted)]
                if let phase = phases.first(where: { $0.1 <= recovery.timestamp && recovery.timestamp < $0.2 }) {
                    lines.append("  Writer phase active at recovery: \(phase.0), completed duration \(ms(PerformanceClock.milliseconds(phase.1, phase.2))) ms")
                }
            }
            if let preceding = samples.filter({ $0.identity.runtimeSessionID == recovery.runtimeSessionID && $0.pipeWriteCompleted <= recovery.timestamp }).max(by: { $0.pipeWriteCompleted < $1.pipeWriteCompleted }) {
                lines.append("  Preceding completed writer: queue \(ms(PerformanceClock.milliseconds(preceding.queueEntered, preceding.queueLeft))) ms, render \(ms(PerformanceClock.milliseconds(preceding.queueLeft, preceding.renderCompleted))) ms, pipe \(ms(PerformanceClock.milliseconds(preceding.pipeWriteStarted, preceding.pipeWriteCompleted))) ms")
            }
        }
        func histogram(_ bins: [Int: Int]) -> String {
            let total = max(1, bins.values.reduce(0, +))
            return bins.sorted { $0.key < $1.key }.map { "\($0.key) frames: \($0.value) (\(String(format: "%.1f", Double($0.value) * 100 / Double(total)))%)" }.joined(separator: ", ")
        }
        lines += ["", "Packet frame-size histogram: \(histogram(packetSizes))",
                  "Emitted frame-size histogram (queue entries): \(histogram(emittedSizes))"]
        lines.append("Packet frames: min \(packetFrameDistribution.minimumFrames), median \(packetFrameDistribution.medianFrames), max \(packetFrameDistribution.maximumFrames)")
        lines.append("Emitted frames: min \(emittedFrameDistribution.minimumFrames), median \(emittedFrameDistribution.medianFrames), max \(emittedFrameDistribution.maximumFrames)")
        lines.append("Coalesced operations: \(operations.filter { $0.result == "coalesced" }.count)")
        for operation in operations {
            lines.append("Operation \(operation.id.rawValue) parent \(operation.parentID.map { String($0.rawValue) } ?? "none"): \(operation.kind), \(operation.reason), revision \(operation.revision.map(String.init) ?? "none"), \(operation.result)")
            for phase in operation.phases { lines.append("  +\(ms(PerformanceClock.milliseconds(operation.started, phase.timestamp))) ms: \(phase.name)") }
        }
        lines += ["", "Downstream observations are snapshots, not additional measured latency.",
                  "DSP telemetry: \(env.telemetryHealth); load: \(env.dspLoad.map(ms) ?? "Unavailable")%; buffer: \(env.dspBufferFrames.map(String.init) ?? "Unavailable") frames; resampler: \(env.dspResamplerLoad.map(ms) ?? "Unavailable")%",
                  "Process CPU during capture: \(processCPUPercent.map(ms) ?? "Unavailable")% (100% = one core)"]
        if let comparison = overheadComparison {
            lines += ["", "Tracing OFF/ON sanity check: \(comparison.workload)",
                "Identical PCM: \(comparison.identicalPCM)",
                "Recoveries OFF/ON: \(comparison.offRecoveries)/\(comparison.onRecoveries); dropped frames: \(comparison.offDroppedFrames)/\(comparison.onDroppedFrames)",
                "Queue peak frames OFF/ON: \(comparison.offQueuePeakFrames)/\(comparison.onQueuePeakFrames)",
                "CPU seconds OFF/ON: \(ms(comparison.offCPUSeconds))/\(ms(comparison.onCPUSeconds)); elapsed seconds: \(ms(comparison.offDurationSeconds))/\(ms(comparison.onDurationSeconds))",
                "Writer p99 ON: \(ms(comparison.onWriterP99Milliseconds)) ms. OFF phase timing is intentionally unavailable."]
        }
        if let presentation {
            lines.append("\nPresentation | count | median | p95 | p99 | max (ms)")
            if let stats = presentation.statistics {
                lines.append("Requests: \(stats.requests) (meter \(stats.meterRequests), immediate \(stats.immediateRequests)); coalesced: \(stats.coalescedRequests)")
                lines.append("Drains: \(stats.workerDrains); builds: \(stats.snapshotsBuilt); trailing builds: \(stats.trailingBuilds); MainActor deliveries: \(stats.mainDeliveries); maximum pending drains (publisher lifetime): \(stats.maximumPendingDrains)")
            }
            for name in presentation.durations.keys.sorted() {
                let metric = presentation.durations[name]!
                lines.append("\(name) | \(metric.sampleCount) | \(ms(metric.medianMilliseconds)) | \(ms(metric.p95Milliseconds)) | \(ms(metric.p99Milliseconds)) | \(ms(metric.maximumMilliseconds))")
            }
        }
        lines += scenarioMismatches.map { "Scenario/coverage note: \($0)" }
        lines.append("Cadence distributions use actual queue entries/dequeues, including entries later discarded by recovery. Writer phase distributions include completed writes only. Inspect event timestamps and writer phases before attributing a recovery to a cause.")
        return lines.joined(separator: "\n")
    }
}
