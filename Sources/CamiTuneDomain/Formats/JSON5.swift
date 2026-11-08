import Foundation

/// JSON5 1.0 syntax, normalized for Foundation's JSONDecoder on macOS 11.
/// Numbers use IEEE 754 binary64, duplicate names keep their last value, and
/// nonfinite numbers become null, as in the previous JSON5-to-JSON adapter.
/// Large hexadecimal integers are rounded once to the nearest binary64 value.
public enum JSON5 {
    public struct ParseError: Error, LocalizedError {
        public let offset: Int
        public let reason: String
        public var errorDescription: String? { "Invalid JSON5 at character \(offset): \(reason)" }
    }

    public static func normalizedData(_ data: Data) throws -> Data {
        guard let source = String(data: data, encoding: .utf8) else {
            throw ParseError(offset: 0, reason: "Expected UTF-8")
        }
        var parser = Parser(source: Array(source.unicodeScalars))
        let value = try parser.value(depth: 0)
        try parser.trivia()
        guard parser.current == nil else { throw parser.error("Unexpected trailing input") }
        var result = Data()
        result.reserveCapacity(data.count)
        value.write(to: &result)
        return result
    }

    private indirect enum Value {
        case object([(key: [UInt16], value: Value)])
        case array([Value])
        case string([UInt16])
        case number(Double)
        case literal(String)

        func write(to data: inout Data) {
            switch self {
            case .object(let members):
                data.append(123)
                for (index, member) in members.enumerated() {
                    if index > 0 { data.append(44) }
                    Self.writeString(member.key, to: &data)
                    data.append(58)
                    member.value.write(to: &data)
                }
                data.append(125)
            case .array(let elements):
                data.append(91)
                for (index, value) in elements.enumerated() {
                    if index > 0 { data.append(44) }
                    value.write(to: &data)
                }
                data.append(93)
            case .string(let units): Self.writeString(units, to: &data)
            case .number(let number):
                let text = number.isFinite ? (number == 0 ? "0" : String(number)) : "null"
                data.append(contentsOf: text.utf8)
            case .literal(let text): data.append(contentsOf: text.utf8)
            }
        }

        private static func writeString(_ units: [UInt16], to data: inout Data) {
            let hex = Array("0123456789abcdef".utf8)
            data.append(34)
            for unit in units {
                if unit >= 32 && unit < 127 && unit != 34 && unit != 92 {
                    data.append(UInt8(unit))
                } else {
                    // Preserve UTF-16 exactly, including escaped lone surrogates.
                    // JSONDecoder owns validation when a string is decoded.
                    data.append(contentsOf: [92, 117, hex[Int(unit >> 12)], hex[Int((unit >> 8) & 15)],
                                             hex[Int((unit >> 4) & 15)], hex[Int(unit & 15)]])
                }
            }
            data.append(34)
        }
    }

    private struct Parser {
        let source: [Unicode.Scalar]
        var offset = 0
        var current: Unicode.Scalar? { offset < source.count ? source[offset] : nil }
        func error(_ reason: String) -> ParseError { ParseError(offset: offset, reason: reason) }

        @discardableResult mutating func take(_ scalar: Unicode.Scalar) -> Bool {
            guard current == scalar else { return false }
            offset += 1
            return true
        }

        mutating func require(_ scalar: Unicode.Scalar) throws {
            guard take(scalar) else { throw error("Expected \(scalar)") }
        }

        mutating func trivia() throws {
            while let scalar = current {
                if Self.isWhitespace(scalar) { offset += 1; continue }
                guard scalar == "/", offset + 1 < source.count else { return }
                if source[offset + 1] == "/" {
                    offset += 2
                    while let scalar = current, !Self.isLineTerminator(scalar) { offset += 1 }
                } else if source[offset + 1] == "*" {
                    offset += 2
                    while offset + 1 < source.count && !(source[offset] == "*" && source[offset + 1] == "/") {
                        offset += 1
                    }
                    guard offset + 1 < source.count else { throw error("Unterminated comment") }
                    offset += 2
                } else { return }
            }
        }

        mutating func value(depth: Int) throws -> Value {
            try trivia()
            // Foundation also limits JSON nesting to 512. Bound recursion before
            // allocating another container, including for unknown metadata fields.
            switch current {
            case "{":
                guard depth < 512 else { throw error("Nesting exceeds 512 containers") }
                offset += 1
                try trivia()
                var members: [(key: [UInt16], value: Value)] = []
                var indices: [[UInt16]: Int] = [:]
                if take("}") { return .object(members) }
                repeat {
                    try trivia()
                    let key = current == "\"" || current == "'" ? try string() : try identifier()
                    try trivia()
                    try require(":")
                    let child = try value(depth: depth + 1)
                    // Swift String equality folds Unicode canonical equivalents;
                    // JSON5/JavaScript object names compare UTF-16 code units.
                    if let index = indices[key] { members[index].value = child }
                    else { indices[key] = members.count; members.append((key, child)) }
                    try trivia()
                    if take("}") { break }
                    try require(",")
                    try trivia()
                    if take("}") { break }
                } while true
                return .object(members)
            case "[":
                guard depth < 512 else { throw error("Nesting exceeds 512 containers") }
                offset += 1
                try trivia()
                var elements: [Value] = []
                if take("]") { return .array(elements) }
                repeat {
                    elements.append(try value(depth: depth + 1))
                    try trivia()
                    if take("]") { break }
                    try require(",")
                    try trivia()
                    if take("]") { break }
                } while true
                return .array(elements)
            case "\"", "'": return .string(try string())
            case "t": try keyword("true"); return .literal("true")
            case "f": try keyword("false"); return .literal("false")
            case "n": try keyword("null"); return .literal("null")
            default: return .number(try number())
            }
        }

