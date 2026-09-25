import CamiTuneDomain
import Foundation







/// Device sample time is the timeline; storage must not change emission policy.
/// Intentionally unsynchronized: the owner provides exclusive synchronous access.
/// Production calls (including prepare + DSP + mix) hold the controller's audioLock.
/// Borrowed packet samples never escape a call; emitted PCMFrame arrays are owned.
package final class PerAppTimelineMixer {
    package private(set) var statistics = PerAppTimelineMixerStatistics()
    private var reorderPolicies: [UInt32: TimelineReorderPolicy] = [:]
    private let policyConfiguration: TimelineReorderPolicyConfiguration
    private let policyClock: TimelinePolicyClock
    private let policyTrace: TimelinePolicyTrace?
    private var emissionReasons: [UInt32: TimelineEmissionReason] = [:]
    private var completionBatch: (device: UInt32, epoch: UInt64, start: Int64, end: Int64, insertedBefore: UInt64, expected: UInt64)?
    private var completionStorage: [UInt32: TimelineCircularStorage] = [:]
    package private(set) var lastReorderEvidence: TimelineReorderEvidence?
    private let storagePolicy: TimelineStoragePolicy
    package private(set) var lastWork: TimelineWorkSample?
    private var measuring = false
    private var materializationMilliseconds = 0.0
    private var growthMilliseconds = 0.0
    package init(storagePolicy: TimelineStoragePolicy, policyConfiguration: TimelineReorderPolicyConfiguration = .production,
         clock: TimelinePolicyClock = .live, policyTrace: TimelinePolicyTrace? = nil) {
        self.policyTrace = policyTrace
        self.storagePolicy = storagePolicy; self.policyConfiguration = policyConfiguration; policyClock = clock
    }
    private var nextStreamEpoch: UInt64 = 0
    private var epochs: [UInt32: UInt64] = [:]
    private var pendingMixesByDevice: [UInt32: PendingMix] = [:]
    private var lastEmittedEndSampleTimeByDevice: [UInt32: Int64] = [:]
    private static let timelineRestartRewindMultiplier = 4
    private static let timelineDiscontinuityMultiplier = 8

    private func newEpoch(for device: UInt32) {
        nextStreamEpoch &+= 1
        epochs[device] = nextStreamEpoch
        statistics.latestStreamEpoch = nextStreamEpoch
    }

    package func statisticsSnapshot() -> PerAppTimelineMixerStatistics {
        var result = statistics
        result.policySnapshots = reorderPolicies.keys.sorted().compactMap { device in
            guard var snapshot = reorderPolicies[device]?.snapshot else { return nil }
            snapshot.deviceObjectID = device; return snapshot
        }
        return result
    }

    // Export only after the transport has stopped. Never copy trace storage in a UI poll.
    package func policyTraceDocument() -> TimelinePolicyTraceDocument? {
        policyTrace?.document(configuration: policyConfiguration, statistics: statisticsSnapshot())
    }

    package func reset() {
        completionBatch = nil
        completionStorage.removeAll()
        policyTrace?.append(.init(kind: .reset, tick: policyClock.now()))
        pendingMixesByDevice.removeAll(keepingCapacity: true)
        lastEmittedEndSampleTimeByDevice.removeAll(keepingCapacity: true)
        epochs.removeAll(keepingCapacity: true)
        reorderPolicies.removeAll(keepingCapacity: true)
        emissionReasons.removeAll(keepingCapacity: true)
        nextStreamEpoch &+= 1
        observeStorage()
    }

    /// Producer-authorized interval. Pad its exact extent with zero, then place
    /// every processed contribution before allowing any emission. A reset or a
    /// failed insertion invalidates the entire batch rather than emitting a mix
    /// assembled from only some clients.
    package func beginCompletedInterval(_ interval: ProducerCompletedInterval) throws {
        guard completionBatch == nil, pendingMixesByDevice[interval.device] == nil,
              interval.end > interval.start else {
            throw ProducerCompletionFault(reason: "mixer is not quiescent at the producer interval boundary")
        }
        if interval.beginsEpoch {
            resetDeviceTimelineLocked(interval.device)
            // The producer owns this epoch; the legacy rewind heuristic must
            // neither invent an identity nor reinterpret its completion fence.
            epochs[interval.device] = interval.epoch
            statistics.latestStreamEpoch = interval.epoch
        }
        guard epochs[interval.device] == interval.epoch else {
            throw ProducerCompletionFault(reason: "completed interval has no matching producer epoch")
        }
        let frames = Int(interval.end - interval.start)
        let storage = try completionStorage[interval.device]
            ?? TimelineCircularStorage(channelCount: interval.channels, maximumFrames: storagePolicy.maximumFrames)
        guard storage.frameCount == 0, storage.channelCount == interval.channels else {
            throw ProducerCompletionFault(reason: "completed interval storage was not retired")
        }
        try reserve(storage, frames: frames)
        completionStorage[interval.device] = storage
        storage.extend(to: frames)
        pendingMixesByDevice[interval.device] = PendingMix(performanceTrace: nil, deviceObjectID: interval.device,
            startSampleTime: interval.start, channelCount: interval.channels, sampleRate: interval.rate,
            channelLayout: interval.layout, storage: storage, largestPacketFrames: frames)
        completionBatch = (interval.device, interval.epoch, interval.start, interval.end, statistics.insertedFrames,
            UInt64(interval.contributions.reduce(0) { $0 + $1.frames }))
    }

    package func finishCompletedInterval(_ interval: ProducerCompletedInterval) throws -> PCMFrame {
        guard let batch = completionBatch, batch.device == interval.device, batch.epoch == interval.epoch,
              batch.start == interval.start, batch.end == interval.end,
              statistics.insertedFrames - batch.insertedBefore == batch.expected,
              let mix = pendingMixesByDevice[interval.device], mix.startSampleTime == batch.start,
              mix.endSampleTime == batch.end,
              let frame = emitAllPendingMixLocked(for: interval.device, reason: .producerCompletion) else {
            completionBatch = nil
            pendingMixesByDevice.removeValue(forKey: interval.device)
            throw ProducerCompletionFault(reason: "producer interval was interrupted or a contribution failed")
        }
        completionBatch = nil
        observeStorage()
        return frame
    }

    package func preparePacket(_ packet: PerAppTimelinePacket) -> TimelinePacketPreparation {
        guard (1...32).contains(packet.channelCount), packet.channelLayout.channelCount == packet.channelCount,
              packet.sampleRate.isFinite, packet.sampleRate > 0, packet.frameCount > 0,
              !packet.startSampleTime.addingReportingOverflow(Int64(packet.frameCount)).overflow else {
            statistics.invalidPackets += 1
            return .init(packet: packet, streamEpoch: epochs[packet.deviceObjectID] ?? 0, requiresClientDSPReset: false, isValid: false)
        }
        guard storagePolicy.reservation(for: packet.frameCount) != nil else {
            statistics.capacityFailures += 1
            return .init(packet: packet, streamEpoch: epochs[packet.deviceObjectID] ?? 0, requiresClientDSPReset: false, isValid: false)
        }
        if let batch = completionBatch {
            let valid = packet.deviceObjectID == batch.device && packet.startSampleTime >= batch.start
                && packet.startSampleTime + Int64(packet.frameCount) <= batch.end
            return .init(packet: packet, streamEpoch: epochs[packet.deviceObjectID] ?? 0,
                requiresClientDSPReset: false, isValid: valid)
        }
        var boundaryReason: TimelineBoundaryReason?
        if epochs[packet.deviceObjectID] == nil { newEpoch(for: packet.deviceObjectID); boundaryReason = .initial }
        let restart = prepareTimelineEpochLocked(deviceObjectID: packet.deviceObjectID,
            packetStartSampleTime: packet.startSampleTime, packetFrameCount: packet.frameCount,
            sampleRate: packet.sampleRate, cycleCounter: packet.cycleCounter)
        if restart { boundaryReason = .restart }
        if let mix = pendingMixesByDevice[packet.deviceObjectID],
           mix.channelCount != packet.channelCount || mix.channelLayout != packet.channelLayout
            || abs(mix.sampleRate - packet.sampleRate) >= 0.5
            || Self.distance(packet.startSampleTime, mix.endSampleTime) > Int64(max(mix.largestPacketFrames, packet.frameCount) * Self.timelineDiscontinuityMultiplier) {
            boundaryReason = mix.channelCount != packet.channelCount || mix.channelLayout != packet.channelLayout
                || abs(mix.sampleRate - packet.sampleRate) >= 0.5 ? .format : .discontinuity
            newEpoch(for: packet.deviceObjectID)
        }
        return .init(packet: packet, streamEpoch: epochs[packet.deviceObjectID]!, requiresClientDSPReset: restart, boundaryReason: boundaryReason)
    }

    package func mixProcessedPacket(_ preparation: TimelinePacketPreparation, samples: UnsafeBufferPointer<Float>,
                            policyNow: PerformanceTick? = nil, performance: PacketPerformanceContext? = nil,
                            processingCompleted: PerformanceTick? = nil) -> PCMFrame? {
        lastWork = nil
        lastReorderEvidence = nil
        guard preparation.isValid, samples.count == preparation.packet.frameCount * preparation.packet.channelCount else { return nil }
        let packet = preparation.packet
        let instant = policyNow ?? policyClock.now()
        let policyStarted = performance.map { _ in PerformanceClock.now() }
        // Completed intervals have one safety authority: the ordered producer
        // fence. Historical adaptive/legacy policy remains a diagnostic replay
        // path; running it here would add redundant state and idle deadlines.
        if completionBatch == nil {
            if let boundary = preparation.boundaryReason {
                policyTrace?.append(.init(kind: .boundary, tick: instant, deviceObjectID: packet.deviceObjectID,
                    epoch: preparation.streamEpoch, boundaryReason: boundary))
            }
            let sameEpoch = reorderPolicies[packet.deviceObjectID]?.observation.epoch == preparation.streamEpoch
            let anchor = pendingMixesByDevice[packet.deviceObjectID]?.startSampleTime ?? lastEmittedEndSampleTimeByDevice[packet.deviceObjectID]
            let maximumSpan = max(packet.frameCount, reorderPolicies[packet.deviceObjectID]?.observation.largestPacketFrames ?? 0) * Self.timelineDiscontinuityMultiplier
            let farStale = sameEpoch && anchor.map { Self.distance($0, packet.startSampleTime + Int64(packet.frameCount)) > Int64(maximumSpan) } == true
            if farStale { statistics.reorder.excludedPackets += 1 }
            else {
                var policy = sameEpoch ? reorderPolicies[packet.deviceObjectID]! : TimelineReorderPolicy(epoch: preparation.streamEpoch, sampleRate: packet.sampleRate, configuration: policyConfiguration)
                let evidence = policy.observe(packet, committedEnd: sameEpoch ? lastEmittedEndSampleTimeByDevice[packet.deviceObjectID] : nil,
                    tick: instant, reason: sameEpoch ? emissionReasons[packet.deviceObjectID] : nil)
                lastReorderEvidence = evidence
                reorderPolicies[packet.deviceObjectID] = policy
            }
        }
        measuring = performance != nil
        materializationMilliseconds = 0; growthMilliseconds = 0
        let started = measuring ? PerformanceClock.now() : nil
        let policyMilliseconds = policyStarted.map { PerformanceClock.milliseconds($0, started!) }
        let before = statistics
        var emittedFrames = 0
        defer {
            observeStorage()
            if let started {
                let total = PerformanceClock.milliseconds(started, PerformanceClock.now())
                lastWork = .init(placementMilliseconds: max(0, total - materializationMilliseconds),
                    materializationMilliseconds: materializationMilliseconds, growthMilliseconds: growthMilliseconds,
                    insertedFrames: Int(statistics.insertedFrames - before.insertedFrames), emittedFrames: emittedFrames, prependedFrames: statistics.prependFrames - before.prependFrames,
                    pendingBefore: before.currentPendingFrames, pendingAfter: statistics.currentPendingFrames,
                    capacityFrames: statistics.currentStorageCapacityFrames,
                    wrappedRead: statistics.wrappedReads > before.wrappedReads,
                    wrappedWrite: statistics.wrappedWrites > before.wrappedWrites, policyMilliseconds: policyMilliseconds)
            }
            measuring = false
        }
        var performance = performance
        performance?.identity.streamEpoch = preparation.streamEpoch
        let completed = mixProcessedPacketLocked(packet, mode: packet.playbackMode,
            packetStartSampleTime: packet.startSampleTime, samples: samples,
            instant: instant, performance: performance, processingCompleted: processingCompleted)
        if var evidence = lastReorderEvidence {
            // Placement may trim the packet or begin a fresh pending window.
            // Report the window actually applied, not the pre-placement guess.
            evidence.activeWindowFrames = reorderPolicies[packet.deviceObjectID]!.currentCommitWindowFrames
            lastReorderEvidence = evidence
            statistics.reorder.record(evidence)
            policyTrace?.append(.init(kind: .packet, tick: instant, evidence: evidence))
        }
        emittedFrames = completed?.frameCount ?? 0
        return completed
    }

    /// Wall Date is retained only for source compatibility with meter/test callers.
    /// Eligibility always uses the independent monotonic policy instant.
    package func flushExpired(policyNow: PerformanceTick? = nil, transportRead: TimelineTransportReadObservation? = nil) -> PerAppMixFlushResult {
        guard completionBatch == nil else { return .idle }
        defer { observeStorage() }
        let instant = policyNow ?? policyClock.now()
        policyTrace?.append(.init(kind: .idleWake, tick: instant, transportRead: transportRead))
        var next = nextDeadline()
        // Finish iteration before mutating the dictionary: retaining its keys
        // iterator during mutation could copy policy storage on every idle wake.
        // Other counterfactual timers also expire lazily before their next packet.
        while let selected = next, !selected.actual, instant >= selected.deadline {
            reorderPolicies[selected.device]?.advanceIdle(at: instant)
            next = nextDeadline()
        }
        guard let selected = next else { return .idle }
        guard selected.actual && instant >= selected.deadline else {
            return .retryAfter(Double(selected.deadline.rawValue - instant.rawValue) / 1_000_000_000)
        }
        reorderPolicies[selected.device]?.advanceIdle(at: instant)
        let execution = pendingMixesByDevice[selected.device]?.performanceTrace.map { _ in PerformanceClock.now() }
        guard let frame = emitAllPendingMixLocked(for: selected.device, reason: .idleTail,
            eligible: selected.deadline, idleDeadline: selected.deadline, idleFlushStarted: execution) else { return .idle }
        return .flushed(frame)
    }

    package func policyInstant() -> PerformanceTick { policyClock.now() }

    package func nextWakeDelay(policyNow: PerformanceTick? = nil) -> TimeInterval? {
        let instant = policyNow ?? policyClock.now()
        return nextDeadline().map { Double(PerformanceClock.duration(from: instant, to: $0.deadline)) / 1_000_000_000 }
    }

    private func nextDeadline() -> (device: UInt32, deadline: PerformanceTick, actual: Bool)? {
        var selected: (device: UInt32, deadline: PerformanceTick, actual: Bool)?
        for device in pendingMixesByDevice.keys {
            guard let deadline = reorderPolicies[device]?.idleDeadline else { continue }
            if selected == nil || deadline < selected!.deadline { selected = (device, deadline, true) }
        }
        for (device, policy) in reorderPolicies {
            if let deadline = policy.shadowIdleDeadline, selected == nil || deadline < selected!.deadline {
                selected = (device, deadline, false)
            }
        }
        return selected
    }

    private struct PendingMix {
        var performanceTrace: MixPerformanceTrace? = nil
        var deviceObjectID: UInt32
        var startSampleTime: Int64
        var channelCount: Int
        var sampleRate: Double
        var channelLayout: LPCMChannelLayout

        var storage: TimelineCircularStorage
        var largestPacketFrames: Int

        var frameCount: Int {
            storage.frameCount
        }

        var endSampleTime: Int64 {
            startSampleTime + Int64(frameCount)
        }
    }

    private func prepareTimelineEpochLocked(
        deviceObjectID: UInt32,
        packetStartSampleTime: Int64,
        packetFrameCount: Int,
        sampleRate: Double,
        cycleCounter: UInt64
    ) -> Bool {
        guard packetFrameCount > 0 else { return false }
        let packetEnd = packetStartSampleTime + Int64(packetFrameCount)
        let emittedEnd = lastEmittedEndSampleTimeByDevice[deviceObjectID]
        let pendingEnd = pendingMixesByDevice[deviceObjectID]?.endSampleTime
        guard let referenceEnd = [emittedEnd, pendingEnd].compactMap({ $0 }).max() else {
            return false
        }

        let nominalRewindFrames = max(
            packetFrameCount * Self.timelineRestartRewindMultiplier,
            Int(min(Double(Int.max / 8), max(1, sampleRate) * 0.1))
        )
        let rewindFrames = Self.distance(referenceEnd, packetEnd)
        // A true IO restart normally recycles mIOCycleCounter near zero. Use
        // that only as a restart hint after the device sample timeline itself
        // has made a large backwards jump; never use it to order applications.
        if rewindFrames > Int64(nominalRewindFrames), cycleCounter <= 16 {
            resetDeviceTimelineLocked(deviceObjectID)
            statistics.timelineRestarts += 1
            return true
        }
        return false
    }

    private func resetDeviceTimelineLocked(_ deviceObjectID: UInt32) {
        newEpoch(for: deviceObjectID)
        pendingMixesByDevice.removeValue(forKey: deviceObjectID)
        lastEmittedEndSampleTimeByDevice.removeValue(forKey: deviceObjectID)
        completionStorage.removeValue(forKey: deviceObjectID)
    }

    private func mixProcessedPacketLocked(
        _ packet: PerAppTimelinePacket,
        mode: PlaybackMode,
        packetStartSampleTime: Int64,
        samples: UnsafeBufferPointer<Float>,
        instant: PerformanceTick,
        performance: PacketPerformanceContext?,
        processingCompleted: PerformanceTick?
    ) -> PCMFrame? {
        let channelCount = packet.channelCount
        var sourceFrameOffset = 0
        var packetFrameCount = samples.count / channelCount
        var packetStart = packetStartSampleTime
        guard packetFrameCount > 0 else { return nil }

        // If a callback finishes after part of its timeline has already been
        // committed, trim only that already-rendered prefix. A fully stale
        // callback is ignored; the client is never permanently disabled.
        if let emittedEnd = lastEmittedEndSampleTimeByDevice[packet.deviceObjectID],
           packetStart < emittedEnd {
            let staleFrames = min(
                packetFrameCount,
                Int(max(0, Self.distance(emittedEnd, packetStart)))
            )
            if staleFrames >= packetFrameCount { statistics.fullyStalePackets += 1; return nil }
            statistics.partiallyLatePackets += 1
            sourceFrameOffset = staleFrames
            packetStart += Int64(staleFrames)
            packetFrameCount -= staleFrames
        }

        if var mix = pendingMixesByDevice[packet.deviceObjectID] {
            if mix.performanceTrace?.capture.isStopped == true { mix.performanceTrace = nil }
            let formatMatches = mix.channelCount == channelCount
                && abs(mix.sampleRate - packet.sampleRate) < 0.5
                && mix.channelLayout == packet.channelLayout
            if !formatMatches {
                statistics.formatBoundaries += 1
                let completed = emitAllPendingMixLocked(for: packet.deviceObjectID, reason: .formatBoundary)
                pendingMixesByDevice[packet.deviceObjectID] = makePendingMix(
                    packet,
                    mode: mode,
                    startSampleTime: packetStart,
                    samples: samples, sourceFrameOffset: sourceFrameOffset, frameCount: packetFrameCount,
                    instant: instant,
                    performance: performance, processingCompleted: processingCompleted
                )
                return completed
            }

            let packetEnd = packetStart + Int64(packetFrameCount)
            let maximumSpan = max(
                mix.largestPacketFrames,
                packetFrameCount
            ) * Self.timelineDiscontinuityMultiplier

            // A far-future timestamp means there was an idle/discontinuous
            // interval, not a giant buffer of zero PCM that should be allocated.
            if packetStart > mix.endSampleTime,
               Self.distance(packetStart, mix.endSampleTime) > Int64(maximumSpan) {
                statistics.discontinuityFlushes += 1
                let completed = emitAllPendingMixLocked(for: packet.deviceObjectID, reason: .discontinuity)
                pendingMixesByDevice[packet.deviceObjectID] = makePendingMix(
                    packet,
                    mode: mode,
                    startSampleTime: packetStart,
                    samples: samples, sourceFrameOffset: sourceFrameOffset, frameCount: packetFrameCount,
                    instant: instant,
                    performance: performance, processingCompleted: processingCompleted
                )
                return completed
            }

            // A very old packet that is entirely before the reorder window is
            // stale. Do not let it rewind the live stream or reset another app.
            if packetEnd < mix.startSampleTime,
               Self.distance(mix.startSampleTime, packetEnd) > Int64(maximumSpan) {
                statistics.fullyStalePackets += 1
                return nil
            }

            if mix.performanceTrace == nil, let performance {
                mix.performanceTrace = MixPerformanceTrace(capture: performance.capture, identity: performance.identity,
                    untracedUntil: completionBatch == nil ? mix.endSampleTime : mix.startSampleTime,
                    lastPolicyTick: performance.policyTick ?? performance.received)
            }
            let existingMixEnd = mix.endSampleTime
            statistics.gapFrames += UInt64(max(0, Self.distance(packetStart, existingMixEnd)))
            mix.performanceTrace?.add(performance, processed: processingCompleted, start: packetStart,
                end: packetEnd, existingEnd: existingMixEnd)
            let prependFrames = Int(max(0, Self.distance(mix.startSampleTime, packetStart)))
            let newStart = min(packetStart, mix.startSampleTime)
            let frameOffset = Int(Self.distance(packetStart, newStart))
            let requiredFrames = max(mix.frameCount + prependFrames, frameOffset + packetFrameCount)
            do {
                let reservation = completionBatch == nil
                    ? max(requiredFrames, storagePolicy.reservation(for: max(mix.largestPacketFrames, packetFrameCount)) ?? requiredFrames)
                    : requiredFrames
                try reserve(mix.storage, frames: reservation)
            } catch {
                // Never overwrite unread PCM. Emit the valid window, then begin
                // a separately identified window for a supported input packet.
                statistics.capacityFailures += 1
                let completed = emitAllPendingMixLocked(for: packet.deviceObjectID)
                newEpoch(for: packet.deviceObjectID)
                var nextPerformance = performance
                nextPerformance?.identity.streamEpoch = epochs[packet.deviceObjectID]!
                pendingMixesByDevice[packet.deviceObjectID] = makePendingMix(packet, mode: mode,
                    startSampleTime: packetStart, samples: samples, sourceFrameOffset: sourceFrameOffset,
                    frameCount: packetFrameCount, instant: instant,
                    performance: nextPerformance, processingCompleted: processingCompleted)
                return completed
            }
            if prependFrames > 0 {
                statistics.prependFrames += UInt64(prependFrames)
                mix.storage.prepend(prependFrames)
                mix.startSampleTime = newStart
            }
            mix.storage.extend(to: requiredFrames)
            let wrappedBefore = mix.storage.wrappedWrites
            mix.storage.add(samples, sourceFrameOffset: sourceFrameOffset, frameCount: packetFrameCount, at: frameOffset, mode: mode)
            statistics.wrappedWrites += mix.storage.wrappedWrites - wrappedBefore
            statistics.insertedFrames += UInt64(packetFrameCount)

            mix.largestPacketFrames = max(mix.largestPacketFrames, packetFrameCount)
            reorderPolicies[packet.deviceObjectID]?.acceptedPendingPacket(largest: mix.largestPacketFrames, instant: instant)
            pendingMixesByDevice[packet.deviceObjectID] = mix
        } else {
            pendingMixesByDevice[packet.deviceObjectID] = makePendingMix(
                packet,
                mode: mode,
                startSampleTime: packetStart,
                samples: samples, sourceFrameOffset: sourceFrameOffset, frameCount: packetFrameCount,
                instant: instant,
                performance: performance, processingCompleted: processingCompleted
            )
        }

        observeStorage()
        if completionBatch != nil { return nil }
        guard let pendingMix = pendingMixesByDevice[packet.deviceObjectID] else {
            return nil
        }
        let holdbackFrames = reorderPolicies[packet.deviceObjectID]!.currentCommitWindowFrames
        let safeFrames = pendingMix.frameCount - holdbackFrames
        guard safeFrames > 0 else { return nil }
        return emitPendingPrefixLocked(
            for: packet.deviceObjectID,
            frameCount: safeFrames,
            eligible: pendingMix.performanceTrace.map { _ in PerformanceClock.now() }
        )
    }

    private func makePendingMix(
        _ packet: PerAppTimelinePacket,
        mode: PlaybackMode,
        startSampleTime: Int64,
        samples: UnsafeBufferPointer<Float>,
        sourceFrameOffset: Int, frameCount: Int,
        instant: PerformanceTick,
        performance: PacketPerformanceContext?,
        processingCompleted: PerformanceTick?
    ) -> PendingMix? {
        let storage: TimelineCircularStorage
        do {
            storage = try TimelineCircularStorage(channelCount: packet.channelCount, maximumFrames: storagePolicy.maximumFrames)
            guard let reservation = storagePolicy.reservation(for: frameCount) else { throw TimelineStorageFailure.capacityExceeded }
            try reserve(storage, frames: reservation)
            storage.extend(to: frameCount)
            storage.add(samples, sourceFrameOffset: sourceFrameOffset, frameCount: frameCount, at: 0, mode: mode)
            statistics.insertedFrames += UInt64(frameCount)
        } catch {
            statistics.capacityFailures += 1
            return nil
        }
        var trace = performance.map { MixPerformanceTrace(capture: $0.capture, identity: $0.identity,
            untracedUntil: startSampleTime, lastPolicyTick: $0.policyTick ?? $0.received) }
        trace?.add(performance, processed: processingCompleted, start: startSampleTime,
                   end: startSampleTime + Int64(frameCount), existingEnd: startSampleTime)
        reorderPolicies[packet.deviceObjectID]?.acceptedPendingPacket(largest: max(1, frameCount), instant: instant)
        return PendingMix(
            performanceTrace: trace,
            deviceObjectID: packet.deviceObjectID,
            startSampleTime: startSampleTime,
            channelCount: packet.channelCount,
            sampleRate: packet.sampleRate,
            channelLayout: packet.channelLayout,
            storage: storage,
            largestPacketFrames: max(1, frameCount)
        )
    }

    private func emitAllPendingMixLocked(for deviceObjectID: UInt32, reason: TimelineEmissionReason = .packetFrontier, eligible: PerformanceTick? = nil, idleDeadline: PerformanceTick? = nil, idleFlushStarted: PerformanceTick? = nil) -> PCMFrame? {
        guard let mix = pendingMixesByDevice[deviceObjectID] else { return nil }
        return emitPendingPrefixLocked(
            for: deviceObjectID,
            frameCount: mix.frameCount,
            reason: reason,
            eligible: eligible ?? mix.performanceTrace.map { _ in PerformanceClock.now() },
            idleDeadline: idleDeadline, idleFlushStarted: idleFlushStarted
        )
    }

    private func emitPendingPrefixLocked(
        for deviceObjectID: UInt32,
        frameCount: Int,
        reason: TimelineEmissionReason = .packetFrontier,
        eligible: PerformanceTick? = nil,
        idleDeadline: PerformanceTick? = nil,
        idleFlushStarted: PerformanceTick? = nil
    ) -> PCMFrame? {
        if completionBatch != nil && reason != .producerCompletion { return nil }
        guard var mix = pendingMixesByDevice[deviceObjectID],
              frameCount > 0,
              frameCount <= mix.frameCount else {
            return nil
        }
        if mix.performanceTrace?.capture.isStopped == true { mix.performanceTrace = nil }
        let intervalTrace = eligible.flatMap { mix.performanceTrace?.emit(start: mix.startSampleTime,
            count: frameCount, eligible: $0, deadline: idleDeadline, flushStarted: idleFlushStarted) }
        let materializationStarted = measuring ? PerformanceClock.now() : nil
        let wrappedBefore = mix.storage.wrappedReads
        let materialized = mix.storage.materializePrefix(frameCount)
        statistics.wrappedReads += mix.storage.wrappedReads - wrappedBefore
        if let materializationStarted { materializationMilliseconds += PerformanceClock.milliseconds(materializationStarted, PerformanceClock.now()) }

        var output = PCMFrame(
            interleaved: materialized.combined,
            channelCount: mix.channelCount,
            sampleRate: mix.sampleRate,
            channelLayout: mix.channelLayout)
        output.playbackModeSamples = materialized.modes
        let emittedEnd = mix.startSampleTime + Int64(frameCount)
        lastEmittedEndSampleTimeByDevice[deviceObjectID] = emittedEnd
        emissionReasons[deviceObjectID] = reason
        if reason == .idleTail { statistics.reorder.idleEmissions += 1 }
        if reason == .packetFrontier { statistics.reorder.packetEmissions += 1 }

        if frameCount == mix.frameCount {
            if reason == .producerCompletion { mix.storage.discardPrefix(frameCount) }
            pendingMixesByDevice.removeValue(forKey: deviceObjectID)
        } else {
            mix.storage.discardPrefix(frameCount)
            mix.startSampleTime = emittedEnd
            pendingMixesByDevice[deviceObjectID] = mix
        }
        output.performanceTrace = intervalTrace
        if output.performanceTrace != nil { output.performanceTrace?.emitted = PerformanceClock.now() }
        return output
    }

    private static func distance(_ end: Int64, _ start: Int64) -> Int64 {
        let difference = end.subtractingReportingOverflow(start)
        return difference.overflow ? (end > start ? Int64.max : Int64.min) : difference.partialValue
    }

    private func reserve(_ storage: TimelineCircularStorage, frames: Int) throws {
        guard frames > storage.capacityFrames else { return }
        let started = measuring ? PerformanceClock.now() : nil
        let oldCopies = storage.growthCopiedFrames
        if try storage.reserve(frames) {
            statistics.storageReallocations += 1
            statistics.storageGrowthCopiedFrames += storage.growthCopiedFrames - oldCopies
        }
        if let started { growthMilliseconds += PerformanceClock.milliseconds(started, PerformanceClock.now()) }
    }

    private func observeStorage() {
        var frames = 0; var milliseconds = 0.0; var capacity = 0; var bytes = 0; var buses = 0
        for mix in pendingMixesByDevice.values {
            frames += mix.frameCount
            milliseconds += Double(mix.frameCount) * 1000 / mix.sampleRate
            capacity += mix.storage.capacityFrames
            bytes += mix.storage.allocatedBytes
            buses += mix.storage.allocatedBusCount
        }
        for (device, storage) in completionStorage where pendingMixesByDevice[device] == nil {
            capacity += storage.capacityFrames
            bytes += storage.allocatedBytes
            buses += storage.allocatedBusCount
        }
        statistics.activeDeviceTimelines = epochs.count
        statistics.currentPendingFrames = frames
        statistics.peakPendingFrames = max(statistics.peakPendingFrames, frames)
        statistics.currentPendingMilliseconds = milliseconds
        statistics.peakPendingMilliseconds = max(statistics.peakPendingMilliseconds, milliseconds)
        statistics.currentStorageCapacityFrames = capacity
        statistics.peakStorageCapacityFrames = max(statistics.peakStorageCapacityFrames, capacity)
        statistics.storageBytes = bytes
        statistics.peakStorageBytes = max(statistics.peakStorageBytes, bytes)
        statistics.allocatedBuses = buses
    }
}
