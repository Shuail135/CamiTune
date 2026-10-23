import CamiTuneDomain
import Foundation

/// A bounded, timestamped stereo send. Multiple clients of one app sum into
/// the same timeline; late/duplicate packets cannot replay detector audio.
package final class PluginSidechainBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity = 32768
    private var left = [Float](repeating: 0, count: 32768)
    private var right = [Float](repeating: 0, count: 32768)
    private var stamps = [Int64](repeating: .min, count: 32768)
    private var ends: [UInt64: Int64] = [:]
    private var first: Int64?
    private var newest: Int64?
    private var cursor: Int64?
    private var receivedAt: UInt64 = 0
    private var enabled = true
    package let source: PluginSidechainSource
    package let sampleRate: Double
    package init(source: PluginSidechainSource, sampleRate: Double) { self.source = source; self.sampleRate = sampleRate }

    package func append(_ samples: UnsafeBufferPointer<Float>, channels: Int, rate: Double, sampleTime: Double,
                        stream: UInt64, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard channels > 0, channels <= 32, samples.count.isMultiple(of: channels), !samples.isEmpty,
              rate.isFinite, (8000...384000).contains(rate), sampleTime.isFinite,
              sampleRate.isFinite, (8000...384000).contains(sampleRate),
              abs(sampleTime * sampleRate / rate) < Double(Int64.max / 2), (0..<channels).contains(source.channelOffset) else { return }
        let frames = samples.count / channels
        guard frames <= 32768 else { return }
        let start = Int64((sampleTime * sampleRate / rate).rounded(.up))
        let end = Int64(((sampleTime + Double(frames)) * sampleRate / rate).rounded(.up))
        guard end > start, end - start <= capacity else { return }
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        if let previous = ends[stream], end < previous - Int64(sampleRate / 2) { clearLocked() }
        let acceptedStart = max(start, ends[stream] ?? start)
        guard end > acceptedStart else { return }
        if ends.count >= 256 && ends[stream] == nil { ends.removeAll(keepingCapacity: true) }
        ends[stream] = end
        first = min(first ?? acceptedStart, acceptedStart); newest = max(newest ?? end, end); receivedAt = now
        for time in acceptedStart..<end {
            let sourceFrame = max(0, min(Double(frames - 1), Double(time) * rate / sampleRate - sampleTime))
            let a = Int(sourceFrame), b = min(frames - 1, a + 1), fraction = Float(sourceFrame - Double(a))
            let l = source.channelOffset, r = min(channels - 1, l + 1)
            func value(_ channel: Int) -> Float {
                let x = samples[a * channels + channel], y = samples[b * channels + channel]
                return x.isFinite && y.isFinite ? x + (y - x) * fraction : 0
            }
            let index = Int(time % Int64(capacity) + Int64(capacity)) % capacity
            if stamps[index] != time { stamps[index] = time; left[index] = 0; right[index] = 0 }
            left[index] += value(l); right[index] += value(r)
        }
    }

    /// The audio writer never waits for a capture callback. Missing, stale or
    /// contended sidechains supply silence, independently of the main signal.
    package func read(into output: UnsafeMutableBufferPointer<Float>, frames: Int,
                      now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard frames >= 0, output.count >= frames * 2 else { return }
        output.baseAddress?.update(repeating: 0, count: frames * 2)
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard let first, let newest, now >= receivedAt, now - receivedAt < 250_000_000 else { cursor = nil; return }
        var start = max(cursor ?? first, newest - Int64(capacity))
        // Rejoin a resumed main stream at recent input, never drain a backlog.
        if newest - start > Int64(max(frames * 2, Int(sampleRate * 0.03))) { start = max(first, newest - Int64(frames)) }
        for f in 0..<frames {
            let time = start + Int64(f), index = Int(time % Int64(capacity) + Int64(capacity)) % capacity
            if stamps[index] == time {
                output[f * 2] = left[index].isFinite ? left[index] : 0
                output[f * 2 + 1] = right[index].isFinite ? right[index] : 0
            }
        }
        // Do not run ahead of an independent capture clock during an underrun.
        // The next packet resumes at the first unread sample, never replays it.
        cursor = min(start + Int64(frames), newest)
    }
    package func reset() { lock.lock(); clearLocked(); lock.unlock() }
    package func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled
        if !enabled { clearLocked() }
    }
    private func clearLocked() {
        stamps.withUnsafeMutableBufferPointer { $0.baseAddress?.update(repeating: .min, count: $0.count) }
        ends.removeAll(keepingCapacity: true); first = nil; newest = nil; cursor = nil; receivedAt = 0
    }
}

package final class PluginSidechainHub: @unchecked Sendable {
    private final class WeakBuffer {
        weak var value: PluginSidechainBuffer?
        init(_ value: PluginSidechainBuffer) { self.value = value }
    }
    private let lock = NSLock()
    private var buffers: [WeakBuffer] = []
    package init() {}
    package func subscribe(_ source: PluginSidechainSource, sampleRate: Double) -> PluginSidechainBuffer {
        let buffer = PluginSidechainBuffer(source: source, sampleRate: sampleRate)
        lock.lock(); buffers.removeAll { $0.value == nil }; buffers.append(WeakBuffer(buffer)); lock.unlock()
        return buffer
    }
    package func offer(kind: PluginSidechainSource.Kind, id: String, samples: UnsafeBufferPointer<Float>,
                       channels: Int, rate: Double, sampleTime: Double, stream: UInt64) {
        guard lock.try() else { return }
        let targets = buffers.compactMap(\.value).filter { $0.source.kind == kind && $0.source.id == id }
        lock.unlock()
        for target in targets { target.append(samples, channels: channels, rate: rate, sampleTime: sampleTime, stream: stream) }
    }
    package func invalidate(kind: PluginSidechainSource.Kind, id: String) {
        lock.lock()
        let targets = buffers.compactMap(\.value).filter { $0.source.kind == kind && $0.source.id == id }
        lock.unlock()
        targets.forEach { $0.reset() }
    }
}
