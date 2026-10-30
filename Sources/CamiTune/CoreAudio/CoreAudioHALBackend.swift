import Foundation
import CoreAudio
import SystemAudioBridgeC
import CamiTuneDomain

struct CoreAudioBridgeCapabilities: Sendable {
    let transportSupported: Bool
    let profileFormatVersion: UInt32
    let sourceDeviceID: UInt32

    var supportsProfileRouting: Bool {
        transportSupported && profileFormatVersion == SABR_PROFILE_FORMAT_VERSION && sourceDeviceID != 0
    }
}

/// Internal I/O adapter. It never chooses a profile or owns runtime transitions.
struct CoreAudioHALBackend: Sendable {
    var enumerateOutputs: @Sendable () -> [AudioDeviceInfo]
    var resolve: @Sendable (String) -> AudioDeviceInfo?
    var readDefaultOutput: @Sendable () -> String?
    var readRateCapabilities: @Sendable (AudioDeviceInfo) -> CoreAudioRateCapabilities
    var subscribe: @Sendable (CoreAudioEvent, @escaping @Sendable () -> Void) -> CoreAudioListenerToken?

    var bridgeCapabilities: @Sendable (AudioDeviceInfo) -> CoreAudioBridgeCapabilities = { _ in
        .init(transportSupported: false, profileFormatVersion: 0, sourceDeviceID: 0)
    }

    var publishEndpoints: @Sendable (AudioDeviceInfo, [ProfileEndpointState]) throws -> [CoreAudioWaitResult] = { _, _ in throw CoreAudioService.AudioError.deviceNotFound("Unconfigured publisher") }
    var setDefaultOutput: @Sendable (AudioDeviceInfo) throws -> Void = { _ in throw CoreAudioService.AudioError.deviceNotFound("Unconfigured backend") }
    var readNominalRate: @Sendable (AudioDeviceInfo) -> Double? = { _ in nil }
    var setNominalRate: @Sendable (AudioDeviceInfo, Double) throws -> Void = { _, _ in throw CoreAudioService.AudioError.deviceNotFound("Unconfigured backend") }
    var schedule: @Sendable (Duration, @escaping @Sendable () -> Void) -> CoreAudioListenerToken = { delay, action in
        let task = Task { do { try await Task.sleep(for: delay); action() } catch {} }
        return CoreAudioListenerToken { task.cancel() }
    }

    static let live = Self(
        enumerateOutputs: { CoreAudioService.enumerateOutputDevices() },
        resolve: { CoreAudioService.deviceInfo(forUID: $0) },
        readDefaultOutput: { CoreAudioService.defaultOutputDevice().flatMap(CoreAudioService.deviceUID) },
        readRateCapabilities: { CoreAudioService.readSampleRateCapabilities(device: $0) },
        subscribe: { event, action in
            let queue = DispatchQueue.global(qos: .userInitiated)
            var address = event.address
            let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
            guard AudioObjectAddPropertyListenerBlock(event.objectID, &address, queue, block) == noErr else { return nil }
            return CoreAudioListenerToken {
                var address = event.address
                _ = AudioObjectRemovePropertyListenerBlock(event.objectID, &address, queue, block)
            }
        },
        bridgeCapabilities: { bridge in
            .init(transportSupported: sabr_client_transport_is_supported(bridge.objectID),
                profileFormatVersion: sabr_client_profile_format_version(bridge.objectID),
                sourceDeviceID: sabr_client_source_device_id(bridge.objectID))
        },
        publishEndpoints: { bridge, endpoints in
            let log = CoreAudioWaitLog()
            try ProfileEndpointPublication.publish(endpoints, using: NativeProfileEndpointBackend(bridgeID: bridge.objectID, waitObserver: { log.append($0) }))
            return log.values
        },
        setDefaultOutput: { device in
            var address = CoreAudioEvent.defaultOutput.address
            var id = device.objectID
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &id)
            guard status == noErr else { throw CoreAudioService.AudioError.osStatus(status) }
        },
        readNominalRate: { CoreAudioService.nominalSampleRate(deviceID: $0.objectID) },
        setNominalRate: { device, rate in
            var address = CoreAudioEvent.nominalRate(device.objectID).address
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device.objectID, &address, &settable) == noErr, settable.boolValue else {
                throw CoreAudioService.AudioError.sampleRateNotSettable(device.name)
            }
            var value = rate
            let status = AudioObjectSetPropertyData(device.objectID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
            guard status == noErr else { throw CoreAudioService.AudioError.osStatus(status) }
        })
}

extension CoreAudioHALBackend {
    /// Termination and maintenance must acknowledge the physical route before
    /// removing a selected virtual endpoint. HAL acceptance alone is not completion.
    func setDefaultOutputAndWaitSynchronously(uid: String) throws {
        if readDefaultOutput() == uid { return }
        guard let device = resolve(uid) else { throw CoreAudioService.AudioError.deviceNotFound(uid) }
        try setDefaultOutput(device)
        let result = CoreAudioConditionWaiter.waitSynchronously(backend: self, events: [.defaultOutput],
            timeout: .seconds(1), condition: { readDefaultOutput() == uid })
        if result.source == .cancelled { throw CancellationError() }
        guard result.source != .timedOut else { throw CoreAudioService.AudioError.defaultOutputDidNotApply(uid) }
    }

    func removeProfileEndpoints() throws {
        if let selected = readDefaultOutput(),
           selected == AudioDeviceInfo.systemAudioBridgeUID || ProfileRoutingDescriptor.isProfileRoutingUID(selected) {
            guard let physical = enumerateOutputs().first(where: { !$0.isRoutingDevice }) else {
                throw CoreAudioService.AudioError.deviceNotFound("An available physical output")
            }
            try setDefaultOutputAndWaitSynchronously(uid: physical.id)
        }
        // The native publisher serializes with a cancelled transaction and its
        // rollback, so that neither can recreate devices after this removal.
        if let bridge = resolve(AudioDeviceInfo.systemAudioBridgeUID) { _ = try publishEndpoints(bridge, []) }
    }
}

enum CoreAudioEvent: Hashable, Sendable {
    case devices, defaultOutput, nominalRate(UInt32), streamConfiguration(UInt32), channelLayout(UInt32)
    var objectID: AudioObjectID {
        switch self {
        case .nominalRate(let id), .streamConfiguration(let id), .channelLayout(let id): return id
        case .devices, .defaultOutput: return AudioObjectID(kAudioObjectSystemObject)
        }
    }
    var address: AudioObjectPropertyAddress {
        let selector: AudioObjectPropertySelector
        switch self {
        case .devices: selector = kAudioHardwarePropertyDevices
        case .defaultOutput: selector = kAudioHardwarePropertyDefaultOutputDevice
        case .nominalRate: selector = kAudioDevicePropertyNominalSampleRate
        case .streamConfiguration: selector = kAudioDevicePropertyStreamConfiguration
        case .channelLayout: selector = kAudioDevicePropertyPreferredChannelLayout
        }
        let scope: AudioObjectPropertyScope
        switch self {
        case .streamConfiguration, .channelLayout: scope = kAudioObjectPropertyScopeOutput
        default: scope = kAudioObjectPropertyScopeGlobal
        }
        return .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Cancellation removes one registration once; no callback executes under this lock.
final class CoreAudioListenerToken: @unchecked Sendable {
    private let lock = NSLock()
    private var removal: (@Sendable () -> Void)?
    init(_ removal: @escaping @Sendable () -> Void) { self.removal = removal }
    func cancel() {
        lock.lock(); let action = removal; removal = nil; lock.unlock()
        action?()
    }
    deinit { cancel() }
}

