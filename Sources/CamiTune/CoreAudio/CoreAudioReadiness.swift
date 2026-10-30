import Foundation
import AudioToolbox
import CoreAudio

struct CoreAudioWaitResult: Sendable, Equatable {
    enum Source: String, Sendable { case immediate, notification, fallback, timedOut, cancelled }
    let source: Source
    let milliseconds: Double
}

/// No HAL calls under locks. Each event is a hint: freshly recheck the condition.
/// AsyncStream cancellation wakes the consumer, and defer removes every token.
enum CoreAudioConditionWaiter {
    enum Wake: Sendable { case notification, fallback, deadline, cancelled }
    static func wait(
        backend: CoreAudioHALBackend, event: CoreAudioEvent, timeout: Duration,
        condition: @escaping @Sendable () -> Bool,
        mutation: (@Sendable () throws -> Void)? = nil
    ) async throws -> CoreAudioWaitResult {
        let start = ContinuousClock.now
        func result(_ source: CoreAudioWaitResult.Source) -> CoreAudioWaitResult {
            let elapsed = start.duration(to: .now).components
            return .init(source: source, milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        try Task.checkCancellation()
        if condition() { return result(.immediate) }
        let (stream, continuation) = AsyncStream<Wake>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let listener = backend.subscribe(event) { continuation.yield(.notification) }
        let fallback = backend.schedule(timeout / 2) { continuation.yield(.fallback) }
        let deadline = backend.schedule(timeout) { continuation.yield(.deadline); continuation.finish() }
        defer { listener?.cancel(); fallback.cancel(); deadline.cancel(); continuation.finish() }
        try Task.checkCancellation()
        // This closes the check/subscribe race even when the event was lost.
        if condition() { return result(.immediate) }
        try mutation?()
        if condition() { return result(.immediate) }
        for await wake in stream {
            try Task.checkCancellation()
            if condition() { return result(wake == .notification ? .notification : .fallback) }
            if wake == .deadline { return result(.timedOut) }
        }
        throw CancellationError()
    }
}

/// The existing endpoint publication transaction is synchronous on a worker.
/// Keep that transaction atomic, but wake visibility checks from HAL events.
/// The same injected clock/event seam makes its timing deterministic in tests.
extension CoreAudioConditionWaiter {
    private final class Signal: @unchecked Sendable {
        let condition = NSCondition()
        var revision: UInt64 = 0
        var source: Wake = .notification
        var expired = false
        func wake(_ value: Wake) {
            condition.lock()
            if !expired { revision &+= 1; source = value; expired = value == .deadline || value == .cancelled }
            condition.broadcast(); condition.unlock()
        }
        func snapshot() -> (UInt64, Wake, Bool) {
            condition.lock(); defer { condition.unlock() }; return (revision, source, expired)
        }
        func awaitChange(after revision: UInt64) {
            condition.lock(); defer { condition.unlock() }
            while self.revision == revision && !expired { condition.wait() }
        }
    }
    static func waitSynchronously(backend: CoreAudioHALBackend, events: [CoreAudioEvent],
                                  timeout: Duration, condition: @escaping @Sendable () -> Bool) -> CoreAudioWaitResult {
        let start = ContinuousClock.now
        func result(_ source: CoreAudioWaitResult.Source) -> CoreAudioWaitResult {
            let elapsed = start.duration(to: .now).components
            return .init(source: source, milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        if condition() { return result(.immediate) }
        let signal = Signal()
        let cancellation = CoreAudioPublicationCancellation.current?.observe { signal.wake(.cancelled) }
        let listeners = events.compactMap { event in backend.subscribe(event) { signal.wake(.notification) } }
        let fallback = backend.schedule(timeout / 2) { signal.wake(.fallback) }
        let deadline = backend.schedule(timeout) { signal.wake(.deadline) }
        defer { listeners.forEach { $0.cancel() }; fallback.cancel(); deadline.cancel(); cancellation?.cancel() }
        // Capture the event revision before checking so a racing notification
        // between the read and condition.wait cannot be lost.
        var first = true
        while true {
            let (revision, source, expired) = signal.snapshot()
            if source == .cancelled { return result(.cancelled) }
            if condition() { return result(first ? .immediate : (source == .notification ? .notification : .fallback)) }
            if expired { return result(.timedOut) }
            first = false
            signal.awaitChange(after: revision)
        }
    }
}

final class CoreAudioWaitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CoreAudioWaitResult] = []
    func append(_ result: CoreAudioWaitResult) { lock.withLock { results.append(result) } }
    var values: [CoreAudioWaitResult] { lock.withLock { results } }
}

/// Publication cancellation wakes its current condition immediately. The publisher
/// disables this scope only while rolling back already-sent external effects.
final class CoreAudioPublicationCancellation: @unchecked Sendable {
    @TaskLocal static var current: CoreAudioPublicationCancellation?
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]
    func observe(_ action: @escaping @Sendable () -> Void) -> CoreAudioListenerToken {
        let id = UUID()
        let call = lock.withLock { if cancelled { return true }; observers[id] = action; return false }
        if call { action() }
        return CoreAudioListenerToken { [weak self] in self?.remove(id) }
    }
    private func remove(_ id: UUID) { lock.withLock { _ = observers.removeValue(forKey: id) } }
    func cancel() {
        let actions = lock.withLock { cancelled = true; return Array(observers.values) }
        actions.forEach { $0() }
    }
}

/// Checks a profile endpoint from an audio client's side of HAL before it can
/// become the default output. Run on the publication worker, never in audio IO.
struct CoreAudioProfileFormat {
    var read: (AudioObjectID, AudioObjectPropertyAddress) -> Data? = Self.readProperty
    var readOutputUnitLayout: (AudioObjectID) -> Data? = Self.outputUnitLayout

