import CryptoKit
import Darwin
import Foundation
import CamiTuneDomain

enum NativeAssetLoadError: LocalizedError, CustomStringConvertible {
    case identity(String)
    case hashMismatch(String)
    case notRegularFile(String)
    case fileSize(String)
    case channel(String)
    case coefficientLimit
    case system(String, Int32)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .identity(let path): return "Missing or inconsistent FIR content identity: \(path)"
        case .hashMismatch(let path): return "FIR bytes differ from the requested content hash: \(path)"
        case .notRegularFile(let path): return "FIR source is not a regular file: \(path)"
        case .fileSize(let path): return "FIR source exceeds the 64 MiB snapshot limit: \(path)"
        case .channel(let path): return "FIR channel is outside the decoded asset: \(path)"
        case .coefficientLimit: return "FIR coefficients exceed native preparation limits"
        case .system(let operation, let code): return "FIR \(operation) failed with errno \(code)"
        }
    }
}

/// Worker-side acquisition through the existing WAVE parser. One immutable
/// snapshot supplies both the requested hash and decoded coefficients, even if
/// the source path is replaced or rewritten. No temporary file is created.
struct NativeAssetLoader: Sendable {
    enum Checkpoint: Sendable {
        case copiedChunk(path: String, bytes: Int)
        case verifiedSnapshot(path: String)
        case decodedFile(path: String)
    }

    // Managed Float64 WAVs at the existing 4,194,304-sample import limit are
    // below 33.6 MB. The container cap bounds metadata as well as coefficient
    // storage; oversized files reject explicitly without truncation.
    static let maximumFileBytes = 64 * 1024 * 1024
    var checkpoint: @Sendable (Checkpoint) throws -> Void = { _ in }

    func load(graph: ProcessingGraph, maximumCoefficients: Int,
              checkCancellation: @escaping @Sendable () throws -> Void) throws -> [String: NativeFIRAsset] {
        try checkCancellation()
        guard maximumCoefficients >= 0 else { throw NativeAssetLoadError.coefficientLimit }
        typealias Reference = (id: String, source: ProcessingGraph.Processor.Implementation.Convolution)
        var files: [String: [Reference]] = [:]
        for processor in graph.processors {
            guard case .convolution(let source) = processor.implementation else { continue }
            guard source.filePath.hasPrefix("/"), let hash = source.contentSHA256,
                  hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw NativeAssetLoadError.identity(source.filePath)
            }
            if let existing = files[source.filePath]?.first, existing.source.contentSHA256 != hash {
                throw NativeAssetLoadError.identity(source.filePath)
            }
            files[source.filePath, default: []].append((processor.id, source))
        }
        var result: [String: NativeFIRAsset] = [:]
        var total = 0
        for path in files.keys.sorted() {
            try checkCancellation()
            let references = files[path]!
            let snapshot = try snapshot(path: path, expectedHash: references[0].source.contentSHA256!, checkCancellation: checkCancellation)
            try checkpoint(.verifiedSnapshot(path: path))
            try checkCancellation()
            let decoded = try ImpulseResponseWAV.read(snapshot: snapshot, maximumSamples: ImpulseResponseStore.maximumTotalSamples,
                checkCancellation: checkCancellation)
            try checkpoint(.decodedFile(path: path))
            try checkCancellation()
            guard decoded.sampleRate == graph.sampleRate else {
                throw ImpulseResponseImportError.sampleRateMismatch(decoded.sampleRate, graph.sampleRate)
            }
            guard references.count <= (maximumCoefficients - total) / decoded.frameCount else {
                throw NativeAssetLoadError.coefficientLimit
            }
            for reference in references {
                guard decoded.channels.indices.contains(reference.source.channel) else {
                    throw NativeAssetLoadError.channel(path)
                }
                result[reference.id] = .init(source: reference.source, sampleRate: decoded.sampleRate,
                    coefficients: decoded.channels[reference.source.channel])
                total += decoded.frameCount
            }
        }
        try checkCancellation()
        return result
    }

    private func snapshot(path: String, expectedHash: String,
                          checkCancellation: @escaping @Sendable () throws -> Void) throws -> Data {
        // O_NONBLOCK lets the boundary reject FIFOs/devices after fstat rather
        // than waiting for a writer before learning the source is unsupported.
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw NativeAssetLoadError.system("open", errno) }
        let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? source.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw NativeAssetLoadError.system("fstat", errno) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw NativeAssetLoadError.notRegularFile(path) }
        guard metadata.st_size >= 0, metadata.st_size <= Int64(Self.maximumFileBytes) else { throw NativeAssetLoadError.fileSize(path) }
        try checkCancellation()
        var snapshot = Data()
        snapshot.reserveCapacity(Int(metadata.st_size))
        var hash = SHA256()
        var copied = 0
        while true {
            try checkCancellation()
            let chunk = try autoreleasepool {
                try source.read(upToCount: min(64 * 1024, Self.maximumFileBytes - copied + 1)) ?? Data()
            }
            if chunk.isEmpty { break }
            guard chunk.count <= Self.maximumFileBytes - copied else { throw NativeAssetLoadError.fileSize(path) }
            hash.update(data: chunk)
            snapshot.append(chunk)
            copied += chunk.count
            try checkpoint(.copiedChunk(path: path, bytes: copied))
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedHash else { throw NativeAssetLoadError.hashMismatch(path) }
        try checkCancellation()
        return snapshot
    }
}
