import AppKit
import os.signpost

@MainActor
enum UIRenderPerformance {
    nonisolated private static let log = OSLog(subsystem: "CamiTune", category: "UI Performance")

    static func recordProfilePresentation() {
        os_signpost(.event, log: log, name: "Profile Presentation")
    }

    nonisolated static func recordAppPublication() {
        os_signpost(.event, log: log, name: "App Audio Publication")
    }
    nonisolated static func recordAppPresentationMutation() {
        os_signpost(.event, log: log, name: "App Presentation Mutation")
    }
    static func recordVisualDemand() {
        os_signpost(.event, log: log, name: "Visual Demand Changed")
    }
    static func beginEQApply() { os_signpost(.begin, log: log, name: "EQ Apply") }
    static func endEQApply() { os_signpost(.end, log: log, name: "EQ Apply") }
    static func beginSpeakerDrag() { os_signpost(.begin, log: log, name: "Speaker Drag") }
    static func endSpeakerDrag() { os_signpost(.end, log: log, name: "Speaker Drag") }
    static func recordSpeakerSave() { os_signpost(.event, log: log, name: "Speaker Save") }

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
                Task { @MainActor in
                    if liveScrollDepth == 0 {
                        os_signpost(.begin, log: log, name: "Live Scroll")
                    }
                    liveScrollDepth += 1
                }
            },
            center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    guard liveScrollDepth > 0 else { return }
                    liveScrollDepth -= 1
                    if liveScrollDepth == 0 {
                        os_signpost(.end, log: log, name: "Live Scroll")
                    }
                }
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
