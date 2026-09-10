import AudioToolbox
import CoreAudio
import Foundation

/// HAL reads only. Invoke on a worker, never from a SwiftUI body/audio callback.
struct SpeakerTopologyProbe {
    enum ProbeError: LocalizedError {
        case routingDevice, property(OSStatus), malformedProperty
        var errorDescription: String? {
            switch self {
            case .routingDevice: return "Select a physical output device."
            case .property(let status): return "Could not read the output device (Core Audio \(status))."
            case .malformedProperty: return "The output device returned an invalid channel description."
            }
        }
    }

    func probe(_ device: AudioDeviceInfo) throws -> SpeakerTopology {
        guard !device.isRoutingDevice else { throw ProbeError.routingDevice }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = AudioObjectGetPropertyData(device.objectID, &uidAddress, 0, nil, &uidSize, &uid)
        guard uidStatus == noErr else { throw ProbeError.property(uidStatus) }
        guard let uid, uid.takeUnretainedValue() as String == device.id else { throw SpeakerTopologyError.invalidDeviceUID }
        let data = try property(device.objectID, selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        let count: Int = try data.withUnsafeBytes { bytes in
            let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
            guard bytes.count >= offset else { throw ProbeError.malformedProperty }
            let bufferCount = Int(bytes.loadUnaligned(as: UInt32.self))
            guard bufferCount <= (bytes.count - offset) / MemoryLayout<AudioBuffer>.stride else { throw ProbeError.malformedProperty }
            var count = 0
            for i in 0..<bufferCount {
                count += Int(bytes.loadUnaligned(fromByteOffset: offset + i * MemoryLayout<AudioBuffer>.stride, as: AudioBuffer.self).mNumberChannels)
            }
            return count
        }
        let rateData = try property(device.objectID, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
        guard rateData.count == MemoryLayout<Double>.size else { throw ProbeError.malformedProperty }
        let rate = rateData.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        let layout = try? property(device.objectID, selector: kAudioDevicePropertyPreferredChannelLayout, scope: kAudioDevicePropertyScopeOutput)
        let channels = layout.flatMap { try? Self.descriptions(data: $0, channelCount: count) } ?? []
        return try SpeakerTopologyResolver().resolve(deviceUID: device.id, sampleRate: rate,
                                                     channelCount: count, channels: channels)
    }

    /// Bounded parsing also used by deterministic HAL-description tests.
    static func descriptions(data: Data, channelCount: Int) throws -> [SpeakerChannelDescription] {
        guard (1...32).contains(channelCount) else { throw ProbeError.malformedProperty }
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        guard data.count >= offset else { throw ProbeError.malformedProperty }
        let tag = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if tag != kAudioChannelLayoutTag_UseChannelDescriptions {
            if tag == kAudioChannelLayoutTag_UseChannelBitmap {
                var bitmap = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
                var size: UInt32 = 0
                let inputSize = UInt32(MemoryLayout<UInt32>.size)
                guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForBitmap, inputSize, &bitmap, &size) == noErr,
                      size >= offset, size <= 65536 else { throw ProbeError.malformedProperty }
                var expanded = Data(count: Int(size))
                let status = expanded.withUnsafeMutableBytes {
                    AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForBitmap, inputSize, &bitmap, &size, $0.baseAddress!)
                }
                guard status == noErr, expanded.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) == kAudioChannelLayoutTag_UseChannelDescriptions else { throw ProbeError.malformedProperty }
                return try descriptions(data: expanded, channelCount: channelCount)
            }
            guard let layout = LPCMChannelLayout(coreAudioTag: tag, channelCount: channelCount) else { return [] }
            return layout.roles.map { SpeakerChannelDescription(role: $0) }
        }
        let count = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
        guard count == channelCount, count <= (data.count - offset) / MemoryLayout<AudioChannelDescription>.stride else { throw ProbeError.malformedProperty }
        return data.withUnsafeBytes { bytes in
            (0..<count).map { SpeakerChannelDescription(bytes.loadUnaligned(fromByteOffset: offset + $0 * MemoryLayout<AudioChannelDescription>.stride, as: AudioChannelDescription.self)) }
        }
    }

    private func property(_ device: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) throws -> Data {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr else { throw ProbeError.property(status) }
        guard size > 0, size <= 65536 else { throw ProbeError.malformedProperty }
        var data = Data(count: Int(size))
        status = data.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw ProbeError.property(status) }
        guard size <= data.count else { throw ProbeError.malformedProperty }
        data.count = Int(size)
        return data
    }
}
