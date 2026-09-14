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

    func toggle(_ output: PhysicalOutputID, topology: SpeakerTopology, audio: CoreAudioManager) {
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
                let clip = try await Task.detached(priority: .userInitiated) {
                    let hardware = try SpeakerTopologyProbe().probe(device)
                    try topology.validateHardware(hardware)
                    var testTopology = topology
                    testTopology.sampleRate = hardware.sampleRate
                    // Identification includes disabled/unconfigured physical channels.
                    guard let index = testTopology.endpoints.firstIndex(where: { $0.id == output }) else {
                        throw SpeakerTopologyError.invalidDeviceUID
                    }
                    testTopology.endpoints[index].connectionState = .confirmedByUser
                    guard let clip = SpatialCalibrationClip(physicalOutput: output, topology: testTopology) else {
                        throw ProfileSettingsError.runtime("This output could not prepare an identification signal.")
                    }
                    return clip
                }.value
                guard request == token, !Task.isCancelled else { return }
                try start(clip: clip, output: output)
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

    private func start(clip: SpatialCalibrationClip, output: PhysicalOutputID) throws {
        var format = AudioStreamBasicDescription(mSampleRate: clip.sampleRate,
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var created: AudioQueueRef?
        try check(AudioQueueNewOutput(&format, speakerAuditionBufferCompleted, nil, nil, nil, 0, &created))
        guard let created else { throw ProfileSettingsError.runtime("The test audio queue could not be created.") }
        queue = created
        let uid = output.deviceUID as CFString
        try withExtendedLifetime(uid) {
            var reference = Unmanaged.passUnretained(uid)
            try check(AudioQueueSetProperty(created, kAudioQueueProperty_CurrentDevice, &reference,
                                            UInt32(MemoryLayout<Unmanaged<CFString>>.size)))
            var assignment = AudioQueueChannelAssignment(mDeviceUID: reference, mChannelNumber: UInt32(output.channelIndex + 1))
            try check(AudioQueueSetProperty(created, kAudioQueueProperty_ChannelAssignments, &assignment,
                                            UInt32(MemoryLayout<AudioQueueChannelAssignment>.size)))
        }
        let samples = Self.monoSamples(clip, output: output.channelIndex)
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
