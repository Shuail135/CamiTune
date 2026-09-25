import Foundation

package struct AudioBusID: RawRepresentable, Codable, Hashable, Sendable {
    package init(rawValue: String) { self.rawValue = rawValue }

    package let rawValue: String
}

package struct AudioBus: Codable, Hashable, Sendable, Identifiable {
    package init(id: AudioBusID, name: String, format: AudioFormatDescriptor) { self.id = id; self.name = name; self.format = format }

    package let id: AudioBusID
    package let name: String
    package let format: AudioFormatDescriptor

    package func validate() throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioFormatError.emptyBusID
        }
        try format.validate()
    }
}
