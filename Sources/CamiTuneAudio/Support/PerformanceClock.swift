import Foundation
import CamiTuneAtomics

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

package final class PerformanceAtomic: @unchecked Sendable {
    package init() {}
    private let value = cmt_performance_atomic_create()!
    deinit { cmt_performance_atomic_destroy(value) }
    package var count: UInt64 { cmt_performance_atomic_load(value) }
    package func set(_ number: UInt64) { cmt_performance_atomic_store(value, number) }
    package func exchange(_ number: UInt64) -> UInt64 { cmt_performance_atomic_exchange(value, number) }
    package func increment() { cmt_performance_atomic_increment(value) }
}
