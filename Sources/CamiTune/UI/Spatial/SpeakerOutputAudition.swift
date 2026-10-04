import CamiTuneAudio
import CamiTuneDomain
import AudioToolbox
import Combine
import Foundation

/// A short identification signal addressed directly to one physical channel.
/// This queue neither changes the default output nor creates/activates a profile.
@MainActor
final class SpeakerOutputAudition: ObservableObject {
    @Published private(set) var output: PhysicalOutputID?
    @Published private(set) var preparing = false
    @Published private(set) var message: String?
    private var queue: AudioQueueRef?
    private var task: Task<Void, Never>?
    private var request = UUID()

    func toggle(_ output: PhysicalOutputID, topology: SpeakerTopology, audio: CoreAudioService,
                profile: DeviceProfile? = nil, subwooferTestGainDB: Double = 0) {
        if self.output == output { stop(); return }
        stop()
        let token = UUID(); request = token
        self.output = output; preparing = true; message = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let device = await audio.resolveDeviceWithoutBlockingUI(uid: output.deviceUID), !device.isRoutingDevice else {
                    throw ProfileSettingsError.runtime("Connect this physical output before testing it.")
                }
                let hardware = try await audio.probeSpeakerTopology(uid: device.id)
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try topology.validateHardware(hardware)
                    var testTopology = topology
                    testTopology.sampleRate = hardware.sampleRate
                    // Identification includes disabled/unconfigured physical channels.
                    guard let index = testTopology.endpoints.firstIndex(where: { $0.id == output }) else {
                        throw SpeakerTopologyError.invalidDeviceUID
                    }
                    testTopology.endpoints[index].connectionState = .confirmedByUser
                    guard let clip = SpatialCalibrationClip(physicalOutput: output, topology: testTopology,
                        subwooferTestGainDB: subwooferTestGainDB) else {
                        throw ProfileSettingsError.runtime("This output could not prepare an identification signal.")
                    }
                    var samples = Self.monoSamples(clip, output: output.channelIndex)
                    if [.woofer, .midrange, .tweeter].contains(testTopology.endpoints[index].function) {
                        guard var candidate = profile else { throw ProfileSettingsError.runtime("Active driver tests require a protected speaker profile.") }
                        candidate.speakerTopology = testTopology; candidate.sampleRate = Int(hardware.sampleRate)
                        try candidate.validateMultichannelHardware(hardware)
                        samples = try SpeakerAuditionProtection.samples(samples, output: output, profile: candidate)
                    }
                    let interleaved = try Self.interleavedSamples(samples, output: output.channelIndex,
                        channelCount: clip.channelCount)
                    return (clip, interleaved)
                }.value
                guard request == token, !Task.isCancelled else { return }
                try start(clip: prepared.0, samples: prepared.1, output: output)
                preparing = false
                // Drain only this test, then release the queue. Poll on the main
                // actor; the audio callback itself does no allocation or UI work.
                let deadline = Date().addingTimeInterval(4)
                var observedRunning = false
                try await Task.sleep(for: .milliseconds(50))
                while request == token && !Task.isCancelled {
                    guard let queue else { return }
                    var running: UInt32 = 0
                    var size = UInt32(MemoryLayout<UInt32>.size)
                    try check(AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size))
                    if running != 0 { observedRunning = true }
                    if running == 0 && observedRunning { stop(); return }
                    if Date() >= deadline {
                        let failedToStart = !observedRunning
                        stop()
                        if failedToStart { message = "The selected output did not start the test. Check its connection and volume." }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch is CancellationError { }
            catch {
                guard request == token else { return }
                stop(); message = error.localizedDescription
            }
        }
    }

    private func start(clip: SpatialCalibrationClip, samples: [Float], output: PhysicalOutputID) throws {
        let channels = UInt32(clip.channelCount)
        let frameBytes = channels * UInt32(MemoryLayout<Float>.size)
        var format = AudioStreamBasicDescription(mSampleRate: clip.sampleRate,
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: frameBytes, mFramesPerPacket: 1, mBytesPerFrame: frameBytes,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var created: AudioQueueRef?
        try check(AudioQueueNewOutput(&format, speakerAuditionBufferCompleted, nil, nil, nil, 0, &created))
        guard let created else { throw ProfileSettingsError.runtime("The test audio queue could not be created.") }
        queue = created
        let uid = output.deviceUID as CFString
        try withExtendedLifetime(uid) {
            var reference = Unmanaged.passUnretained(uid)
            try check(AudioQueueSetProperty(created, kAudioQueueProperty_CurrentDevice, &reference,
                                            UInt32(MemoryLayout<Unmanaged<CFString>>.size)))
            // Supply every physical channel, including explicit silence, instead
            // of relying on a one-channel stream's mapping to a wider device.
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | channels
            try check(AudioQueueSetProperty(created, kAudioQueueProperty_ChannelLayout, &layout,
                                            UInt32(MemoryLayout<AudioChannelLayout>.size)))
            let assignments = (1...channels).map {
                AudioQueueChannelAssignment(mDeviceUID: reference, mChannelNumber: $0)
            }
            try assignments.withUnsafeBufferPointer { buffer in
                try check(AudioQueueSetProperty(created, kAudioQueueProperty_ChannelAssignments, buffer.baseAddress!,
                                                UInt32(buffer.count * MemoryLayout<AudioQueueChannelAssignment>.stride)))
            }
        }
        var buffer: AudioQueueBufferRef?
        try check(AudioQueueAllocateBuffer(created, UInt32(samples.count * MemoryLayout<Float>.size), &buffer))
        guard let buffer else { throw ProfileSettingsError.runtime("The test audio buffer could not be created.") }
        samples.withUnsafeBytes { bytes in
            buffer.pointee.mAudioData.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            buffer.pointee.mAudioDataByteSize = UInt32(bytes.count)
        }
        try check(AudioQueueEnqueueBuffer(created, buffer, 0, nil))
        try check(AudioQueueStart(created, nil))
        try check(AudioQueueStop(created, false))
    }

    nonisolated static func monoSamples(_ clip: SpatialCalibrationClip, output: Int) -> [Float] {
        guard (0..<clip.channelCount).contains(output) else { return [] }
        return stride(from: output, to: clip.samples.count, by: clip.channelCount).map { clip.samples[$0] }
    }

    /// Preserve the already protected mono signal and explicitly silence every
    /// other hardware output. This is the buffer passed directly to AudioQueue.
    nonisolated static func interleavedSamples(_ mono: [Float], output: Int, channelCount: Int) throws -> [Float] {
        guard (1...SpeakerTopology.maximumOutputChannels).contains(channelCount),
              (0..<channelCount).contains(output), !mono.isEmpty else {
            throw SpeakerTopologyError.invalidChannelIndex(output)
        }
        var result = [Float](repeating: 0, count: mono.count * channelCount)
        for frame in mono.indices { result[frame * channelCount + output] = mono[frame] }
        return result
    }

    func stop() {
        request = UUID(); task?.cancel(); task = nil
        if let queue { AudioQueueStop(queue, true); AudioQueueDispose(queue, true) }
        queue = nil; output = nil; preparing = false
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw ProfileSettingsError.runtime("The selected output could not play the test (Core Audio \(status)).")
        }
    }
}

// AudioQueue invokes this on its own thread. A file-level callback cannot inherit
// MainActor isolation from SpeakerOutputAudition.start().
private func speakerAuditionBufferCompleted(_ context: UnsafeMutableRawPointer?, _ queue: AudioQueueRef, _ buffer: AudioQueueBufferRef) {}
