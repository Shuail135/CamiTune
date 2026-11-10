import Foundation
import CamiTuneAtomics
import Darwin

package struct PerformanceTick: Sendable, Codable, Comparable, Equatable {
    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package let rawValue: UInt64
    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    package func advanced(seconds: Double) -> Self {
        .init(rawValue: rawValue &+ UInt64(max(0, seconds) * 1_000_000_000))
    }
}

package enum PerformanceClock {
    package static func now() -> PerformanceTick { .init(rawValue: DispatchTime.now().uptimeNanoseconds) }
    package static func duration(from start: PerformanceTick, to end: PerformanceTick) -> UInt64 {
        end.rawValue >= start.rawValue ? end.rawValue - start.rawValue : 0
    }
    package static func milliseconds(_ start: PerformanceTick, _ end: PerformanceTick) -> Double {
        Double(duration(from: start, to: end)) / 1_000_000
    }
}

/// An observation of this thread, never a scheduling or audio clock.
package struct PerformanceThreadSample: Sendable, Codable, Equatable {
    package init(threadID: UInt64, observed: PerformanceTick, cpuNanoseconds: UInt64) {
        self.threadID = threadID; self.observed = observed; self.cpuNanoseconds = cpuNanoseconds
    }
    package let threadID: UInt64
    package let observed: PerformanceTick
    package let cpuNanoseconds: UInt64

    /// Called only during detailed tracing. The wall observation precedes the
    /// CPU query; the pair is not an atomic hardware timestamp.
    package static func now() -> Self? {
        var threadID: UInt64 = 0
        guard pthread_threadid_np(nil, &threadID) == 0 else { return nil }
        let observed = PerformanceClock.now()
        var cpu = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu) == 0 else { return nil }
        return .init(threadID: threadID, observed: observed,
            cpuNanoseconds: UInt64(cpu.tv_sec) * 1_000_000_000 + UInt64(cpu.tv_nsec))
    }

    package func cpuMilliseconds(until end: Self) -> Double? {
        guard threadID == end.threadID, observed <= end.observed,
              cpuNanoseconds <= end.cpuNanoseconds else { return nil }
        return Double(end.cpuNanoseconds - cpuNanoseconds) / 1_000_000
    }
}

package final class PerformanceAtomic: @unchecked Sendable {
    package init() {}
    private let value = cmt_performance_atomic_create()!
    deinit { cmt_performance_atomic_destroy(value) }
    package var count: UInt64 { cmt_performance_atomic_load(value) }
    package func set(_ number: UInt64) { cmt_performance_atomic_store(value, number) }
    package func exchange(_ number: UInt64) -> UInt64 { cmt_performance_atomic_exchange(value, number) }
    package func increment() { cmt_performance_atomic_increment(value) }
    package var acquired: UInt64 { cmt_performance_atomic_load_acquire(value) }
    package func publish(_ number: UInt64) { cmt_performance_atomic_store_release(value, number) }
    package func compareExchange(expected: UInt64, desired: UInt64) -> Bool {
        cmt_performance_atomic_compare_exchange(value, expected, desired) != 0
    }
}
