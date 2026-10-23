import Foundation

package enum AudioPluginFormat: String, Codable, CaseIterable, Sendable {
    case audioUnit = "AU", vst3 = "VST3"
}
package enum AudioPluginKind: String, Codable, Sendable { case effect, instrument }

package struct PluginSidechainSource: Codable, Hashable, Sendable {
    package enum Kind: String, Codable, Sendable { case application, audioInput }
    package var kind: Kind
    package var id: String
    package var name: String
    /// Zero-based hardware channel pair; app sends use their first stereo pair.
    package var channelOffset: Int
    package init(kind: Kind, id: String, name: String, channelOffset: Int = 0) {
        self.kind = kind; self.id = id; self.name = name; self.channelOffset = channelOffset
    }
}

/// Stable component identity, independent of the display name or scan order.
package struct AudioPluginDescriptor: Codable, Hashable, Identifiable, Sendable {
    package var id: String
    package var name: String
    package var manufacturer: String
    package var format: AudioPluginFormat
    package var location: String
    package var componentType: UInt32 = 0
    package var componentSubtype: UInt32 = 0
    package var componentManufacturer: UInt32 = 0
    package var kind: AudioPluginKind?
    package var isInstrument: Bool {
        kind == .instrument || (format == .audioUnit && (componentType == 0x61756d75 || componentType == 0x6175676e))
    }

    package init(id: String, name: String, manufacturer: String, format: AudioPluginFormat,
                 location: String = "", componentType: UInt32 = 0,
                 componentSubtype: UInt32 = 0, componentManufacturer: UInt32 = 0, kind: AudioPluginKind? = nil) {
        self.id = id; self.name = name; self.manufacturer = manufacturer
        self.format = format; self.location = location; self.componentType = componentType
        self.componentSubtype = componentSubtype; self.componentManufacturer = componentManufacturer
        self.kind = kind
    }
}

package struct AudioPluginSlot: Codable, Hashable, Identifiable, Sendable {
    package var id: UUID
    package var plugin: AudioPluginDescriptor
    package var isEnabled: Bool
    /// Opaque AU property-list or VST3 component/controller state, encoded by the helper.
    package var state: Data?
    package var sidechain: PluginSidechainSource?
    /// nil selects the plug-in's first auxiliary input.
    package var sidechainBus: Int?

    package init(id: UUID = UUID(), plugin: AudioPluginDescriptor, isEnabled: Bool = true, state: Data? = nil,
                 sidechain: PluginSidechainSource? = nil, sidechainBus: Int? = nil) {
        self.id = id; self.plugin = plugin; self.isEnabled = isEnabled; self.state = state
        self.sidechain = sidechain; self.sidechainBus = sidechainBus
    }
}

package struct PluginRack: Codable, Hashable, Sendable {
    package static let maximumSlots = 16
    package static let maximumStateBytes = 4 * 1024 * 1024
    package var isEnabled: Bool
    package var slots: [AudioPluginSlot]
    package var midi: PluginMIDIConfiguration
    package init(isEnabled: Bool = false, slots: [AudioPluginSlot] = [], midi: PluginMIDIConfiguration = .init()) {
        self.isEnabled = isEnabled; self.slots = slots; self.midi = midi
    }
    private enum CodingKeys: String, CodingKey { case isEnabled, slots, midi }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        slots = try values.decode([AudioPluginSlot].self, forKey: .slots)
        midi = try values.decodeIfPresent(PluginMIDIConfiguration.self, forKey: .midi) ?? .init()
    }
    /// MIDI edits change control routing, never the prepared audio processors.
    package var audioConfiguration: PluginRack { var copy = self; copy.midi = .init(); return copy }
    package var activeSlots: [AudioPluginSlot] { isEnabled ? slots.filter(\.isEnabled) : [] }
    package var isProcessing: Bool { !activeSlots.isEmpty }
    package func validate() throws {
        try midi.validate()
        guard slots.count <= Self.maximumSlots, Set(slots.map(\.id)).count == slots.count,
              slots.allSatisfy({ !$0.plugin.id.isEmpty && !$0.plugin.name.isEmpty
                  && ($0.state?.count ?? 0) <= Self.maximumStateBytes
                  && ($0.sidechainBus == nil || (0..<64).contains($0.sidechainBus!))
                  && ($0.sidechain == nil || (!$0.sidechain!.id.isEmpty && (0..<32).contains($0.sidechain!.channelOffset))) }) else { throw PluginRackError.invalidRack }
        for slot in slots where slot.plugin.format == .vst3 {
            guard slot.plugin.id.count == 32, slot.plugin.id.allSatisfy(\.isHexDigit),
                  slot.plugin.location.hasPrefix("/"), slot.plugin.location.lowercased().hasSuffix(".vst3") else {
                throw PluginRackError.invalidRack
            }
        }
    }
}

