import Foundation

/// Stable within a compiled plan. Role and display-name edits do not change identity.
package struct AudioChannelID: RawRepresentable, Codable, Hashable, Sendable {
    package init(rawValue: String) { self.rawValue = rawValue }

    package let rawValue: String

    package static func source(_ index: Int) -> Self {
        Self(rawValue: "source:\(index)")
    }

    package static func physical(_ output: PhysicalOutputID) -> Self {
        Self(rawValue: "physical:\(output.id)")
    }

    package static func hardware(_ output: PhysicalOutputID) -> Self {
        Self(rawValue: "hardware:\(output.id)")
    }
}

package enum AudioChannelKind: String, Codable, Hashable, Sendable {
    case source
    case internalBus
    case physicalEndpoint
    case hardwareSlot
}

package struct AudioChannelDescriptor: Codable, Hashable, Sendable, Identifiable {
    package let id: AudioChannelID
    package let role: ChannelRole?
    package let label: String?
    package let kind: AudioChannelKind
    package let physicalOutputID: PhysicalOutputID?

    package init(id: AudioChannelID, role: ChannelRole? = nil, label: String? = nil,
         kind: AudioChannelKind, physicalOutputID: PhysicalOutputID? = nil) {
        self.id = id
        self.role = role
        self.label = label
        self.kind = kind
        self.physicalOutputID = physicalOutputID
    }
}

package enum AudioFormatError: Error, Equatable {
    case invalidSampleRate(Int)
    case invalidChannelCount(Int)
    case emptyChannelID
    case duplicateChannelID(AudioChannelID)
    case missingPhysicalOutput(AudioChannelID)
    case unexpectedPhysicalOutput(AudioChannelID)
    case duplicatePhysicalOutput(PhysicalOutputID)
    case emptyBusID
}

/// An ordered bus format, independent of transport capacity and hardware width.
/// Like SpeakerTopology, values must be validated after decoding and before use.
package struct AudioFormatDescriptor: Codable, Hashable, Sendable {
    package init(sampleRate: Int, channels: [AudioChannelDescriptor]) { self.sampleRate = sampleRate; self.channels = channels }

    package let sampleRate: Int
    package let channels: [AudioChannelDescriptor]

    package var channelCount: Int { channels.count }

    /// Ordered signal identity. UI labels never change stream compatibility.
    package var signalSignature: Self {
        .init(sampleRate: sampleRate, channels: channels.map {
            .init(id: $0.id, role: $0.role, kind: $0.kind, physicalOutputID: $0.physicalOutputID)
        })
    }

    package func validate() throws {
        guard sampleRate > 0 else { throw AudioFormatError.invalidSampleRate(sampleRate) }
        guard !channels.isEmpty else { throw AudioFormatError.invalidChannelCount(0) }
        // Internal expansion (e.g. split filter paths) may exceed hardware capacity.
        if channels.contains(where: { $0.kind != .internalBus }),
           channelCount > SpeakerTopology.maximumOutputChannels {
            throw AudioFormatError.invalidChannelCount(channelCount)
        }
        var ids = Set<AudioChannelID>()
        var outputs = Set<PhysicalOutputID>()
        for channel in channels {
            guard !channel.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AudioFormatError.emptyChannelID
            }
            guard ids.insert(channel.id).inserted else {
                throw AudioFormatError.duplicateChannelID(channel.id)
            }
            switch channel.kind {
            case .physicalEndpoint, .hardwareSlot:
                guard let output = channel.physicalOutputID else {
                    throw AudioFormatError.missingPhysicalOutput(channel.id)
                }
                try output.validate()
                guard outputs.insert(output).inserted else {
                    throw AudioFormatError.duplicatePhysicalOutput(output)
                }
            case .source, .internalBus:
                guard channel.physicalOutputID == nil else {
                    throw AudioFormatError.unexpectedPhysicalOutput(channel.id)
                }
            }
        }
    }

    /// Preserve the supplied channel order, including unknown/discrete roles.
    package static func source(sampleRate: Int, layout: LPCMChannelLayout) throws -> Self {
        let format = Self(sampleRate: sampleRate, channels: layout.roles.enumerated().map {
            AudioChannelDescriptor(id: .source($0.offset), role: $0.element, kind: .source)
        })
        try format.validate()
        return format
    }

    /// The caller supplies the enabled endpoints in compiled bus order. Sparse
    /// physical indices stay attached to their identities rather than becoming bus indices.
    package static func physicalEndpoints(sampleRate: Int, endpoints: [SpeakerEndpoint]) throws -> Self {
        let format = Self(sampleRate: sampleRate, channels: endpoints.map {
            AudioChannelDescriptor(id: .physical($0.id), role: $0.role, label: $0.displayName,
                                   kind: .physicalEndpoint, physicalOutputID: $0.id)
        })
        try format.validate()
        return format
    }

    /// Full hardware width, including unused slots. Speaker semantics belong to
    /// the endpoint bus and are deliberately not inferred from a channel index.
    package static func hardwareOutputs(sampleRate: Int, deviceUID: String, channelCount: Int) throws -> Self {
        guard (1...SpeakerTopology.maximumOutputChannels).contains(channelCount) else {
            throw AudioFormatError.invalidChannelCount(channelCount)
        }
        let format = Self(sampleRate: sampleRate, channels: (0..<channelCount).map { index in
            let output = PhysicalOutputID(deviceUID: deviceUID, channelIndex: index)
            return AudioChannelDescriptor(id: .hardware(output), kind: .hardwareSlot,
                                          physicalOutputID: output)
        })
        try format.validate()
        return format
    }
}
