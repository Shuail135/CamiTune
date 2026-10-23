import CamiTuneDomain
import Foundation
import Darwin

enum PluginArchitecture: String, Sendable {
    case arm64, x86_64
    static var native: Self {
#if arch(arm64)
        return .arm64
#else
        return .x86_64
#endif
    }
    var cpuType: UInt32 { self == .arm64 ? 0x0100000c : 0x01000007 }

    /// Read only the Mach-O header. No bundle executable is loaded to choose a helper.
    static func available(in executable: URL) -> Set<PluginArchitecture> {
        guard let file = try? FileHandle(forReadingFrom: executable) else { return [] }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 4096), data.count >= 8 else { return [] }
        return architectures(in: data)
    }
    static func architectures(in data: Data) -> Set<PluginArchitecture> {
        func word(_ offset: Int, little: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[offset + (little ? 3 - $1 : $1)]) }
        }
        guard let magic = word(0) else { return [] }
        let types: [UInt32]
        switch magic {
        case 0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca:
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
            guard let count = word(4, little: little), count <= 64, 8 + Int(count) * stride <= data.count else { return [] }
            types = (0..<Int(count)).compactMap { word(8 + $0 * stride, little: little) }
        case 0xfeedfacf, 0xfeedface: types = word(4).map { [$0] } ?? []
        case 0xcffaedfe, 0xcefaedfe: types = word(4, little: true).map { [$0] } ?? []
        default: return []
        }
        return Set([Self.arm64, .x86_64].filter { types.contains($0.cpuType) })
    }
    static func preferred(forVST3 url: URL) -> Self {
        guard let executable = Bundle(url: url)?.executableURL else { return native }
        let choices = available(in: executable)
        if choices.contains(native) { return native }
        return choices.contains(.x86_64) ? .x86_64 : choices.contains(.arm64) ? .arm64 : native
    }
    static func groups(for slots: [AudioPluginSlot]) -> [(architecture: Self, slots: [AudioPluginSlot])] {
        var result: [(architecture: Self, slots: [AudioPluginSlot])] = []
        for slot in slots {
            let architecture = slot.plugin.format == .vst3 ? preferred(forVST3: URL(fileURLWithPath: slot.plugin.location)) : native
            if result.last?.architecture == architecture { result[result.count - 1].slots.append(slot) }
            else { result.append((architecture, [slot])) }
        }
        return result
    }
}
