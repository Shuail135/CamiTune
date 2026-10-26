import CamiTuneDomain
import Foundation

/// The owner serializes access. Only producer-completed intervals can emit PCM.
package final class PerAppTimelineMixer {
    private struct DeviceStorage {
        let epoch: UInt64
        let samples: TimelineCircularStorage
    }
    private struct Batch {
        let interval: ProducerCompletedInterval
        let storage: TimelineCircularStorage
        let expectedFrames: UInt64
        var insertedFrames: UInt64 = 0
        var trace: MixPerformanceTrace?
    }

    private let storagePolicy: TimelineStoragePolicy
    private var devices: [UInt32: DeviceStorage] = [:]
    private var batch: Batch?
    package private(set) var statistics = PerAppTimelineMixerStatistics()
    package private(set) var lastWork: TimelineWorkSample?

    package init(storagePolicy: TimelineStoragePolicy) { self.storagePolicy = storagePolicy }

    package func reset() {
        batch = nil
        devices.removeAll(keepingCapacity: true)
        lastWork = nil
        observeStorage()
    }

    package func statisticsSnapshot() -> PerAppTimelineMixerStatistics { statistics }

    package func beginCompletedInterval(_ interval: ProducerCompletedInterval) throws {
        guard batch == nil, interval.end > interval.start else {
            throw ProducerCompletionFault(reason: "mixer is not quiescent at the producer interval boundary")
        }
        if interval.beginsEpoch {
            devices[interval.device] = DeviceStorage(epoch: interval.epoch,
                samples: try TimelineCircularStorage(channelCount: interval.channels, maximumFrames: storagePolicy.maximumFrames))
            statistics.latestStreamEpoch = interval.epoch
        }
        guard let device = devices[interval.device], device.epoch == interval.epoch else {
            throw ProducerCompletionFault(reason: "completed interval has no matching producer epoch")
        }
        let storage = device.samples
        guard storage.frameCount == 0, storage.channelCount == interval.channels else {
            throw ProducerCompletionFault(reason: "completed interval storage was not retired")
        }
        let frames = Int(interval.end - interval.start)
        let copiedBefore = storage.growthCopiedFrames
        if try storage.reserve(frames) {
            statistics.storageReallocations += 1
            statistics.storageGrowthCopiedFrames += storage.growthCopiedFrames - copiedBefore
        }
        storage.extend(to: frames)
        batch = Batch(interval: interval, storage: storage,
            expectedFrames: UInt64(interval.contributions.reduce(0) { $0 + $1.frames }))
        observeStorage()
    }

    package func addProcessedPacket(_ packet: PerAppTimelinePacket, samples: UnsafeBufferPointer<Float>,
                                    performance: PacketPerformanceContext?, processingCompleted: PerformanceTick?) throws {
        lastWork = nil
        guard packet.frameCount <= storagePolicy.maximumPacketFrames else {
            statistics.capacityFailures += 1
            throw ProducerCompletionFault(reason: "processed contribution exceeds the packet frame limit")
        }
        guard var current = batch,
              packet.deviceObjectID == current.interval.device,
              packet.channelCount == current.interval.channels,
              packet.channelLayout == current.interval.layout,
              packet.sampleRate == current.interval.rate,
              packet.frameCount > 0, samples.count == packet.frameCount * packet.channelCount,
              packet.startSampleTime >= current.interval.start,
              !packet.startSampleTime.addingReportingOverflow(Int64(packet.frameCount)).overflow,
              packet.startSampleTime + Int64(packet.frameCount) <= current.interval.end else {
            statistics.invalidPackets += 1
            throw ProducerCompletionFault(reason: "processed contribution does not belong to the completed interval")
        }
        let started = performance.map { _ in PerformanceClock.now() }
        if current.trace?.capture.isStopped == true { current.trace = nil }
        if current.trace == nil, let performance {
            current.trace = MixPerformanceTrace(capture: performance.capture, identity: performance.identity,
                untracedUntil: current.interval.start, lastPolicyTick: performance.policyTick ?? performance.received)
        }
        let intervalEnd = current.interval.end
        current.trace?.add(performance, processed: processingCompleted, start: packet.startSampleTime,
            end: packet.startSampleTime + Int64(packet.frameCount), existingEnd: intervalEnd)
        let wrappedBefore = current.storage.wrappedWrites
        current.storage.add(samples, sourceFrameOffset: 0, frameCount: packet.frameCount,
            at: Int(packet.startSampleTime - current.interval.start), mode: packet.playbackMode)
        statistics.wrappedWrites += current.storage.wrappedWrites - wrappedBefore
        statistics.insertedFrames += UInt64(packet.frameCount)
        current.insertedFrames += UInt64(packet.frameCount)
        batch = current
        observeStorage()
        if let started {
            lastWork = .init(placementMilliseconds: PerformanceClock.milliseconds(started, PerformanceClock.now()),
                materializationMilliseconds: 0, growthMilliseconds: 0, insertedFrames: packet.frameCount,
                emittedFrames: 0, prependedFrames: 0, pendingBefore: current.storage.frameCount,
                pendingAfter: current.storage.frameCount, capacityFrames: current.storage.capacityFrames,
                wrappedRead: false, wrappedWrite: current.storage.wrappedWrites > wrappedBefore, policyMilliseconds: nil)
        }
    }

    package func finishCompletedInterval(_ interval: ProducerCompletedInterval) throws -> PCMFrame {
        guard let current = batch, current.interval.device == interval.device,
              current.interval.epoch == interval.epoch,
              current.interval.start == interval.start, current.interval.end == interval.end,
              current.insertedFrames == current.expectedFrames else {
            batch = nil
            devices.removeValue(forKey: interval.device)
            throw ProducerCompletionFault(reason: "producer interval was interrupted or a contribution failed")
        }
        var trace = current.trace
        if trace?.capture.isStopped == true { trace = nil }
        let intervalTrace = trace?.emit(start: interval.start, count: current.storage.frameCount,
            eligible: PerformanceClock.now(), deadline: nil, flushStarted: nil)
        let wrappedBefore = current.storage.wrappedReads
        let materialized = current.storage.materializePrefix(current.storage.frameCount)
        statistics.wrappedReads += current.storage.wrappedReads - wrappedBefore
        var output = PCMFrame(interleaved: materialized.combined, channelCount: interval.channels,
            sampleRate: interval.rate, channelLayout: interval.layout)
        output.playbackModeSamples = materialized.modes
        output.performanceTrace = intervalTrace
        output.performanceTrace?.emitted = PerformanceClock.now()
        current.storage.discardPrefix(current.storage.frameCount)
        batch = nil
        observeStorage()
        return output
    }

    private func observeStorage() {
        let frames = batch?.storage.frameCount ?? 0
        let milliseconds = batch.map { Double(frames) * 1000 / $0.interval.rate } ?? 0
        let capacity = devices.values.reduce(0) { $0 + $1.samples.capacityFrames }
        let bytes = devices.values.reduce(0) { $0 + $1.samples.allocatedBytes }
        statistics.activeDeviceTimelines = devices.count
        statistics.currentPendingFrames = frames
        statistics.peakPendingFrames = max(statistics.peakPendingFrames, frames)
        statistics.currentPendingMilliseconds = milliseconds
        statistics.peakPendingMilliseconds = max(statistics.peakPendingMilliseconds, milliseconds)
        statistics.currentStorageCapacityFrames = capacity
        statistics.peakStorageCapacityFrames = max(statistics.peakStorageCapacityFrames, capacity)
        statistics.storageBytes = bytes
        statistics.peakStorageBytes = max(statistics.peakStorageBytes, bytes)
        statistics.allocatedBuses = devices.values.reduce(0) { $0 + $1.samples.allocatedBusCount }
    }
}
