import CamiTuneDomain
import Foundation

package enum TimelineBoundaryReason: String, Sendable, Codable { case initial, format, restart, discontinuity }

package struct TimelineTransportReadObservation: Sendable, Codable, Equatable {
    package init(sampledAt: PerformanceTick, transportGeneration: UInt64, valid: Bool, readPacket: UInt64, reservedWritePacket: UInt64, readFrame: UInt64, reservedWriteFrame: UInt64) {
        self.sampledAt = sampledAt
        self.transportGeneration = transportGeneration
        self.valid = valid
        self.readPacket = readPacket
        self.reservedWritePacket = reservedWritePacket
        self.readFrame = readFrame
        self.reservedWriteFrame = reservedWriteFrame
    }

    package let sampledAt: PerformanceTick
    package let transportGeneration: UInt64
    package let valid: Bool
    package let readPacket: UInt64
    package let reservedWritePacket: UInt64
    package let readFrame: UInt64
    package let reservedWriteFrame: UInt64
    package var outstandingReservations: UInt64 { reservedWritePacket &- readPacket }
    package var reservedFrames: UInt64 { reservedWriteFrame &- readFrame }
}

package struct TimelinePolicyTraceEvent: Sendable, Codable {
    package init(kind: Kind, tick: PerformanceTick, evidence: TimelineReorderEvidence? = nil, deviceObjectID: UInt32? = nil, epoch: UInt64? = nil, boundaryReason: TimelineBoundaryReason? = nil, transportRead: TimelineTransportReadObservation? = nil) {
        self.kind = kind
        self.tick = tick
        self.evidence = evidence
        self.deviceObjectID = deviceObjectID
        self.epoch = epoch
        self.boundaryReason = boundaryReason
        self.transportRead = transportRead
    }

    package enum Kind: String, Sendable, Codable { case packet, idleWake, reset, boundary }
    package let kind: Kind
    package let tick: PerformanceTick
    package var evidence: TimelineReorderEvidence? = nil
    package var deviceObjectID: UInt32? = nil
    package var epoch: UInt64? = nil
    package var boundaryReason: TimelineBoundaryReason? = nil
    package var transportRead: TimelineTransportReadObservation? = nil
}

package struct TimelinePolicyTraceDocument: Sendable, Codable {
    package init(version: Int, configuration: TimelineReorderPolicyConfiguration, events: [TimelinePolicyTraceEvent], droppedEvents: UInt64, statistics: PerAppTimelineMixerStatistics) {
        self.version = version
        self.configuration = configuration
        self.events = events
        self.droppedEvents = droppedEvents
        self.statistics = statistics
    }

    package let version: Int
    package let configuration: TimelineReorderPolicyConfiguration
    package let events: [TimelinePolicyTraceEvent]
    package let droppedEvents: UInt64
    package let statistics: PerAppTimelineMixerStatistics

    /// Re-evaluates original arrivals and timer wakes without PCM or sleeping.

}

package final class TimelinePolicyTrace {
    private var events: [TimelinePolicyTraceEvent] = []
    package private(set) var droppedEvents: UInt64 = 0
    private let capacity: Int
    package init(capacity: Int = 100_000) {
        self.capacity = max(0, capacity); events.reserveCapacity(self.capacity)
    }

    package func append(_ event: TimelinePolicyTraceEvent) {
        guard events.count < capacity else { droppedEvents &+= 1; return }
        events.append(event)
    }
    package func document(configuration: TimelineReorderPolicyConfiguration, statistics: PerAppTimelineMixerStatistics) -> TimelinePolicyTraceDocument {
        .init(version: 1, configuration: configuration, events: events, droppedEvents: droppedEvents, statistics: statistics)
    }

}
