import CamiTuneAudio
import CamiTuneDomain
import Foundation

/// Frozen 9A algorithm, used only by diagnostic differential fixtures.
final class ReferenceLinearTimelineMixer {
    private(set) var statistics = PerAppTimelineMixerStatistics()
    private var nextStreamEpoch: UInt64 = 0
    private var epochs: [UInt32: UInt64] = [:]
    private var pendingMixesByDevice: [UInt32: PendingMix] = [:]
    private var lastEmittedEndSampleTimeByDevice: [UInt32: Int64] = [:]
    private static let pendingMixHoldbackPackets = 2
    private static let timelineRestartRewindMultiplier = 4
    private static let timelineDiscontinuityMultiplier = 8

    private func newEpoch(for device: UInt32) {
        nextStreamEpoch &+= 1
        epochs[device] = nextStreamEpoch
    }

    func reset() {
        pendingMixesByDevice.removeAll(keepingCapacity: true)
        lastEmittedEndSampleTimeByDevice.removeAll(keepingCapacity: true)
        epochs.removeAll(keepingCapacity: true)
        nextStreamEpoch &+= 1
    }

    func preparePacket(_ packet: PerAppTimelinePacket) -> TimelinePacketPreparation {
        if epochs[packet.deviceObjectID] == nil { newEpoch(for: packet.deviceObjectID) }
        let restart = prepareTimelineEpochLocked(deviceObjectID: packet.deviceObjectID,
            packetStartSampleTime: packet.startSampleTime, packetFrameCount: packet.frameCount,
            sampleRate: packet.sampleRate, cycleCounter: packet.cycleCounter)
        if let mix = pendingMixesByDevice[packet.deviceObjectID],
           mix.channelCount != packet.channelCount || mix.channelLayout != packet.channelLayout
            || abs(mix.sampleRate - packet.sampleRate) >= 0.5
            || packet.startSampleTime - mix.endSampleTime > Int64(max(mix.largestPacketFrames, packet.frameCount) * Self.timelineDiscontinuityMultiplier) {
            newEpoch(for: packet.deviceObjectID)
        }
        return .init(packet: packet, streamEpoch: epochs[packet.deviceObjectID]!, requiresClientDSPReset: restart)
    }

    func mixProcessedPacket(_ preparation: TimelinePacketPreparation, samples: UnsafeBufferPointer<Float>,
                            now: Date, performance: PacketPerformanceContext? = nil,
                            processingCompleted: PerformanceTick? = nil) -> PCMFrame? {
        let packet = preparation.packet
        return mixProcessedPacketLocked(packet, mode: packet.playbackMode,
            packetStartSampleTime: packet.startSampleTime, samples: Array(samples),
            now: now, performance: performance, processingCompleted: processingCompleted)
    }

    func flushExpired(now: Date) -> PerAppMixFlushResult {
        var selectedDevice: UInt32?
        var selectedDeadline = Date.distantFuture
        for (deviceObjectID, mix) in pendingMixesByDevice {
            let packetDuration = Double(max(1, mix.largestPacketFrames)) / mix.sampleRate
            let requiredDelay = max(0.004, packetDuration * 1.5)
            let deadline = mix.lastPacketDate.addingTimeInterval(requiredDelay)
            if deadline < selectedDeadline {
                selectedDeadline = deadline
                selectedDevice = deviceObjectID
            }
        }

        guard let selectedDevice else {
            return .idle
        }
        guard now >= selectedDeadline else {
            return .retryAfter(max(0.0005, selectedDeadline.timeIntervalSince(now)))
        }
        let execution = pendingMixesByDevice[selectedDevice]?.performanceTrace.map { _ in PerformanceClock.now() }
        let deadline: PerformanceTick? = pendingMixesByDevice[selectedDevice].flatMap { mix in
            mix.performanceTrace.map { trace in
                trace.lastPolicyTick.advanced(seconds: max(0.004, Double(max(1, mix.largestPacketFrames)) / mix.sampleRate * 1.5))
            }
        }
        guard let completed = emitAllPendingMixLocked(for: selectedDevice, eligible: deadline ?? execution, idleDeadline: deadline, idleFlushStarted: execution) else {
            return .idle
        }
        return .flushed(completed)
    }

    private struct PendingMix {
        var performanceTrace: MixPerformanceTrace? = nil
        var deviceObjectID: UInt32
        var startSampleTime: Int64
        var channelCount: Int
        var sampleRate: Double
        var channelLayout: LPCMChannelLayout

        var samples: [Float]
        var samplesByMode: [PlaybackMode: [Float]]
        var largestPacketFrames: Int
        var lastPacketDate: Date

