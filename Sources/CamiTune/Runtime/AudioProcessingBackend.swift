import CamiTuneAudio
import CamiTuneDomain
import Foundation

struct AudioBackendWork: Sendable {
    var loadPercent: Double?
    var clockEpoch: UInt64?
    var underrunFrames: UInt64?
}

@MainActor
protocol AudioProcessingBackend: AnyObject {
    var name: String { get }
    var playbackClock: AudioPlaybackClock? { get }
    var isRunning: Bool { get }
    var graphUpdateDescription: String? { get }
    func validateAvailability() throws
    func start() async throws
    func validateOutput(uid: String) async throws
    func resetRuntime()
    func applyGraph(_ graph: ProcessingGraph, performanceRecorder: RuntimePerformanceRecorder?) async throws
    func makeInputSink() throws -> any PCMOutputSink
    func fetchMeters() async throws -> SignalLevels
    func fetchTelemetry() async throws -> AudioOutputTelemetry
    func measureWork() async -> AudioBackendWork
    func observePlaybackClock(session: UUID, consumer: @escaping @Sendable (AudioClockObservation) -> Void)
    func stopClockObservations()
    func closeInput() async
    func closeInputSynchronously()
    func stop() async
    func stopSynchronously()
}
