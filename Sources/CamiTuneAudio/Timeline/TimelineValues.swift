import CamiTuneDomain
import Foundation

package struct PerAppTimelinePacket: Sendable {
    package init(deviceObjectID: UInt32, cycleCounter: UInt64, startSampleTime: Int64, frameCount: Int, channelCount: Int, sampleRate: Double, channelLayout: LPCMChannelLayout, playbackMode: PlaybackMode) {
        self.deviceObjectID = deviceObjectID
        self.cycleCounter = cycleCounter
        self.startSampleTime = startSampleTime
        self.frameCount = frameCount
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
        self.playbackMode = playbackMode
    }

    package let deviceObjectID: UInt32
    package let cycleCounter: UInt64
    package let startSampleTime: Int64
    package let frameCount: Int
    package let channelCount: Int
    package let sampleRate: Double
    package let channelLayout: LPCMChannelLayout
    package let playbackMode: PlaybackMode
}

package struct TimelinePacketPreparation: Sendable {
    package init(packet: PerAppTimelinePacket, streamEpoch: UInt64, requiresClientDSPReset: Bool, isValid: Bool = true, boundaryReason: TimelineBoundaryReason? = nil) {
        self.packet = packet
        self.streamEpoch = streamEpoch
        self.requiresClientDSPReset = requiresClientDSPReset
        self.isValid = isValid
        self.boundaryReason = boundaryReason
    }

    package let packet: PerAppTimelinePacket
    package let streamEpoch: UInt64
    package let requiresClientDSPReset: Bool
    package var isValid: Bool = true
    package var boundaryReason: TimelineBoundaryReason? = nil
}

package struct PerAppTimelineMixerStatistics: Sendable, Codable {
    package init(reorder: TimelineReorderCounters = TimelineReorderCounters(), policySnapshots: [TimelineReorderPolicySnapshot]? = nil, insertedFrames: UInt64 = 0, fullyStalePackets: UInt64 = 0, partiallyLatePackets: UInt64 = 0, timelineRestarts: UInt64 = 0, formatBoundaries: UInt64 = 0, discontinuityFlushes: UInt64 = 0, prependFrames: UInt64 = 0, gapFrames: UInt64 = 0, prependCopiedFrames: UInt64 = 0, retainedSuffixShiftFrames: UInt64 = 0, packetFrontShiftSamples: UInt64 = 0, currentPendingFrames: Int = 0, peakPendingFrames: Int = 0, currentPendingMilliseconds: Double = 0.0, peakPendingMilliseconds: Double = 0.0, currentStorageCapacityFrames: Int = 0, peakStorageCapacityFrames: Int = 0, storageBytes: Int = 0, peakStorageBytes: Int = 0, allocatedBuses: Int = 0, activeDeviceTimelines: Int = 0, latestStreamEpoch: UInt64 = 0, storageReallocations: UInt64 = 0, storageGrowthCopiedFrames: UInt64 = 0, capacityFailures: UInt64 = 0, invalidPackets: UInt64 = 0, wrappedReads: UInt64 = 0, wrappedWrites: UInt64 = 0) {
        self.reorder = reorder
        self.policySnapshots = policySnapshots
        self.insertedFrames = insertedFrames
        self.fullyStalePackets = fullyStalePackets
        self.partiallyLatePackets = partiallyLatePackets
        self.timelineRestarts = timelineRestarts
        self.formatBoundaries = formatBoundaries
        self.discontinuityFlushes = discontinuityFlushes
        self.prependFrames = prependFrames
        self.gapFrames = gapFrames
        self.prependCopiedFrames = prependCopiedFrames
        self.retainedSuffixShiftFrames = retainedSuffixShiftFrames
        self.packetFrontShiftSamples = packetFrontShiftSamples
        self.currentPendingFrames = currentPendingFrames
        self.peakPendingFrames = peakPendingFrames
        self.currentPendingMilliseconds = currentPendingMilliseconds
        self.peakPendingMilliseconds = peakPendingMilliseconds
        self.currentStorageCapacityFrames = currentStorageCapacityFrames
        self.peakStorageCapacityFrames = peakStorageCapacityFrames
        self.storageBytes = storageBytes
        self.peakStorageBytes = peakStorageBytes
        self.allocatedBuses = allocatedBuses
        self.activeDeviceTimelines = activeDeviceTimelines
        self.latestStreamEpoch = latestStreamEpoch
        self.storageReallocations = storageReallocations
        self.storageGrowthCopiedFrames = storageGrowthCopiedFrames
        self.capacityFailures = capacityFailures
        self.invalidPackets = invalidPackets
        self.wrappedReads = wrappedReads
        self.wrappedWrites = wrappedWrites
    }

    package var reorder = TimelineReorderCounters()
    package var policySnapshots: [TimelineReorderPolicySnapshot]? = nil
    package var insertedFrames: UInt64 = 0
    package var fullyStalePackets: UInt64 = 0
    package var partiallyLatePackets: UInt64 = 0
    package var timelineRestarts: UInt64 = 0
    package var formatBoundaries: UInt64 = 0
    package var discontinuityFlushes: UInt64 = 0
    package var prependFrames: UInt64 = 0
    package var gapFrames: UInt64 = 0
    package var prependCopiedFrames: UInt64 = 0
    package var retainedSuffixShiftFrames: UInt64 = 0
    package var packetFrontShiftSamples: UInt64 = 0
    package var currentPendingFrames = 0
    package var peakPendingFrames = 0
    package var currentPendingMilliseconds = 0.0
    package var peakPendingMilliseconds = 0.0
    package var currentStorageCapacityFrames = 0
    package var peakStorageCapacityFrames = 0
    package var storageBytes = 0
    package var peakStorageBytes = 0
    package var allocatedBuses = 0
    package var activeDeviceTimelines = 0
    package var latestStreamEpoch: UInt64 = 0
    package var storageReallocations: UInt64 = 0
    package var storageGrowthCopiedFrames: UInt64 = 0
    package var capacityFailures: UInt64 = 0
    package var invalidPackets: UInt64 = 0
    package var wrappedReads: UInt64 = 0
    package var wrappedWrites: UInt64 = 0

    package var policySummary: String {
        reorder.summary + "\n\n" + (policySnapshots ?? []).map(\.summary).joined(separator: "\n\n")
    }

    package var summary: String {
        """
        Active device timelines: \(activeDeviceTimelines); latest epoch: \(latestStreamEpoch)
        Pending: \(currentPendingFrames) frames / \(String(format: "%.2f", currentPendingMilliseconds)) ms (peak \(peakPendingFrames) frames)
        Storage capacity: \(currentStorageCapacityFrames) frames (peak \(peakStorageCapacityFrames)); buses: \(allocatedBuses)
        Storage bytes: \(storageBytes) (peak \(peakStorageBytes)); capacity is memory, not buffered latency
        Stale: \(fullyStalePackets); partially late: \(partiallyLatePackets); restarts: \(timelineRestarts)
        Format boundaries: \(formatBoundaries); discontinuities: \(discontinuityFlushes)
        Prepend: \(prependFrames) frames; gaps: \(gapFrames) frames
        Reallocations: \(storageReallocations); growth copies: \(storageGrowthCopiedFrames) bus-frames
        Retained suffix shifts: \(retainedSuffixShiftFrames); prepend copies: \(prependCopiedFrames); input shifts: \(packetFrontShiftSamples)
        Wrapped reads/writes: \(wrappedReads)/\(wrappedWrites)
        Capacity failures: \(capacityFailures); invalid packets: \(invalidPackets)
        """
    }
}
