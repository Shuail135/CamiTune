import Foundation

/// Content-addressed source bytes plus an atomic endpoint index. Cache reads
/// and writes run on the provider actor, never on the audio or main thread.
struct SpeakerMeasurementCache: Sendable {
    struct Entry: Codable, Sendable {
        var data: Data
        var retrievedAt: Date
        var isStale = false
    }
    let directory: URL
    private func url(_ key: String) -> URL {
        directory.appendingPathComponent(SpeakerCEA2034Measurement.hash(Data(key.utf8)) + ".json")
    }
    func read(_ key: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }
    func write(_ entry: Entry, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = directory.appendingPathComponent(SpeakerCEA2034Measurement.hash(entry.data) + ".raw.json")
        if !FileManager.default.fileExists(atPath: raw.path) { try entry.data.write(to: raw, options: .atomic) }
        try JSONEncoder().encode(entry).write(to: url(key), options: .atomic)
    }
}
