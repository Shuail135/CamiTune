import CamiTuneAudio
import CamiTuneDomain
import Foundation

enum AudioProcessingEngine: String, CaseIterable, Sendable {
    case camillaDSP = "camilla"
    case ctDSP = "ctdsp"

    static let storageKey = "audioProcessingEngine"

    var displayName: String {
        switch self {
        case .camillaDSP: return "CamillaDSP"
        case .ctDSP: return "ctDSP"
        }
    }

    static func saved(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .camillaDSP
    }

    static func selectedForLaunch(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        #if DEBUG
        // Local qualification selects either engine without changing the saved preference.
        if let value = environment["CAMITUNE_DEVELOPMENT_DSP"], let engine = Self(rawValue: value) {
            return engine
        }
        #endif
        return saved(in: defaults)
    }

    @MainActor
    func makeBackend(binary: URL) -> any AudioProcessingBackend {
        switch self {
        case .camillaDSP: return CamillaDSPController(manager: CamillaDSPManager(), binary: binary)
        case .ctDSP: return CTDSPBackend()
        }
    }
}

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