    func matches(deviceID: AudioObjectID, expected: ProfileEndpointState.Format) -> Bool {
        guard (1...32).contains(expected.channelCount), expected.sampleRate.isFinite,
              expected.sampleRate > 0 else { return false }
        func property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope, _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Data? {
            read(object, .init(mSelector: selector, mScope: scope, mElement: element))
        }
        // Our profile endpoints expose one interleaved output stream. A matching
        // stream count alone cannot establish the preferred speaker layout.
        guard let buffers = property(deviceID, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
              let bufferCount: UInt32 = value(buffers), bufferCount == 1,
              let buffer: AudioBuffer = value(buffers, at: MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!),
              buffer.mNumberChannels == expected.channelCount,
              let streams = property(deviceID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
              streams.count == MemoryLayout<AudioObjectID>.size,
              let stream: AudioObjectID = value(streams), stream != kAudioObjectUnknown else { return false }
        for selector in [kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat] {
            guard let data = property(stream, selector, kAudioObjectPropertyScopeGlobal),
                  let format: AudioStreamBasicDescription = value(data),
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mChannelsPerFrame == expected.channelCount,
                  format.mSampleRate == expected.sampleRate else { return false }
        }
        guard let rate = property(deviceID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
              let sampleRate: Double = value(rate), sampleRate == expected.sampleRate,
              let expectedLabels = Self.labels(for: expected.layoutTag),
              expectedLabels.count == Int(expected.channelCount) else { return false }
        // Some clients query the main element, others the wildcard element.
        // Both must describe the same channels, including their order.
        for element in [kAudioObjectPropertyElementMain, kAudioObjectPropertyElementWildcard] {
            guard let layout = property(deviceID, kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput, element),
                  Self.labels(in: layout) == expectedLabels else { return false }
        }
        // A tag-only device property can pass the HAL checks while the output
        // AudioUnit exposes left/right followed by unknown speakers. Players
        // using that interface will downmix before we receive their PCM.
        guard let unitLayout = readOutputUnitLayout(deviceID),
              Self.labels(in: unitLayout) == expectedLabels else { return false }
        return true
    }

    private static func outputUnitLayout(_ deviceID: AudioObjectID) -> Data? {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { return nil }
        defer { AudioComponentInstanceDispose(unit) }
        var device = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &device, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr else { return nil }
        defer { AudioUnitUninitialize(unit) }
        // No render callback is installed and AudioOutputUnitStart is never
        // called. This only inspects the virtual endpoint on the control worker.
        var size: UInt32 = 0, writable = DarwinBoolean(false)
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_AudioChannelLayout,
            kAudioUnitScope_Output, 0, &size, &writable) == noErr,
            size > 0, size <= 65536 else { return nil }
        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes {
            AudioUnitGetProperty(unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Output,
                                 0, $0.baseAddress!, &size)
        }
        guard status == noErr, size <= data.count else { return nil }
        data.count = Int(size)
        return data
    }

    private func value<T>(_ data: Data, at offset: Int = 0) -> T? {
        guard data.count >= offset + MemoryLayout<T>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }

    private static func labels(for tag: AudioChannelLayoutTag) -> [AudioChannelLabel]? {
        expandedLabels(selector: kAudioFormatProperty_ChannelLayoutForTag, value: tag)
    }

    private static func expandedLabels(selector: AudioFormatPropertyID, value: UInt32) -> [AudioChannelLabel]? {
        var value = value, size: UInt32 = 0
        let valueSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFormatGetPropertyInfo(selector, valueSize, &value, &size) == noErr,
              size > 0, size <= 65536 else { return nil }
        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes {
            AudioFormatGetProperty(selector, valueSize, &value, &size, $0.baseAddress!)
        }
        guard status == noErr, size <= data.count else { return nil }
        data.count = Int(size)
        // AudioFormatGetProperty may retain the original tag while filling in
        // descriptions. Read those descriptions directly, without expanding again.
        return labels(in: data, expand: false)
    }

    private static func labels(in data: Data, expand: Bool = true) -> [AudioChannelLabel]? {
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        guard data.count >= offset else { return nil }
        let tag = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if expand && tag != kAudioChannelLayoutTag_UseChannelDescriptions {
            if tag == kAudioChannelLayoutTag_UseChannelBitmap {
                let bitmap = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
                return expandedLabels(selector: kAudioFormatProperty_ChannelLayoutForBitmap, value: bitmap)
            }
            return labels(for: tag)
        }
        let count = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
        guard (1...32).contains(count), count <= (data.count - offset) / MemoryLayout<AudioChannelDescription>.stride else { return nil }
        return data.withUnsafeBytes { bytes in
            (0..<count).map { bytes.loadUnaligned(fromByteOffset: offset + $0 * MemoryLayout<AudioChannelDescription>.stride,
                                                 as: AudioChannelDescription.self).mChannelLabel }
        }
    }

    private static func readProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Data? {
        var address = address, size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0, size <= 65536 else { return nil }
        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr, size <= data.count else { return nil }
        data.count = Int(size)
        return data
    }
}
