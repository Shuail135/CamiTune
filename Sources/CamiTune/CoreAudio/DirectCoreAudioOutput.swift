import AudioToolbox
import CoreAudio
import CamiTuneAudio
import CamiTuneDomain
import Foundation
import Darwin

/// The hardware callback only consumes a preallocated SPSC ring. All plug-in
/// IPC, channel mapping, limiting and allocation stay on the delivery worker.
package final class DirectCoreAudioOutput: PCMOutputSink, @unchecked Sendable {
    package struct Snapshot: Sendable {
        package var peak: [Double]
        package var rms: [Double]
        package var bufferedFrames: UInt64
        package var underrunFrames: UInt64
        package var clippedSamples: UInt64
        package var callbackFrames: Int
        package var clock: AudioClockObservation?
        package var silentSeconds: Double
        package var error: String?
    }
    package let sampleRate: Double
    package let deviceID: AudioDeviceID
    package let requestedFrames: Int
    package var processingBlockFrames: Int? { requestedFrames }
    package let bufferFrames: Int
    package let inputChannels: Int
    package let outputChannels: Int
    private let storage: DirectOutputBuffer
    private let epoch = mach_absolute_time()
    private var unit: AudioUnit?
    private var stopped = false
    private let originalBufferFrames: UInt32
    private let changedDeviceBuffer: Bool
    // Sole delivery-writer ownership.
    private var finalProcessor: FinalOutputProcessor

    package init(deviceID: AudioDeviceID, sampleRate: Double, inputChannels: Int,
                 outputChannels: Int, channelMap: [Int], requestedFrames: Int) throws {
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate),
              (1...32).contains(inputChannels), (1...32).contains(outputChannels),
              channelMap.count == inputChannels, Set(channelMap).count == inputChannels,
              channelMap.allSatisfy({ (0..<outputChannels).contains($0) }),
              (32...8192).contains(requestedFrames) else { throw Failure("Unsupported direct output format.") }
        self.deviceID = deviceID; self.sampleRate = sampleRate
        self.inputChannels = inputChannels; self.outputChannels = outputChannels
        self.requestedFrames = requestedFrames
        guard let processor = FinalOutputProcessor(inputChannels: inputChannels, outputChannels: outputChannels,
            channelMap: channelMap, sampleRate: sampleRate) else { throw Failure("Unsupported direct output mapping.") }
        finalProcessor = processor
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var original: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        try Self.check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &original), "Read device buffer")
        originalBufferFrames = original
        var range = AudioValueRange(); var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        var rangeAddress = address; rangeAddress.mSelector = kAudioDevicePropertyBufferFrameSizeRange
        try Self.check(AudioObjectGetPropertyData(deviceID, &rangeAddress, 0, nil, &rangeSize, &range), "Read device buffer range")
        guard range.mMinimum.isFinite, range.mMaximum.isFinite, range.mMinimum > 0,
              range.mMaximum >= range.mMinimum, range.mMaximum <= Double(UInt32.max) else {
            throw Failure("The output device reported an invalid buffer range.")
        }
        var frames = UInt32(min(range.mMaximum, max(range.mMinimum, Double(requestedFrames))))
        var writable = DarwinBoolean(false)
        let canSet = AudioObjectIsPropertySettable(deviceID, &address, &writable) == noErr && writable.boolValue
        let changed = frames != original && canSet && AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &frames) == noErr
        changedDeviceBuffer = changed
        var actual = original
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &actual) != noErr { actual = changed ? frames : original }
        bufferFrames = Int(actual)
        guard actual > 0, actual <= 8192,
              let storage = DirectOutputBuffer(channels: outputChannels, capacityFrames: 65536, prerollFrames: Int(actual) * 2) else {
            if changed { var restore = original; AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &restore) }
            throw Failure("The output device buffer is unsupported.")
        }
        self.storage = storage
        do {
            var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else { throw Failure("Core Audio output is unavailable.") }
            var created: AudioUnit?
            try Self.check(AudioComponentInstanceNew(component, &created), "Create direct output")
            guard let created else { throw Failure("Core Audio did not create an output unit.") }
            unit = created
            var outputDevice = deviceID
            try Self.check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &outputDevice, UInt32(MemoryLayout<AudioDeviceID>.size)), "Select output device")
            var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(outputChannels * 4), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(outputChannels * 4), mChannelsPerFrame: UInt32(outputChannels), mBitsPerChannel: 32, mReserved: 0)
            try Self.check(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set output format")
            var maximum: UInt32 = 8192
            try Self.check(AudioUnitSetProperty(created, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &maximum, UInt32(MemoryLayout<UInt32>.size)), "Set maximum output block")
            var callback = AURenderCallbackStruct(inputProc: { context, _, timestamp, _, frames, data in
                guard let data else { return kAudio_ParamError }
                let buffers = UnsafeMutableAudioBufferListPointer(data)
                guard buffers.count == 1, frames <= 8192,
                      buffers[0].mNumberChannels == DirectOutputBuffer.channelCount(context: context),
                      let samples = buffers[0].mData,
                      buffers[0].mDataByteSize >= frames * buffers[0].mNumberChannels * 4 else {
                    for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                    return kAudio_ParamError
                }
                DirectOutputBuffer.render(context: context, output: samples.assumingMemoryBound(to: Float.self), frames: frames,
                    sampleTime: timestamp.pointee.mSampleTime, hostTime: timestamp.pointee.mHostTime, flags: timestamp.pointee.mFlags.rawValue)
                return noErr
            }, inputProcRefCon: storage.context)
            try Self.check(AudioUnitSetProperty(created, kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install output callback")
            try Self.check(AudioUnitInitialize(created), "Initialize output")
            try Self.check(AudioOutputUnitStart(created), "Start output")
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    package func write(_ bytes: Data) throws {
        // Source packets may be larger than the hardware buffer. Mapping is
        // writer-side; the output ring never accumulates that entire packet.
        let mapped = try finalProcessor.process(bytes)
        let frames = mapped.count / outputChannels
        try mapped.withUnsafeBufferPointer { samples in
            var offset = 0
            var lastProgress = ProcessInfo.processInfo.systemUptime
            while offset < frames {
                guard storage.accepting else { throw Failure("Direct output stopped.") }
                let snapshot = storage.snapshot()
                // Other audio clients may renegotiate the shared device buffer.
                // Follow the callback's actual size without reallocating its ring.
                let currentFrames = snapshot.callbackFrames > 0 ? Int(snapshot.callbackFrames) : bufferFrames
                let allowance = max(0, currentFrames * 3 - Int(snapshot.bufferedFrames))
                if allowance > 0, let base = samples.baseAddress {
                    let written = storage.push(base + offset * outputChannels, frames: min(frames - offset, allowance))
                    if written > 0 { offset += written; lastProgress = ProcessInfo.processInfo.systemUptime; continue }
                }
                let remaining = 0.25 - (ProcessInfo.processInfo.systemUptime - lastProgress)
                guard remaining > 0 else { throw Failure("The output device stopped consuming audio.") }
                storage.waitForCallback(after: snapshot.renderedFrames,
                    timeoutNanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    package func cancel() { storage.cancel() }
    package func finish() { cancel() }

    /// Control-side only. Callback state outlives AudioOutputUnitStop/Dispose;
    /// a cancelled writer can still unwind while retaining this object.
    package func stop() {
        guard !stopped else { return }
        stopped = true
        cancel()
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); self.unit = nil }
        if changedDeviceBuffer {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var current: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &current) == noErr, current == bufferFrames {
                var original = originalBufferFrames
                AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &original)
            }
        }
    }

    package func snapshot(readMeters: Bool = false) -> Snapshot {
        let value = storage.snapshot()
        let now = PerformanceClock.now()
        let clock = value.timestampFlags & 3 == 3 ? AudioClockObservation(epoch: epoch,
            sampleTime: value.sampleTime, hostTime: value.hostTime, nominalRate: sampleRate,
            timestampFlags: value.timestampFlags, received: now, deviceID: deviceID) : nil
        var scale = mach_timebase_info_data_t(); mach_timebase_info(&scale)
        let last = value.hostTime > 0 ? value.hostTime : epoch
        let host = mach_absolute_time()
        let age = host >= last ? Double(host - last) * Double(scale.numer) / Double(scale.denom) / 1e9 : 0
        let error = storage.accepting && age > 0.5 ? "Direct audio output is no longer responding." : nil
        func db(_ value: Float) -> Double { value > 0 ? max(-150, 20 * log10(Double(value))) : -150 }
        return Snapshot(peak: readMeters ? (0..<outputChannels).map { db(storage.takePeak(channel: $0)) } : [],
            rms: readMeters ? (0..<outputChannels).map { db(storage.rms(channel: $0)) } : [],
            bufferedFrames: value.bufferedFrames, underrunFrames: value.underrunFrames,
            clippedSamples: value.clippedSamples,
            callbackFrames: value.callbackFrames > 0 ? Int(value.callbackFrames) : bufferFrames, clock: clock,
            silentSeconds: Double(host - min(host, max(epoch, value.lastSignalHostTime))) * Double(scale.numer) / Double(scale.denom) / 1e9,
            error: error)
    }

    private struct Failure: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }
    private static func check(_ status: OSStatus, _ action: String) throws {
        if status != noErr { throw Failure("\(action) failed (Core Audio \(status)).") }
    }
}