        mutating func keyword(_ word: String) throws {
            for scalar in word.unicodeScalars { try require(scalar) }
        }

        mutating func string() throws -> [UInt16] {
            let quote = source[offset]
            offset += 1
            var units: [UInt16] = []
            while let scalar = current {
                offset += 1
                if scalar == quote { return units }
                if scalar == "\n" || scalar == "\r" { throw error("Unescaped newline in string") }
                if scalar != "\\" { units.append(contentsOf: scalar.utf16); continue }
                guard let escaped = current else { throw error("Unterminated escape") }
                offset += 1
                switch escaped {
                case "\r": take("\n")
                case "\n", "\u{2028}", "\u{2029}": break
                case "b": units.append(8)
                case "f": units.append(12)
                case "n": units.append(10)
                case "r": units.append(13)
                case "t": units.append(9)
                case "v": units.append(11)
                case "0":
                    guard !Self.isDigit(current) else { throw error("Octal escape is not JSON5") }
                    units.append(0)
                case "1"..."9": throw error("Octal escape is not JSON5")
                case "x": units.append(try hexUnit(digits: 2))
                case "u": units.append(try hexUnit(digits: 4))
                default: units.append(contentsOf: escaped.utf16)
                }
            }
            throw error("Unterminated string")
        }

        mutating func hexUnit(digits: Int) throws -> UInt16 {
            var value: UInt16 = 0
            for _ in 0..<digits {
                guard let scalar = current, let digit = Self.hexDigit(scalar) else { throw error("Expected hexadecimal digit") }
                value = value * 16 + UInt16(digit)
                offset += 1
            }
            return value
        }

        mutating func identifier() throws -> [UInt16] {
            var units: [UInt16] = []
            while let scalar = current {
                let character: Unicode.Scalar
                if scalar == "\\" {
                    offset += 1
                    try require("u")
                    guard let decoded = Unicode.Scalar(try hexUnit(digits: 4)),
                          Self.isIdentifier(decoded, first: units.isEmpty) else { throw error("Invalid identifier escape") }
                    character = decoded
                } else {
                    guard Self.isIdentifier(scalar, first: units.isEmpty) else { break }
                    character = scalar
                    offset += 1
                }
                units.append(contentsOf: character.utf16)
            }
            guard !units.isEmpty else { throw error("Expected member name") }
            return units
        }

        mutating func number() throws -> Double {
            let start = offset
            let negative = take("-")
            if !negative { take("+") }
            let numericStart = offset
            if current == "I" { try keyword("Infinity"); return negative ? -.infinity : .infinity }
            if current == "N" { try keyword("NaN"); return .nan }
            if take("0") {
                if take("x") || take("X") {
                    let digits = offset
                    while let scalar = current, Self.hexDigit(scalar) != nil { offset += 1 }
                    guard offset > digits else { throw error("Expected hexadecimal number") }
                    let text = String(String.UnicodeScalarView(source[digits..<offset]))
                    // A hexadecimal floating-point conversion rounds once, even
                    // for integers larger than UInt64 or binary64's exact range.
                    guard let value = Double("0x" + text + "p0") else { throw error("Invalid hexadecimal number") }
                    return negative ? -value : value
                }
                guard !Self.isDigit(current) else { throw error("Leading zero is not JSON5") }
            } else {
                while Self.isDigit(current) { offset += 1 }
            }
            let beforeFraction = offset
            if take(".") {
                while Self.isDigit(current) { offset += 1 }
            }
            guard beforeFraction > numericStart || offset > beforeFraction + 1 else { throw error("Expected number") }
            if take("e") || take("E") {
                if !take("+") { take("-") }
                let exponent = offset
                while Self.isDigit(current) { offset += 1 }
                guard offset > exponent else { throw error("Expected exponent digits") }
            }
            let text = String(String.UnicodeScalarView(source[start..<offset]))
            guard let value = Double(text) else { throw error("Invalid number") }
            return value
        }

        static func isDigit(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return scalar >= "0" && scalar <= "9"
        }
        static func hexDigit(_ scalar: Unicode.Scalar) -> UInt32? {
            switch scalar.value {
            case 48...57: return scalar.value - 48
            case 65...70: return scalar.value - 55
            case 97...102: return scalar.value - 87
            default: return nil
            }
        }
        static func isIdentifier(_ scalar: Unicode.Scalar, first: Bool) -> Bool {
            if scalar == "$" || scalar == "_" { return true }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .letterNumber: return true
            case .nonspacingMark, .spacingMark, .decimalNumber, .connectorPunctuation: return !first
            default: return !first && (scalar == "\u{200C}" || scalar == "\u{200D}")
            }
        }
        static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
        }
        static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
            isLineTerminator(scalar) || scalar == "\t" || scalar == "\u{B}" || scalar == "\u{C}"
                || scalar == "\u{FEFF}" || scalar.properties.generalCategory == .spaceSeparator
        }
    }
}
