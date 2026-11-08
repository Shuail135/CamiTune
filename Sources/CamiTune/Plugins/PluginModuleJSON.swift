import Foundation
import CamiTuneDomain

/// Vendor manifests are bounded data, decoded on catalog workers, never on audio callbacks.
enum PluginModuleJSON {
    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.propertyListReadCorrupt) }
        return try JSONDecoder().decode(type, from: JSON5.normalizedData(data))
    }
}
