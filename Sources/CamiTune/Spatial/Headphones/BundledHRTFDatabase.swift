import CamiTuneAudio
import CamiTuneDomain
import CryptoKit
import Foundation

/// Native runtime representation compiled reproducibly from a pinned SOFA source.
/// JSON, hashing and byte conversion happen once, before the PCM writer starts.
final class BundledHRTFDatabase: HRTFDatabase {
    struct Manifest: Decodable {
        struct Direction: Decodable { let role: String; let azimuthDegrees: Float; let elevationDegrees: Float }
        struct Rate: Decodable { let sampleRate: Double; let frameCount: Int; let byteOffset: Int; let referenceDelayFrames: Int }
        let version: Int; let id: String; let name: String; let license: String
        let file: String; let sha256: String; let directions: [Direction]; let rates: [Rate]
    }
    enum LoadError: Error { case missingAsset, invalidAsset, unsupportedDirectionOrRate }
    static let shared: BundledHRTFDatabase? = try? BundledHRTFDatabase()
    var profileName: String { manifest.name }
    var supportedSampleRates: [Double] { manifest.rates.map(\.sampleRate) }
    let manifest: Manifest
    private let filters: [Double: DirectionalHRTFGrid]
    private let roomFilters: [Double: [HRIRPair]]

    init(directory: URL? = nil) throws {
        let directory = try directory ?? Self.resourceDirectory()
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 2, manifest.license == "Apache-2.0", manifest.directions.count == 468,
              manifest.file == "sadie-d1.f32", manifest.rates.count == 6 else { throw LoadError.invalidAsset }
        for (index, direction) in manifest.directions.enumerated() {
            guard direction.azimuthDegrees == Float(index % 36 * 10 - 180),
                  direction.elevationDegrees == Float(index / 36 * 15 - 90) else { throw LoadError.invalidAsset }
        }
        let bytes = try Data(contentsOf: directory.appendingPathComponent(manifest.file))
        guard bytes.count <= 16_000_000,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else { throw LoadError.invalidAsset }
        var filters: [Double: DirectionalHRTFGrid] = [:]
        for rate in manifest.rates {
            guard rate.sampleRate.isFinite, (8000...384000).contains(rate.sampleRate),
                  (1...8192).contains(rate.frameCount), rate.byteOffset >= 0,
                  rate.byteOffset <= bytes.count - rate.frameCount * 468 * 2 * 4,
                  (0...rate.frameCount).contains(rate.referenceDelayFrames), filters[rate.sampleRate] == nil else { throw LoadError.invalidAsset }
            var pairs: [HRIRPair] = []
            for direction in 0..<468 {
                let start = rate.byteOffset + direction * rate.frameCount * 2 * 4
                func ear(_ index: Int) throws -> [Float] {
                    let values = bytes.withUnsafeBytes { buffer -> [Float] in
                        (0..<rate.frameCount).map { i in
                            Float(bitPattern: buffer.loadUnaligned(fromByteOffset: start + (index * rate.frameCount + i) * 4, as: UInt32.self).littleEndian)
                        }
                    }
                    guard values.allSatisfy(\.isFinite) else { throw LoadError.invalidAsset }
                    return values
                }
                pairs.append(HRIRPair(left: try ear(0), right: try ear(1)))
            }
            filters[rate.sampleRate] = try DirectionalHRTFGrid(pairs: pairs)
        }
        self.manifest = manifest; self.filters = filters
        roomFilters = try Self.loadRoom(directory: directory, rates: manifest.rates)
    }
    func hrir(for direction: HRTFDirection, sampleRate: Double) throws -> HRIRPair {
        guard let bank = filters[sampleRate] else { throw LoadError.unsupportedDirectionOrRate }
        return try bank.hrir(azimuth: direction.azimuthDegrees, elevation: direction.elevationDegrees)
    }

    func referenceDelayFrames(sampleRate: Double) -> Int {
        manifest.rates.first { $0.sampleRate == sampleRate }?.referenceDelayFrames ?? 0
    }
    func roomResponse(for role: ChannelRole, sampleRate: Double) throws -> HRIRPair {
        guard let index = VirtualSpeakerScene.roles.firstIndex(of: role), let bank = roomFilters[sampleRate] else {
            throw PersonalSpatialError.measuredRoomUnavailable
        }
        return bank[index]
    }

    private static func loadRoom(directory: URL, rates: [Manifest.Rate]) throws -> [Double: [HRIRPair]] {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("studio-manifest.json")))
        guard manifest.version == 1, manifest.id == "sadie-ii-d1-genelec-room", manifest.license == "Apache-2.0",
              manifest.file == "sadie-studio.f32", manifest.directions.count == 7, manifest.rates.count == rates.count,
              manifest.directions.map(\.azimuthDegrees) == [-45, 45, 0, -90, 90, -135, 135] else { throw LoadError.invalidAsset }
        let bytes = try Data(contentsOf: directory.appendingPathComponent(manifest.file))
        guard bytes.count <= 16_000_000,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else { throw LoadError.invalidAsset }
        var result: [Double: [HRIRPair]] = [:]
        var expectedOffset = 0
        for (rate, reference) in zip(manifest.rates, rates) {
            guard rate.sampleRate == reference.sampleRate, rate.referenceDelayFrames == reference.referenceDelayFrames,
                  (1...131072).contains(rate.frameCount), rate.byteOffset == expectedOffset,
                  rate.frameCount * 7 * 2 * 4 <= bytes.count - expectedOffset else { throw LoadError.invalidAsset }
            result[rate.sampleRate] = try (0..<7).map { direction in
                func ear(_ ear: Int) throws -> [Float] {
                    let start = rate.byteOffset + (direction * 2 + ear) * rate.frameCount * 4
                    let values = bytes.withUnsafeBytes { buffer in
                        (0..<rate.frameCount).map { Float(bitPattern: buffer.loadUnaligned(fromByteOffset: start + $0 * 4, as: UInt32.self).littleEndian) }
                    }
                    guard values.allSatisfy(\.isFinite) else { throw LoadError.invalidAsset }
                    return values
                }
                return .init(left: try ear(0), right: try ear(1))
            }
            expectedOffset += rate.frameCount * 7 * 2 * 4
        }
        guard expectedOffset == bytes.count else { throw LoadError.invalidAsset }
        return result
    }
    private static func resourceDirectory() throws -> URL {
#if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "SpatialAssets", withExtension: nil) { return url }
#endif
        if let url = Bundle.main.url(forResource: "SpatialAssets", withExtension: nil) { return url }
        throw LoadError.missingAsset
    }
}
