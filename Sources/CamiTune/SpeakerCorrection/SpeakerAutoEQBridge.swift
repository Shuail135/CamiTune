import CamiTuneDomain
import Darwin
import Foundation

struct SpeakerAutoEQResponse: Decodable, Sendable {
    struct Filter: Decodable, Sendable { var type: String; var frequency: Double; var gainDB: Double; var q: Double }
    struct Engine: Decodable, Sendable { var name: String; var version: String; var mode: String }
    struct Diagnostics: Decodable, Sendable {
        var converged: Bool; var warnings: [String]; var objectiveBefore: Double; var objectiveAfter: Double
    }
    var schemaVersion: Int
    var filters: [Filter]
    var engine: Engine
    var sourceHash: String
    var diagnostics: Diagnostics
}
struct SpeakerAutoEQRequest: Encodable, Sendable {
    var schemaVersion = 1
    var mode: SpeakerListeningMode
    var speakerName: String
    var measurementVersion: String
    var measurementType = "CEA2034"
    var sampleRate: Double
    var filterCount: Int
    var minFrequency: Double
    var maxFrequency: Double
    var minimumGainDB: Double
    var maximumGainDB: Double
    var minimumQ: Double
    var maximumQ: Double
    var rawCEA2034: String
}
struct SpeakerAutoEQBridge: Sendable {
    var executable: URL?
    var timeout: TimeInterval = 120
    func generate(measurement: SpeakerCEA2034Measurement, mode: SpeakerListeningMode,
                  settings: SpeakerCorrectionSettings, sampleRate: Double) async throws -> SpeakerAutoEQResponse {
        try settings.validate(sampleRate: sampleRate)
        guard let helper = executable ?? Bundle.main.resourceURL?.appendingPathComponent("Helpers/camitune-speaker-eq"),
              FileManager.default.isExecutableFile(atPath: helper.path), let raw = String(data: measurement.rawPayload, encoding: .utf8) else {
            throw SpeakerCorrectionError.invalid("The bundled speaker optimizer is missing. Rebuild CamiTune's speaker helper.")
        }
        let request = SpeakerAutoEQRequest(mode: mode, speakerName: measurement.provenance.speakerName,
            measurementVersion: measurement.provenance.version, sampleRate: sampleRate, filterCount: settings.filterCount,
            minFrequency: settings.minFrequency, maxFrequency: settings.maxFrequency, minimumGainDB: settings.minimumGainDB,
            maximumGainDB: settings.maximumGainDB, minimumQ: settings.minimumQ, maximumQ: settings.maximumQ, rawCEA2034: raw)
        let data = try JSONEncoder().encode(request)
        let runner = SpeakerHelperProcess()
        let timeout = timeout
        return try await withTaskCancellationHandler {
            let output = try await Task.detached(priority: .userInitiated) {
                try runner.run(executable: helper, input: data, timeout: timeout)
            }.value
            try Task.checkCancellation()
            let response = try JSONDecoder().decode(SpeakerAutoEQResponse.self, from: output)
            guard response.schemaVersion == 1, response.sourceHash == measurement.rawPayloadHash,
                  response.engine.name == "autoeq", !response.engine.version.isEmpty, response.engine.mode == mode.loss,
                  response.diagnostics.converged, response.diagnostics.objectiveBefore.isFinite,
                  response.diagnostics.objectiveAfter.isFinite,
                  response.diagnostics.objectiveAfter <= response.diagnostics.objectiveBefore + 1e-6 else {
                throw SpeakerCorrectionError.invalid("The speaker optimizer returned an incomplete or mismatched result.")
            }
            return response
        } onCancel: { runner.cancel() }
    }
}

/// All blocking I/O belongs to detached work. Pipe readers run concurrently
/// with stdin writes so even a full diagnostic pipe cannot deadlock generation.
private final class SpeakerHelperProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func run(executable: URL, input: Data, timeout: TimeInterval) throws -> Data {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run(); self.process = process; lock.unlock() }
        catch { lock.unlock(); throw error }
        // Parent copies of the child ends must close for EOF to be observable.
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        let out = PipeCollector(), err = PipeCollector(), ioGroup = DispatchGroup()
        for (handle, collector) in [(stdout.fileHandleForReading, out), (stderr.fileHandleForReading, err)] {
            ioGroup.enter()
            DispatchQueue.global(qos: .utility).async { collector.read(handle); ioGroup.leave() }
        }
        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            ioGroup.leave()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && !isCancelled && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let timedOut = process.isRunning && !isCancelled
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit(); ioGroup.wait()
        lock.lock(); self.process = nil; lock.unlock()
        if isCancelled { throw CancellationError() }
        if timedOut { throw SpeakerCorrectionError.invalid("Speaker optimization timed out. The existing correction has been preserved.") }
        guard process.terminationStatus == 0 else {
            let diagnostic = String(data: err.data, encoding: .utf8) ?? "Unknown optimizer error"
            throw SpeakerCorrectionError.invalid("Could not generate a safe speaker correction: \(diagnostic.prefix(800))")
        }
        guard !out.overflow, !out.data.isEmpty else { throw SpeakerCorrectionError.invalid("The speaker optimizer returned invalid output.") }
        return out.data
    }
}
private final class PipeCollector: @unchecked Sendable {
    var data = Data()
    var overflow = false
    func read(_ handle: FileHandle) {
        defer { try? handle.close() }
        while let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty {
            if data.count + chunk.count <= 2 * 1024 * 1024 { data.append(chunk) } else { overflow = true }
        }
    }
}
