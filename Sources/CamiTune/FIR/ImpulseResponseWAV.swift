import AVFoundation
import Foundation

/// Reads coefficient samples without depending on AVAudioFile's frame estimates.
/// FIRs must retain their leading silence, final tap, channel order and gain.
struct ImpulseResponseWAV {
    let sampleRate: Int
    let channels: [[Double]]
    var frameCount: Int { channels[0].count }

    static func read(at url: URL, maximumSamples: Int) throws -> Self {
        do {
            let reader = try WAVChunks(url: url)
            if let decoded = try reader.decode(maximumSamples: maximumSamples) { return decoded }
            // Compressed WAVE codecs supported by macOS are converted to lossless
            // coefficients on import, never passed to CamillaDSP's PCM-only reader.
            return try readWithCoreAudio(at: url, maximumSamples: maximumSamples)
        } catch let error as ImpulseResponseImportError { throw error }
        catch { throw ImpulseResponseImportError.unreadableWAV(error.localizedDescription) }
    }

    /// A canonical little-endian float64 WAVE keeps integer/float precision and
    /// strips container quirks and metadata unsupported by the DSP's WAV reader.
    func encoded() throws -> Data {
        guard channels.count <= Int(UInt16.max) / 8,
              UInt64(sampleRate) * UInt64(channels.count * 8) <= UInt32.max else {
            throw ImpulseResponseImportError.unreadableWAV("The WAV format exceeds the managed coefficient format's limits.")
        }
        let bytes = frameCount * channels.count * 8
        var result = Data(capacity: 58 + bytes)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        result.append(contentsOf: "RIFF".utf8); append(UInt32(50 + bytes))
        result.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(18))
        append(UInt16(3)); append(UInt16(channels.count)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels.count * 8)); append(UInt16(channels.count * 8))
        append(UInt16(64)); append(UInt16(0))
        result.append(contentsOf: "fact".utf8); append(UInt32(4)); append(UInt32(frameCount))
        result.append(contentsOf: "data".utf8); append(UInt32(bytes))
        for frame in 0..<frameCount {
            for channel in channels { append(channel[frame].bitPattern) }
        }
        return result
    }

    private static func readWithCoreAudio(at url: URL, maximumSamples: Int) throws -> Self {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw ImpulseResponseImportError.unreadableWAV("macOS could not decode this WAV encoding. \(error.localizedDescription)") }
        let format = file.processingFormat
        let count = Int(format.channelCount)
        let rate = format.sampleRate
        guard rate.isFinite, rate > 0, rate <= Double(UInt32.max), rate.rounded() == rate else {
            throw ImpulseResponseImportError.invalidSampleRate(rate)
        }
        guard count > 0 else { throw ImpulseResponseImportError.unreadableWAV("The WAV has no channels.") }
        guard count <= maximumSamples, file.length <= Int64(maximumSamples / count) else {
            throw ImpulseResponseImportError.tooLarge(maximumSamples)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw ImpulseResponseImportError.couldNotAllocate
        }
        var channels = [[Double]](repeating: [], count: count)
        var frames = 0
        while true {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            let read = Int(buffer.frameLength)
            if read == 0 { break }
            guard read <= maximumSamples / count - frames else { throw ImpulseResponseImportError.tooLarge(maximumSamples) }
            guard let samples = buffer.floatChannelData else {
                throw ImpulseResponseImportError.unreadableWAV("The decoder did not return PCM samples.")
            }
            for channel in 0..<count {
                channels[channel].append(contentsOf: UnsafeBufferPointer(start: samples[channel], count: read).map(Double.init))
            }
            frames += read
        }
        guard frames > 0 else { throw ImpulseResponseImportError.emptyWAV }
        if file.length > frames { throw ImpulseResponseImportError.incompleteWAV(expected: Int(file.length), actual: frames) }
        return .init(sampleRate: Int(rate), channels: channels)
    }
}

private final class WAVChunks {
    private let file: FileHandle
    private let fileSize: UInt64
    private var bigEndian = false

    init(url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        fileSize = try file.seekToEnd()
    }
    deinit { try? file.close() }

