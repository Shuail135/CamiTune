import Foundation
import SystemAudioBridgeC

struct PerformanceTick: Sendable, Codable, Comparable, Equatable {
    let rawValue: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    func advanced(seconds: Double) -> Self {
        .init(rawValue: rawValue &+ UInt64(max(0, seconds) * 1_000_000_000))
    }
}

enum PerformanceClock {
    static func now() -> PerformanceTick { .init(rawValue: DispatchTime.now().uptimeNanoseconds) }
    static func duration(from start: PerformanceTick, to end: PerformanceTick) -> UInt64 {
        end.rawValue >= start.rawValue ? end.rawValue - start.rawValue : 0
    }
    static func milliseconds(_ start: PerformanceTick, _ end: PerformanceTick) -> Double {
        Double(duration(from: start, to: end)) / 1_000_000
    }
}

final class PerformanceAtomic: @unchecked Sendable {
    private let value = cmt_performance_atomic_create()!
    deinit { cmt_performance_atomic_destroy(value) }
    var count: UInt64 { cmt_performance_atomic_load(value) }
    func set(_ number: UInt64) { cmt_performance_atomic_store(value, number) }
    func exchange(_ number: UInt64) -> UInt64 { cmt_performance_atomic_exchange(value, number) }
    func increment() { cmt_performance_atomic_increment(value) }
}
