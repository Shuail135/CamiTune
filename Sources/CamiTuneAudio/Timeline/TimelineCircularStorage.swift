import CamiTuneDomain
import Accelerate
import Foundation

/// The reader's negotiated packet ceiling, not source queue occupancy, bounds
/// addressable storage. 2 held packets + 8 tolerated gap packets + 1 input.
package struct TimelineStoragePolicy: Sendable {
    package let maximumPacketFrames: Int
    package let maximumFrames: Int
    package init(maximumPacketFrames: Int) {
        let product = maximumPacketFrames.multipliedReportingOverflow(by: 11)
        self.maximumPacketFrames = max(0, maximumPacketFrames)
        maximumFrames = product.overflow || maximumPacketFrames <= 0 ? 0 : product.partialValue
    }
    package func reservation(for packetFrames: Int) -> Int? {
        guard packetFrames > 0, packetFrames <= maximumPacketFrames else { return nil }
        let product = packetFrames.multipliedReportingOverflow(by: 11)
        return product.overflow ? nil : min(maximumFrames, product.partialValue)
    }
}

package enum TimelineStorageFailure: Error { case capacityExceeded }

/// Specialized interleaved PCM ring. Exclusive owner only; never exposes its
/// backing arrays or pointers. All buses share one logical head and live span.
/// Reference identity avoids Swift COW copying the retained span when a pending
/// window is fetched from the mixer's dictionary. No output aliases this object.
package final class TimelineCircularStorage {
    package let channelCount: Int
    package let maximumFrames: Int
    package private(set) var capacityFrames = 0
    package private(set) var headFrameIndex = 0
    package private(set) var frameCount = 0
    private var combined: [Float] = []
    private var modeBuses: [PlaybackMode: [Float]] = [:]
    package private(set) var reallocations: UInt64 = 0
    package private(set) var growthCopiedFrames: UInt64 = 0
    package private(set) var wrappedReads: UInt64 = 0
    package private(set) var wrappedWrites: UInt64 = 0
    package var allocatedBusCount: Int { 1 + modeBuses.count }
    package var allocatedBytes: Int { capacityFrames * channelCount * MemoryLayout<Float>.stride * allocatedBusCount }

    package init(channelCount: Int, maximumFrames: Int) throws {
        // Check even the all-bus upper bound before accepting a storage policy.
        var bytes = maximumFrames
        for multiplier in [channelCount, MemoryLayout<Float>.stride, 1 + PlaybackMode.allCases.count] {
            let product = bytes.multipliedReportingOverflow(by: multiplier)
            guard !product.overflow else { throw TimelineStorageFailure.capacityExceeded }
            bytes = product.partialValue
        }
        guard (1...32).contains(channelCount), maximumFrames > 0 else { throw TimelineStorageFailure.capacityExceeded }
        self.channelCount = channelCount; self.maximumFrames = maximumFrames
    }

    /// Capacity changes are the only operations that copy retained PCM.
    @discardableResult package func reserve(_ required: Int) throws -> Bool {
        guard required >= 0, required <= maximumFrames else { throw TimelineStorageFailure.capacityExceeded }
        guard required > capacityFrames else { return false }
        var next = max(1, capacityFrames)
        while next < required { next = next > maximumFrames / 2 ? maximumFrames : next * 2 }
        let newSamples = next * channelCount
        var newCombined = [Float](repeating: 0, count: newSamples)
        copyLive(combined, to: &newCombined)
        var newBuses: [PlaybackMode: [Float]] = [:]
        for (mode, bus) in modeBuses {
            var new = [Float](repeating: 0, count: newSamples)
            copyLive(bus, to: &new)
            newBuses[mode] = new
        }
        growthCopiedFrames += UInt64(frameCount * allocatedBusCount)
        reallocations += 1
        combined = newCombined; modeBuses = newBuses
        capacityFrames = next; headFrameIndex = 0
        return true
    }

    package func prepend(_ count: Int) {
        precondition(count >= 0 && count <= capacityFrames - frameCount)
        headFrameIndex = (headFrameIndex - count + capacityFrames) % capacityFrames
        frameCount += count
        clear(offset: 0, count: count)
    }
    package func extend(to count: Int) {
        precondition(count >= frameCount && count <= capacityFrames)
        clear(offset: frameCount, count: count - frameCount)
        frameCount = count
    }
    package func add(_ samples: UnsafeBufferPointer<Float>, sourceFrameOffset: Int, frameCount count: Int,
             at offset: Int, mode: PlaybackMode) {
        precondition(offset >= 0 && count >= 0 && offset + count <= frameCount)
        precondition(sourceFrameOffset >= 0 && (sourceFrameOffset + count) * channelCount <= samples.count)
        if modeBuses[mode] == nil { modeBuses[mode] = [Float](repeating: 0, count: capacityFrames * channelCount) }
        let first = (headFrameIndex + offset) % capacityFrames
        let tail = min(count, capacityFrames - first)
        if tail < count { wrappedWrites += 1 }
        let channels = channelCount
        // Inout dictionary access keeps the mode array uniquely held.
        func accumulate(_ destination: inout [Float]) {
            let source = sourceFrameOffset * channels
            destination.withUnsafeMutableBufferPointer { buffer in
                if tail > 0 {
                    let output = buffer.baseAddress! + first * channels
                    vDSP_vadd(samples.baseAddress! + source, 1, output, 1, output, 1, vDSP_Length(tail * channels))
                }
                if count > tail {
                    let output = buffer.baseAddress!
                    vDSP_vadd(samples.baseAddress! + source + tail * channels, 1,
                        output, 1, output, 1, vDSP_Length((count - tail) * channels))
                }
            }
        }
        accumulate(&combined)
        accumulate(&modeBuses[mode]!)
    }

    package func materializePrefix(_ count: Int) -> (combined: [Float], modes: [PlaybackMode: [Float]]) {
        precondition(count >= 0 && count <= frameCount)
        if count > capacityFrames - headFrameIndex { wrappedReads += 1 }
        return (copyPrefix(combined, count: count), modeBuses.mapValues { copyPrefix($0, count: count) })
    }
    package func discardPrefix(_ count: Int) {
        precondition(count >= 0 && count <= frameCount)
        clear(offset: 0, count: count)
        headFrameIndex = (headFrameIndex + count) % capacityFrames
        frameCount -= count
    }

    private func clear(offset: Int, count: Int) {
        guard count > 0 else { return }
        let first = (headFrameIndex + offset) % capacityFrames
        let tail = min(count, capacityFrames - first)
        let channels = channelCount
        func zero(_ bus: inout [Float]) {
            bus.withUnsafeMutableBufferPointer { buffer in
                if tail > 0 { vDSP_vclr(buffer.baseAddress! + first * channels, 1, vDSP_Length(tail * channels)) }
                if count > tail { vDSP_vclr(buffer.baseAddress!, 1, vDSP_Length((count - tail) * channels)) }
            }
        }
        zero(&combined)
        for mode in PlaybackMode.allCases where modeBuses[mode] != nil { zero(&modeBuses[mode]!) }
    }
    private func copyPrefix(_ bus: [Float], count: Int) -> [Float] {
        let sampleCount = count * channelCount
        let firstSamples = min(count, capacityFrames - headFrameIndex) * channelCount
        return Array(unsafeUninitializedCapacity: sampleCount) { destination, initialized in
            bus.withUnsafeBufferPointer { source in
                if firstSamples > 0 {
                    destination.baseAddress!.initialize(from: source.baseAddress! + headFrameIndex * channelCount, count: firstSamples)
                }
                if sampleCount > firstSamples {
                    (destination.baseAddress! + firstSamples).initialize(from: source.baseAddress!, count: sampleCount - firstSamples)
                }
            }
            initialized = sampleCount
        }
    }
    private func copyLive(_ bus: [Float], to destination: inout [Float]) {
        guard frameCount > 0 else { return }
        let tailSamples = min(frameCount, capacityFrames - headFrameIndex) * channelCount
        for n in 0..<tailSamples { destination[n] = bus[headFrameIndex * channelCount + n] }
        for n in 0..<(frameCount * channelCount - tailSamples) { destination[tailSamples + n] = bus[n] }
    }
}
