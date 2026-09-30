import Foundation
import CoreAudio

/// Internal I/O adapter. It never chooses a profile or owns runtime transitions.
struct CoreAudioHALBackend: Sendable {
    var enumerateOutputs: @Sendable () -> [AudioDeviceInfo]
    var resolve: @Sendable (String) -> AudioDeviceInfo?
    var readDefaultOutput: @Sendable () -> String?
    var readRateCapabilities: @Sendable (AudioDeviceInfo) -> CoreAudioRateCapabilities
    var subscribe: @Sendable (CoreAudioEvent, @escaping @Sendable () -> Void) -> CoreAudioListenerToken?

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

enum CoreAudioEvent: Hashable, Sendable {
    case devices, defaultOutput, nominalRate(UInt32)
    var objectID: AudioObjectID {
        if case .nominalRate(let id) = self { return id }
        return AudioObjectID(kAudioObjectSystemObject)
    }
    var address: AudioObjectPropertyAddress {
        let selector: AudioObjectPropertySelector
        switch self {
        case .devices: selector = kAudioHardwarePropertyDevices
        case .defaultOutput: selector = kAudioHardwarePropertyDefaultOutputDevice
        case .nominalRate: selector = kAudioDevicePropertyNominalSampleRate
        }
        return .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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