package struct PluginMIDIConfiguration: Codable, Hashable, Sendable {
    package var isEnabled = false
    package var sourceID: Int32? = nil
    /// nil accepts all 16 MIDI channels; this is independent of audio channels.
    package var channel: Int? = nil
    /// nil ignores program changes; otherwise only this slot receives them.
    package var programChangeSlotID: UUID? = nil
    package var mappings: [PluginMIDIMapping] = []
    package init() {}
    package func validate() throws {
        guard channel == nil || (1...16).contains(channel!), mappings.count <= 256,
              Set(mappings.map(\.id)).count == mappings.count,
              mappings.allSatisfy({ (1...16).contains($0.channel) && (0...($0.input == .note ? 127 : 119)).contains($0.controller)
                  && $0.lower.isFinite && $0.upper.isFinite && (0...1).contains($0.lower) && (0...1).contains($0.upper) }) else {
            throw PluginRackError.invalidRack
        }
    }
}

package enum PluginMIDIInput: String, Codable, CaseIterable, Sendable {
    case controller, note
}

package enum PluginMIDIControlMode: String, Codable, CaseIterable, Sendable {
    case knob, button, toggle, velocity
    package var title: String {
        switch self {
        case .knob: return "Knob / Fader"
        case .button: return "Momentary Button"
        case .toggle: return "Toggle Button"
        case .velocity: return "Note Velocity"
        }
    }
}

package enum PluginMIDIResponseCurve: String, Codable, CaseIterable, Sendable {
    case linear, soft, hard, sCurve
    package var title: String {
        switch self {
        case .linear: return "Linear"
        case .soft: return "Soft"
        case .hard: return "Hard"
        case .sCurve: return "S-Curve"
        }
    }
    package func transform(_ input: Double) -> Double {
        let x = min(1, max(0, input))
        switch self {
        case .linear: return x
        case .soft: return sqrt(x)
        case .hard: return x * x
        case .sCurve: return x * x * (3 - 2 * x)
        }
    }
}

package struct PluginMIDIMapping: Codable, Hashable, Identifiable, Sendable {
    package var id: UUID
    package var slotID: UUID
    package var parameterID: UInt64
    package var parameterName: String
    package var sourceID: Int32
    package var sourceName: String
    package var channel: Int
    package var controller: Int
    package var lower: Double
    package var upper: Double
    package var pickup: Bool
    package var input: PluginMIDIInput
    package var mode: PluginMIDIControlMode
    package var curve: PluginMIDIResponseCurve

    package func output(at inputValue: Double) -> Double {
        let value = mode == .button || mode == .toggle ? (inputValue >= 0.5 ? 1.0 : 0.0) : curve.transform(inputValue)
        return lower + value * (upper - lower)
    }

    private enum CodingKeys: String, CodingKey {
        case id, slotID, parameterID, parameterName, sourceID, sourceName, channel, controller, lower, upper, pickup, input, mode, curve
    }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        slotID = try values.decode(UUID.self, forKey: .slotID)
        parameterID = try values.decode(UInt64.self, forKey: .parameterID)
        parameterName = try values.decode(String.self, forKey: .parameterName)
        sourceID = try values.decode(Int32.self, forKey: .sourceID)
        sourceName = try values.decode(String.self, forKey: .sourceName)
        channel = try values.decode(Int.self, forKey: .channel)
        controller = try values.decode(Int.self, forKey: .controller)
        lower = try values.decode(Double.self, forKey: .lower)
        upper = try values.decode(Double.self, forKey: .upper)
        pickup = try values.decode(Bool.self, forKey: .pickup)
        input = try values.decodeIfPresent(PluginMIDIInput.self, forKey: .input) ?? .controller
        mode = try values.decodeIfPresent(PluginMIDIControlMode.self, forKey: .mode) ?? .knob
        curve = try values.decodeIfPresent(PluginMIDIResponseCurve.self, forKey: .curve) ?? .linear
    }
    package init(id: UUID = UUID(), slotID: UUID, parameterID: UInt64, parameterName: String,
                 sourceID: Int32, sourceName: String, channel: Int, controller: Int,
                 lower: Double = 0, upper: Double = 1, pickup: Bool = true,
                 input: PluginMIDIInput = .controller, mode: PluginMIDIControlMode = .knob, curve: PluginMIDIResponseCurve = .linear) {
        self.id = id; self.slotID = slotID; self.parameterID = parameterID; self.parameterName = parameterName
        self.sourceID = sourceID; self.sourceName = sourceName; self.channel = channel; self.controller = controller
        self.lower = lower; self.upper = upper; self.pickup = pickup
        self.input = input; self.mode = mode; self.curve = curve
    }
}

package enum PluginRackError: LocalizedError {
    case invalidRack
    package var errorDescription: String? {
        switch self {
        case .invalidRack: return "The plug-in rack contains invalid or oversized settings. Remove the affected plug-in and add it again."
        }
    }
}
