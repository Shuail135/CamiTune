import Foundation

/// Presentation values only: UIDs are identity; HAL object IDs never escape here.
struct CoreAudioOutputSnapshot: Identifiable, Equatable, Sendable {
    let uid: String
    let name: String
    let isRoutingDevice: Bool
    var id: String { uid }
    init(_ device: AudioDeviceInfo) {
        uid = device.id; name = device.name; isRoutingDevice = device.isRoutingDevice
    }
}

struct CoreAudioRateCapabilities: Equatable, Sendable {
    let currentRate: Double?
    let ranges: [ClosedRange<Double>]
    let isSettable: Bool
    func supports(_ rate: Double) -> Bool {
        guard rate.isFinite, rate > 0 else { return false }
        return currentRate.map { abs($0 - rate) < 0.5 } == true
            || (isSettable && ranges.contains { $0.contains(rate) })
    }
}

struct CoreAudioSnapshot: Equatable, Sendable {
    var revision: UInt64 = 0
    var outputs: [CoreAudioOutputSnapshot] = []
    var defaultOutputUID: String?
    var hasCompletedInitialRefresh = false
    var observedAt = Date()
    var rateCapabilities: [String: CoreAudioRateCapabilities] = [:]
}

/// MainActor publication only. No HAL operations, listeners, or service reference.
@MainActor
final class CoreAudioSnapshotStore: ObservableObject {
    @Published private(set) var diagnostics = "No readiness operations recorded"
    func publishDiagnostics(_ text: String) { diagnostics = text }
    @Published private(set) var snapshot = CoreAudioSnapshot()
    var outputDevices: [CoreAudioOutputSnapshot] { snapshot.outputs }
    var physicalOutputDevices: [CoreAudioOutputSnapshot] { snapshot.outputs.filter { !$0.isRoutingDevice } }
    var defaultOutputUID: String? { snapshot.defaultOutputUID }
    var hasCompletedInitialRefresh: Bool { snapshot.hasCompletedInitialRefresh }
    func cachedDevice(uid: String) -> CoreAudioOutputSnapshot? { snapshot.outputs.first { $0.uid == uid } }
    func cachedSampleRateSupport(uid: String, rate: Double) -> Bool? { snapshot.rateCapabilities[uid]?.supports(rate) }
    func publish(outputs: [CoreAudioOutputSnapshot], defaultUID: String?) {
        var next = snapshot
        next.outputs = outputs; next.defaultOutputUID = defaultUID; next.hasCompletedInitialRefresh = true
        publish(next)
    }
    func publishDefault(_ uid: String?) {
        var next = snapshot; next.defaultOutputUID = uid; publish(next)
    }
    func publishRates(_ rates: [String: CoreAudioRateCapabilities]) {
        var next = snapshot; next.rateCapabilities = rates; publish(next)
    }
    private func publish(_ value: CoreAudioSnapshot) {
        var next = value; next.revision &+= 1; next.observedAt = Date(); snapshot = next
    }
}
