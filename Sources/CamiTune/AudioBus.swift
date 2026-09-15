import Foundation

struct AudioBusID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

struct AudioBus: Codable, Hashable, Sendable, Identifiable {
    let id: AudioBusID
    let name: String
    let format: AudioFormatDescriptor

    func validate() throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioFormatError.emptyBusID
        }
        try format.validate()
    }
}