    private func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else {
            throw invalid("A WAV chunk is truncated.")
        }
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw invalid("A WAV chunk is truncated.") }
        return data
    }

    private func integer(_ data: Data, _ offset: Int, _ bytes: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<bytes {
            let shift = (bigEndian ? bytes - i - 1 : i) * 8
            value |= UInt64(data[offset + i]) << shift
        }
        return value
    }

    private func invalid(_ reason: String) -> ImpulseResponseImportError { .unreadableWAV(reason) }

    func decode(maximumSamples: Int) throws -> ImpulseResponseWAV? {
        let header = try read(0, 12)
        let container = String(decoding: header.prefix(4), as: UTF8.self)
        if container == "riff" { return try decodeWave64(maximumSamples: maximumSamples) }
        guard ["RIFF", "RIFX", "RF64", "BW64"].contains(container),
              String(decoding: header[8..<12], as: UTF8.self) == "WAVE" else {
            throw invalid("The file does not contain a WAVE header.")
        }
        bigEndian = container == "RIFX"
        let extended = container == "RF64" || container == "BW64"
        var end = extended ? fileSize : integer(header, 4, 4) + 8
        guard end >= 12, end <= fileSize else { throw invalid("The RIFF size exceeds the available WAV data.") }
        var offset: UInt64 = 12
        var format: Data?
        var dataChunks: [(UInt64, UInt64)] = []
        var dataSize64: UInt64?
        var largeSizes: [String: [UInt64]] = [:]
        var needsCoreAudio = false
        while offset < end {
            guard end - offset >= 8 else { throw invalid("The WAV ends inside a chunk header.") }
            let chunk = try read(offset, 8)
            let tag = String(decoding: chunk.prefix(4), as: UTF8.self)
            var size = integer(chunk, 4, 4)
            let body = offset + 8
            if size == UInt32.max, extended {
                if tag == "data", let first = dataSize64 {
                    size = first; dataSize64 = nil
                } else if var sizes = largeSizes[tag], !sizes.isEmpty {
                    size = sizes.removeFirst(); largeSizes[tag] = sizes
                } else { throw invalid("The RF64 chunk is missing its 64-bit size.") }
            }
            guard size <= end - body else { throw invalid("The \(tag) chunk is truncated.") }
            switch tag {
            case "ds64" where extended:
                guard size >= 28 else { throw invalid("Invalid RF64 size table.") }
                let sizes = try read(body, 28)
                let riffSize = integer(sizes, 0, 8)
                guard riffSize >= 4, riffSize <= fileSize - 8, body + size <= riffSize + 8 else {
                    throw invalid("Invalid RF64 container size.")
                }
                end = riffSize + 8; dataSize64 = integer(sizes, 8, 8)
                let entries = integer(sizes, 24, 4)
                guard entries <= (size - 28) / 12 else { throw invalid("Truncated RF64 size table.") }
                for index in 0..<entries {
                    let entry = try read(body + 28 + index * 12, 12)
                    let name = String(decoding: entry.prefix(4), as: UTF8.self)
                    largeSizes[name, default: []].append(integer(entry, 4, 8))
                }
            case "fmt ":
                guard format == nil, size >= 16 else { throw invalid("Missing or duplicate WAV format information.") }
                format = try read(body, Int(min(size, 40)))
            case "data": dataChunks.append((body, size))
            case "LIST":
                if size >= 4, try read(body, 4) == Data("wavl".utf8) { needsCoreAudio = true }
            default: break // Metadata chunks can appear before or after the samples.
            }
            offset = body + size
            if size % 2 != 0, offset < end { offset += 1 }
        }
        return try decodeSamples(format: format, dataChunks: dataChunks,
                                 maximumSamples: maximumSamples, needsCoreAudio: needsCoreAudio)
    }

    private func decodeWave64(maximumSamples: Int) throws -> ImpulseResponseWAV? {
        let header = try read(0, 40)
        let riffSuffix: [UInt8] = [0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04, 0xc1, 0, 0]
        let waveSuffix: [UInt8] = [0xf3, 0xac, 0xd3, 0x11, 0x8c, 0xd1, 0, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a]
        guard Array(header[4..<16]) == riffSuffix, Array(header[28..<40]) == waveSuffix,
              String(decoding: header[24..<28], as: UTF8.self) == "wave" else { throw invalid("Invalid Wave64 header.") }
        let end = integer(header, 16, 8)
        guard end >= 40, end <= fileSize else { throw invalid("Invalid Wave64 size.") }
        var offset: UInt64 = 40
        var format: Data?
        var dataChunks: [(UInt64, UInt64)] = []
        while offset < end {
            guard end - offset >= 24 else { throw invalid("Truncated Wave64 chunk header.") }
            let header = try read(offset, 24)
            let size = integer(header, 16, 8)
            guard size >= 24, size <= end - offset else { throw invalid("Truncated Wave64 chunk.") }
            if Array(header[4..<16]) == waveSuffix {
                let tag = String(decoding: header.prefix(4), as: UTF8.self)
                if tag == "fmt " {
                    guard format == nil, size >= 40 else { throw invalid("Invalid Wave64 format.") }
                    format = try read(offset + 24, Int(min(size - 24, 40)))
                } else if tag == "data" { dataChunks.append((offset + 24, size - 24)) }
            }
            offset += size
            let padding = (8 - size % 8) % 8
            if offset < end {
                guard padding <= end - offset else { throw invalid("Truncated Wave64 padding.") }
                offset += padding
            }
        }
        return try decodeSamples(format: format, dataChunks: dataChunks, maximumSamples: maximumSamples)
    }

    private func decodeSamples(format: Data?, dataChunks: [(UInt64, UInt64)], maximumSamples: Int,
                               needsCoreAudio: Bool = false) throws -> ImpulseResponseWAV? {
        guard let format else { throw invalid("The WAV has no format chunk.") }
        var encoding = integer(format, 0, 2)
        let channelCount = Int(integer(format, 2, 2))
        let sampleRate = Int(integer(format, 4, 4))
        let blockSize = Int(integer(format, 12, 2))
        let bits = Int(integer(format, 14, 2))
        var validBits = bits
        if encoding == 0xfffe {
            guard format.count >= 40, integer(format, 16, 2) >= 22 else { throw invalid("Truncated extensible WAV format.") }
            validBits = Int(integer(format, 18, 2))
            if validBits == 0 { validBits = bits }
            let guidTail: [UInt8] = [0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]
            guard integer(format, 28, 2) == 0, integer(format, 30, 2) == 16,
                  Array(format[32..<40]) == guidTail else { return nil }
            encoding = integer(format, 24, 4)
        }
        guard sampleRate > 0 else { throw ImpulseResponseImportError.invalidSampleRate(Double(sampleRate)) }
        guard channelCount > 0, blockSize > 0 else { throw invalid("Invalid WAV channel count or block size.") }
        if needsCoreAudio || ![1, 3, 6, 7].contains(encoding) { return nil }
        guard !dataChunks.isEmpty else { throw invalid("The WAV has no audio data chunk.") }
        guard blockSize % channelCount == 0 else { throw invalid("Invalid PCM frame size.") }
        let sampleBytes = blockSize / channelCount
        guard (1...8).contains(sampleBytes), bits > 0, bits <= sampleBytes * 8,
              validBits > 0, validBits <= bits else { throw invalid("Invalid PCM sample width.") }
        if [6, 7].contains(encoding), (bits != 8 || sampleBytes != 1) { throw invalid("Invalid G.711 sample width.") }
        if encoding == 3, !((bits == 32 || bits == 64) && sampleBytes * 8 == bits) {
            return nil
        }
        var frames = 0
        for (_, size) in dataChunks {
            guard size % UInt64(blockSize) == 0 else { throw invalid("The WAV ends inside an audio frame.") }
            let count = size / UInt64(blockSize)
            guard count <= UInt64(maximumSamples / channelCount - frames) else {
                throw ImpulseResponseImportError.tooLarge(maximumSamples)
            }
            frames += Int(count)
        }
        guard frames > 0 else { throw ImpulseResponseImportError.emptyWAV }
        var channels = [[Double]](repeating: [Double](repeating: 0, count: frames), count: channelCount)
        let scale = pow(2, Double(validBits - 1))
        var frame = 0
        for (start, size) in dataChunks {
            var position = start
            while position < start + size {
                let count = Int(min(UInt64(max(blockSize, 65536 / blockSize * blockSize)), start + size - position))
                let samples = try read(position, count)
                for base in stride(from: 0, to: count, by: blockSize) {
                    for channel in 0..<channelCount {
                        let raw = integer(samples, base + channel * sampleBytes, sampleBytes)
                        let value: Double
                        if encoding == 3 {
                            value = bits == 32 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw)
                        } else if encoding == 7 {
                            let code = Int(raw) ^ 0xff
                            let magnitude = (((code & 15) * 8 + 132) << ((code >> 4) & 7)) - 132
                            value = Double(code & 128 == 0 ? magnitude : -magnitude) / 32768
                        } else if encoding == 6 {
                            let code = Int(raw) ^ 0x55
                            let exponent = (code >> 4) & 7
                            let magnitude = exponent == 0 ? (code & 15) * 16 + 8
                                : ((code & 15) * 16 + 264) << (exponent - 1)
                            value = Double(code & 128 != 0 ? magnitude : -magnitude) / 32768
                        } else if sampleBytes == 1 {
                            let shift = 8 - validBits
                            value = Double(Int(raw >> shift) - (1 << (validBits - 1))) / scale
                        } else {
                            // PCM valid bits are left-aligned, including 24-in-32.
                            let shift = 64 - sampleBytes * 8
                            let signed = Int64(bitPattern: raw << shift) >> (64 - validBits)
                            value = Double(signed) / scale
                        }
                        guard value.isFinite else { throw ImpulseResponseImportError.nonFiniteSamples(channel) }
                        channels[channel][frame] = value
                    }
                    frame += 1
                }
                position += UInt64(count)
            }
        }
        return .init(sampleRate: sampleRate, channels: channels)
    }
}