        var frameCount: Int {
            channelCount > 0 ? samples.count / channelCount : 0
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
            Int(max(1, sampleRate) * 0.1)
        )
        let rewindFrames = referenceEnd - packetEnd
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
    }

    private func mixProcessedPacketLocked(
        _ packet: PerAppTimelinePacket,
        mode: PlaybackMode,
        packetStartSampleTime: Int64,
        samples: [Float],
        now: Date,
        performance: PacketPerformanceContext?,
        processingCompleted: PerformanceTick?
    ) -> PCMFrame? {
        let channelCount = packet.channelCount
        var packetSamples = samples
        var packetFrameCount = packetSamples.count / channelCount
        var packetStart = packetStartSampleTime
        guard packetFrameCount > 0 else { return nil }

        // If a callback finishes after part of its timeline has already been
        // committed, trim only that already-rendered prefix. A fully stale
        // callback is ignored; the client is never permanently disabled.
        if let emittedEnd = lastEmittedEndSampleTimeByDevice[packet.deviceObjectID],
           packetStart < emittedEnd {
            let staleFrames = min(
                packetFrameCount,
                Int(max(0, emittedEnd - packetStart))
            )
            if staleFrames >= packetFrameCount { statistics.fullyStalePackets += 1; return nil }
            statistics.partiallyLatePackets += 1
            statistics.packetFrontShiftSamples += UInt64(packetSamples.count - staleFrames * channelCount)
            packetSamples.removeFirst(staleFrames * channelCount)
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
                let completed = emitAllPendingMixLocked(for: packet.deviceObjectID)
                pendingMixesByDevice[packet.deviceObjectID] = makePendingMix(
                    packet,
                    mode: mode,
                    startSampleTime: packetStart,
                    samples: packetSamples,
                    now: now,
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
               packetStart - mix.endSampleTime > Int64(maximumSpan) {
                statistics.discontinuityFlushes += 1
                let completed = emitAllPendingMixLocked(for: packet.deviceObjectID)
                pendingMixesByDevice[packet.deviceObjectID] = makePendingMix(
                    packet,
                    mode: mode,
                    startSampleTime: packetStart,
                    samples: packetSamples,
                    now: now,
                    performance: performance, processingCompleted: processingCompleted
                )
                return completed
            }

            // A very old packet that is entirely before the reorder window is
            // stale. Do not let it rewind the live stream or reset another app.
            if packetEnd < mix.startSampleTime,
               mix.startSampleTime - packetEnd > Int64(maximumSpan) {
                statistics.fullyStalePackets += 1
                return nil
            }

            if mix.performanceTrace == nil, let performance {
                mix.performanceTrace = MixPerformanceTrace(capture: performance.capture, identity: performance.identity,
                    untracedUntil: mix.endSampleTime, lastPolicyTick: performance.policyTick ?? performance.received)
            }
            let existingMixEnd = mix.endSampleTime
            statistics.gapFrames += UInt64(max(0, packetStart - existingMixEnd))
            mix.performanceTrace?.add(performance, processed: processingCompleted, start: packetStart,
                end: packetEnd, existingEnd: existingMixEnd)
            if packetStart < mix.startSampleTime {
                let prependFrames = Int(mix.startSampleTime - packetStart)
                statistics.prependFrames += UInt64(prependFrames)
                statistics.prependCopiedFrames += UInt64(mix.frameCount * (1 + mix.samplesByMode.count))
                mix.samples = [Float](
                    repeating: 0,
                    count: prependFrames * channelCount
                ) + mix.samples
                mix.startSampleTime = packetStart
                for key in Array(mix.samplesByMode.keys) {
                    mix.samplesByMode[key] = [Float](repeating: 0,
                        count: prependFrames * channelCount) + mix.samplesByMode[key]!
                }
            }

            let frameOffset = Int(packetStart - mix.startSampleTime)
            let sampleOffset = frameOffset * channelCount
            let requiredSamples = sampleOffset + packetSamples.count
            if requiredSamples > mix.samples.count {
                mix.samples.append(contentsOf: repeatElement(
                    Float(0),
                    count: requiredSamples - mix.samples.count
                ))
            }
            for index in packetSamples.indices {
                mix.samples[sampleOffset + index] += packetSamples[index]
            }
            for key in Set(mix.samplesByMode.keys).union([mode]) {
                var bus = mix.samplesByMode[key] ?? []
                bus.append(contentsOf: repeatElement(Float(0), count: mix.samples.count - bus.count))
                if key == mode {
                    for index in packetSamples.indices { bus[sampleOffset + index] += packetSamples[index] }
                }
                mix.samplesByMode[key] = bus
            }

            mix.largestPacketFrames = max(mix.largestPacketFrames, packetFrameCount)
            mix.lastPacketDate = now
            pendingMixesByDevice[packet.deviceObjectID] = mix
        } else {
            pendingMixesByDevice[packet.deviceObjectID] = makePendingMix(
                packet,
                mode: mode,
                startSampleTime: packetStart,
                samples: packetSamples,
                now: now,
                performance: performance, processingCompleted: processingCompleted
            )
        }

        guard let pendingMix = pendingMixesByDevice[packet.deviceObjectID] else {
            return nil
        }
        let holdbackFrames = max(
            1,
            pendingMix.largestPacketFrames * Self.pendingMixHoldbackPackets
        )
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
        samples: [Float],
        now: Date,
        performance: PacketPerformanceContext?,
        processingCompleted: PerformanceTick?
    ) -> PendingMix {
        var trace = performance.map { MixPerformanceTrace(capture: $0.capture, identity: $0.identity,
            untracedUntil: startSampleTime, lastPolicyTick: $0.policyTick ?? $0.received) }
        trace?.add(performance, processed: processingCompleted, start: startSampleTime,
                   end: startSampleTime + Int64(samples.count / packet.channelCount), existingEnd: startSampleTime)
        return PendingMix(
            performanceTrace: trace,
            deviceObjectID: packet.deviceObjectID,
            startSampleTime: startSampleTime,
            channelCount: packet.channelCount,
            sampleRate: packet.sampleRate,
            channelLayout: packet.channelLayout,
            samples: samples,
            samplesByMode: [mode: samples],
            largestPacketFrames: max(1, samples.count / packet.channelCount),
            lastPacketDate: now
        )
    }

    private func emitAllPendingMixLocked(for deviceObjectID: UInt32, eligible: PerformanceTick? = nil, idleDeadline: PerformanceTick? = nil, idleFlushStarted: PerformanceTick? = nil) -> PCMFrame? {
        guard let mix = pendingMixesByDevice[deviceObjectID] else { return nil }
        return emitPendingPrefixLocked(
            for: deviceObjectID,
            frameCount: mix.frameCount,
            eligible: eligible ?? mix.performanceTrace.map { _ in PerformanceClock.now() },
            idleDeadline: idleDeadline, idleFlushStarted: idleFlushStarted
        )
    }

    private func emitPendingPrefixLocked(
        for deviceObjectID: UInt32,
        frameCount: Int,
        eligible: PerformanceTick? = nil,
        idleDeadline: PerformanceTick? = nil,
        idleFlushStarted: PerformanceTick? = nil
    ) -> PCMFrame? {
        guard var mix = pendingMixesByDevice[deviceObjectID],
              frameCount > 0,
              frameCount <= mix.frameCount else {
            return nil
        }
        if mix.performanceTrace?.capture.isStopped == true { mix.performanceTrace = nil }
        let intervalTrace = eligible.flatMap { mix.performanceTrace?.emit(start: mix.startSampleTime,
            count: frameCount, eligible: $0, deadline: idleDeadline, flushStarted: idleFlushStarted) }
        let sampleCount = frameCount * mix.channelCount
        let outputSamples = Array(mix.samples.prefix(sampleCount))

        var output = PCMFrame(
            interleaved: outputSamples,
            channelCount: mix.channelCount,
            sampleRate: mix.sampleRate,
            channelLayout: mix.channelLayout)
        output.playbackModeSamples = mix.samplesByMode.mapValues { Array($0.prefix(sampleCount)) }
        let emittedEnd = mix.startSampleTime + Int64(frameCount)
        lastEmittedEndSampleTimeByDevice[deviceObjectID] = emittedEnd

        if frameCount == mix.frameCount {
            pendingMixesByDevice.removeValue(forKey: deviceObjectID)
        } else {
            statistics.retainedSuffixShiftFrames += UInt64((mix.frameCount - frameCount) * (1 + mix.samplesByMode.count))
            mix.samples.removeFirst(sampleCount)
            for key in Array(mix.samplesByMode.keys) {
                mix.samplesByMode[key]?.removeFirst(sampleCount)
            }
            mix.startSampleTime = emittedEnd
            pendingMixesByDevice[deviceObjectID] = mix
        }
        output.performanceTrace = intervalTrace
        if output.performanceTrace != nil { output.performanceTrace?.emitted = PerformanceClock.now() }
        return output
    }
}
