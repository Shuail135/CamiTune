import CamiTuneAudio
import CamiTuneDomain
import Foundation

struct AudioCaptureClient: Hashable, Sendable {
    var deviceObjectID: UInt32 = 0
    var clientID: UInt32
    var processID: Int32
    var bundleID: String?
    var isActive: Bool
    var generation: UInt64

    var transportKey: PerAppTransportClientKey {
        PerAppTransportClientKey(deviceObjectID: deviceObjectID, clientID: clientID)
    }

    var applicationKey: String {
        if let bundleID = PerAppClientRegistry.canonicalApplicationBundleID(bundleID) {
            return bundleID
        }
        return "pid:\(processID)"
    }
}

final class AudioCaptureDelivery: Sendable {
    private let router: PCMRouter
    private let applications: PerAppAudioController

    init(router: PCMRouter, applications: PerAppAudioController) {
        self.router = router
        self.applications = applications
    }

    var performanceSource: PerformanceTraceSource { router.performanceSource }
    var statistics: PCMRouter.Statistics { router.statistics }

    func updateClients(_ clients: [AudioCaptureClient]) { applications.updateClients(clients) }

    func consume(_ interval: ProducerCompletedInterval) throws {
        if let clock = interval.clock { router.observeSourceClock(clock) }
        if interval.end > interval.start {
            router.route(try applications.ingestCompletedInterval(interval))
        }
        if interval.terminal { router.finishProducerEpoch() }
    }

    func stop() {
        router.stop()
        applications.resetRuntime()
    }
}
