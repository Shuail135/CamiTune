import CamiTuneDomain
import Foundation

package struct PerAppAudioIngestResult: Sendable {
    package init(frame: PCMFrame? = nil, nextTimelineWakeAfter: TimeInterval? = nil) {
        self.frame = frame
        self.nextTimelineWakeAfter = nextTimelineWakeAfter
    }

    package let frame: PCMFrame?
    package let nextTimelineWakeAfter: TimeInterval?
}

package enum PerAppMixFlushResult: Sendable {
    case idle
    case retryAfter(TimeInterval)
    case flushed(PCMFrame)
}
