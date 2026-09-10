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
    let manifest: Manifest
    private let filters: [Double: [HRIRPair]]

    init(directory: URL? = nil) throws {
        let directory = try directory ?? Self.resourceDirectory()
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1, manifest.license == "Apache-2.0", manifest.directions.count == 7,
              manifest.file == "sadie-d1.f32", manifest.rates.count == 6 else { throw LoadError.invalidAsset }
        let bytes = try Data(contentsOf: directory.appendingPathComponent(manifest.file))
        guard bytes.count <= 2_000_000,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else { throw LoadError.invalidAsset }
        var filters: [Double: [HRIRPair]] = [:]
        for rate in manifest.rates {
            guard rate.sampleRate.isFinite, (8000...384000).contains(rate.sampleRate),
                  (1...8192).contains(rate.frameCount), rate.byteOffset >= 0,
                  rate.byteOffset <= bytes.count - rate.frameCount * 7 * 2 * 4,
                  (0...rate.frameCount).contains(rate.referenceDelayFrames), filters[rate.sampleRate] == nil else { throw LoadError.invalidAsset }
            var pairs: [HRIRPair] = []
            for direction in 0..<7 {
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
            filters[rate.sampleRate] = pairs
        }
        self.manifest = manifest; self.filters = filters
    }
    func hrir(for direction: HRTFDirection, sampleRate: Double) throws -> HRIRPair {
        guard let index = manifest.directions.firstIndex(where: {
            abs($0.azimuthDegrees - direction.azimuthDegrees) < 0.01 && abs($0.elevationDegrees - direction.elevationDegrees) < 0.01
        }), let bank = filters[sampleRate] else { throw LoadError.unsupportedDirectionOrRate }
        return bank[index]
    }
    func referenceDelayFrames(sampleRate: Double) -> Int {
        manifest.rates.first { $0.sampleRate == sampleRate }?.referenceDelayFrames ?? 0
    }
    private static func resourceDirectory() throws -> URL {
#if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "SpatialAssets", withExtension: nil) { return url }
#endif
        if let url = Bundle.main.url(forResource: "SpatialAssets", withExtension: nil) { return url }
        throw LoadError.missingAsset
    }
}
