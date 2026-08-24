import AppKit

@MainActor
enum UIRenderPerformance {
    private static var monitoringStarted = false
    private static var liveScrollDepth = 0
    private static var observers: [NSObjectProtocol] = []

    static func startMonitoring() {
        guard !monitoringStarted else { return }
        monitoringStarted = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in liveScrollDepth += 1 }
            },
            center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in liveScrollDepth = max(0, liveScrollDepth - 1) }
            }
        ]
    }

    static var isLiveResizing: Bool {
        guard let application = NSApp else { return false }
        return application.windows.contains(where: \.inLiveResize)
    }

    static var isInteractionInProgress: Bool {
        isLiveResizing || liveScrollDepth > 0
    }

    static func allowsSpectrumPublication(
        since previousPublication: Date,
        now: Date = Date()
    ) -> Bool {
        // Keep the analyzer alive during scrolling. FFT production is already
        // capped at 20 fps off the main actor; this guard only coalesces an
        // accidental duplicate publication instead of freezing live visuals.
        let minimumInterval = 1.0 / 30.0
        return now.timeIntervalSince(previousPublication) >= minimumInterval
    }

    static var meterPollMilliseconds: Int {
        // Eight updates per second leave enough time for AppKit's live-scroll
        // work while view animations interpolate between samples.
        isInteractionInProgress ? 125 : 100
    }

    static var animatedLevelTransitionDuration: Double {
        isInteractionInProgress ? 0.125 : 0.10
    }
}
