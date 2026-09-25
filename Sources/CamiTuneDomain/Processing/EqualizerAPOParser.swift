import Foundation

package struct EqualizerAPOParser {
    package init() {}
    package enum PreampPolicy {
        /// Used for CamiTune's own drafts and legacy profile migration.
        case importValue
        /// Used for user-selected APO files. CamiTune owns gain staging separately.
        case ignore
    }

    package struct ParseError: LocalizedError {
        package init(line: Int, message: String) { self.line = line; self.message = message }
        let line: Int
        let message: String
        package var errorDescription: String? { "Line \(line): \(message)" }
    }

    private enum FilterParseResult {
        case band(EQBand)
        case unsupported(String)
    }

    /// Commands that are valid Equalizer APO syntax but cannot be represented by
    /// CamiTune's editable processing graph yet. Keeping this list explicit lets
    /// the importer distinguish an APO document from arbitrary `name: value` text.
    private static let recognizedUnsupportedCommands: Set<String> = [
        "balance", "convolution", "copy", "delay", "else", "elseif", "endif",
        "eval", "expression", "graphiceq", "if", "include", "loudnesscorrection",
        "select", "stage", "vstplugin"
    ]

    package func parse(_ text: String, preampPolicy: PreampPolicy = .importValue) throws -> ParsedEQ {
        var result = ParsedEQ()
        let lines = text.components(separatedBy: .newlines)
        var validDirectiveCount = 0
        var firstInvalidDirective: ParseError?

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmingCharacters = CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "\u{FEFF}"))
            // Equalizer APO accepts a non-breaking space as a thousands separator
            // in frequencies exported by some localized versions of REW.
            let line = rawLine
                .replacingOccurrences(of: "\u{00A0}", with: "")
                .trimmingCharacters(in: trimmingCharacters)
            if line.isEmpty || line.hasPrefix("#") { continue }

            guard let colon = line.firstIndex(of: ":") else {
                // Equalizer APO itself ignores non-command lines. They do not make
                // otherwise valid imported EQ text fail, but cannot establish that
                // a document is an APO preset on their own.
                continue
            }

            let header = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard let command = header.split(whereSeparator: { $0.isWhitespace }).first?.lowercased() else {
                continue
            }
            let payload = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            switch command {
            case "preamp":
                guard let value = firstNumber(in: payload) else {
                    record(
                        ParseError(line: lineNumber, message: "Invalid Preamp value"),
                        firstInvalidDirective: &firstInvalidDirective,
                        warnings: &result.warnings
                    )
                    continue
                }
                if preampPolicy == .importValue {
                    result.preampDB += value
                    result.importedDirectiveCount += 1
                } else {
                    result.warnings.append(
                        "Line \(lineNumber): Preamp is ignored; use CamiTune's User Preamp and automatic system headroom controls."
                    )
                }
                validDirectiveCount += 1

            case "filter":
                do {
                    switch try parseFilter(line, lineNumber: lineNumber) {
                    case .band(let band):
                        result.bands.append(band)
                        result.importedDirectiveCount += 1
                    case .unsupported(let message):
                        result.warnings.append("Line \(lineNumber): \(message)")
                    }
                    validDirectiveCount += 1
                } catch let error as ParseError {
                    record(
                        error,
                        firstInvalidDirective: &firstInvalidDirective,
                        warnings: &result.warnings
                    )
                }

            // Device selection belongs to CamiTune profiles rather than imported text.
            case "device":
                guard !payload.isEmpty else {
                    record(
                        ParseError(line: lineNumber, message: "Device command is empty"),
                        firstInvalidDirective: &firstInvalidDirective,
                        warnings: &result.warnings
                    )
                    continue
                }
                result.warnings.append("Line \(lineNumber): Device: is ignored; choose the macOS output device in the CamiTune profile.")
                validDirectiveCount += 1

            case "channel":
                guard !payload.isEmpty else {
                    record(
                        ParseError(line: lineNumber, message: "Channel command is empty"),
                        firstInvalidDirective: &firstInvalidDirective,
                        warnings: &result.warnings
                    )
                    continue
                }
                result.warnings.append("Line \(lineNumber): Channel: is not imported here; use CamiTune's per-channel EQ controls.")
                validDirectiveCount += 1

            case let command where Self.recognizedUnsupportedCommands.contains(command):
                let allowsEmptyPayload = command == "else" || command == "endif"
                guard allowsEmptyPayload || !payload.isEmpty else {
                    record(
                        ParseError(line: lineNumber, message: "Empty \(header) command"),
                        firstInvalidDirective: &firstInvalidDirective,
                        warnings: &result.warnings
                    )
                    continue
                }
                result.warnings.append("Line \(lineNumber): \(header): is valid Equalizer APO syntax but is not imported yet, so it was skipped.")
                validDirectiveCount += 1

            default:
                // Equalizer APO ignores unknown commands. Do the same when another
                // valid directive proves that this is an APO document.
                continue
            }
        }

        guard validDirectiveCount > 0 else {
            if let firstInvalidDirective { throw firstInvalidDirective }
            throw ParseError(line: 1, message: "No valid Equalizer APO commands were found")
        }
        return result
    }

    private func parseFilter(_ line: String, lineNumber: Int) throws -> FilterParseResult {
        guard let colon = line.firstIndex(of: ":") else {
            throw ParseError(line: lineNumber, message: "Filter line needs ':'")
        }
        let payload = String(line[line.index(after: colon)...])
        let tokens = payload.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2 else { throw ParseError(line: lineNumber, message: "Incomplete filter") }

        let enabledToken = tokens[0].uppercased()
        guard enabledToken == "ON" || enabledToken == "OFF" else {
            throw ParseError(line: lineNumber, message: "Expected ON or OFF")
        }
        let enabled = enabledToken == "ON"

        let typeToken = tokens[1].uppercased()
        let kind: EQBand.Kind
        switch typeToken {
        case "PK", "PEQ": kind = .peaking
        case "LS", "LSC": kind = .lowShelf
        case "HS", "HSC": kind = .highShelf
        case "LP", "LPQ": kind = .lowPass
        case "HP", "HPQ": kind = .highPass
        case "NO": kind = .notch
        case "AP": kind = .allPass
        case "BP", "IIR", "MODAL":
            return .unsupported("Filter type \(typeToken) is not represented by CamiTune's EQ graph yet, so it was skipped.")
        default:
            throw ParseError(
                line: lineNumber,
                message: "Unknown Equalizer APO filter type \(typeToken)"
            )
        }

        guard let fc = value(after: "Fc", in: tokens) else {
            throw ParseError(line: lineNumber, message: "Missing Fc")
        }
        guard fc > 0 else { throw ParseError(line: lineNumber, message: "Fc must be greater than zero") }
        let gain = value(after: "Gain", in: tokens)
        let explicitQ = value(after: "Q", in: tokens)
        let bw = bandwidth(in: tokens)
        let declaredShelfSlope = shelfSlope(in: tokens)
        if let explicitQ, explicitQ <= 0 {
            throw ParseError(line: lineNumber, message: "Q must be greater than zero")
        }
        if let bw, bw <= 0 {
            throw ParseError(line: lineNumber, message: "BW Oct must be greater than zero")
        }
        if let declaredShelfSlope, !(0 < declaredShelfSlope && declaredShelfSlope <= 12) {
            throw ParseError(line: lineNumber, message: "Shelf slope must be greater than 0 and no more than 12 dB/oct")
        }

        // The graphical editor and CamillaDSP graph are Q-based. Normalize APO's
        // BW Oct and shelf-slope forms now so later editing/serialization cannot
        // silently change their response.
        var normalizedFrequency = fc
        var q = explicitQ ?? bw.map(qFromBandwidth)
        if kind == .lowShelf || kind == .highShelf {
            guard gain != nil else { throw ParseError(line: lineNumber, message: "Shelf filter needs Gain") }
            if let declaredShelfSlope {
                q = qFromShelfSlope(declaredShelfSlope, gainDB: gain ?? 0)

                // LS/HS 6dB and 12dB use corner frequency, whereas LSC/HSC use
                // center frequency. Equalizer APO applies this same conversion.
                if typeToken == "LS" || typeToken == "HS" {
                    let slope = declaredShelfSlope / 12
                    let centerFactor = pow(10, abs(gain ?? 0) / 80 / slope)
                    normalizedFrequency = typeToken == "LS"
                        ? fc * centerFactor
                        : fc / centerFactor
                }
            }
        }
        if let q, !q.isFinite || q <= 0 {
            throw ParseError(line: lineNumber, message: "The calculated filter Q is invalid")
        }

        switch kind {
        case .peaking:
            guard gain != nil else { throw ParseError(line: lineNumber, message: "Peaking filter needs Gain") }
            guard q != nil else { throw ParseError(line: lineNumber, message: "Peaking filter needs Q or BW Oct") }
        case .allPass:
            guard q != nil else { throw ParseError(line: lineNumber, message: "All-pass filter needs Q") }
        default:
            break
        }

        return .band(EQBand(
            enabled: enabled,
            kind: kind,
            frequency: normalizedFrequency,
            gain: gain,
            q: q
        ))
    }

    private func record(
        _ error: ParseError,
        firstInvalidDirective: inout ParseError?,
        warnings: inout [String]
    ) {
        if firstInvalidDirective == nil { firstInvalidDirective = error }
        warnings.append("Line \(error.line): \(error.message); this line was skipped.")
    }

    private func value(after key: String, in tokens: [String]) -> Double? {
        guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
              index + 1 < tokens.count else { return nil }
        return number(from: tokens[index + 1])
    }

    private func bandwidth(in tokens: [String]) -> Double? {
        guard let bwIndex = tokens.firstIndex(where: { $0.caseInsensitiveCompare("BW") == .orderedSame }) else { return nil }
        var index = bwIndex + 1
        if index < tokens.count, tokens[index].caseInsensitiveCompare("Oct") == .orderedSame { index += 1 }
        guard index < tokens.count else { return nil }
        return number(from: tokens[index])
    }

    /// Returns the optional `x dB` immediately following LS/LSC/HS/HSC.
    private func shelfSlope(in tokens: [String]) -> Double? {
        guard tokens.count > 2 else { return nil }
        let compactToken = tokens[2].lowercased()
        if compactToken.hasSuffix("db") {
            return number(from: compactToken)
        }
        if tokens.count > 3,
           tokens[3].caseInsensitiveCompare("dB") == .orderedSame {
            return number(from: tokens[2])
        }
        return nil
    }

    private func firstNumber(in string: String) -> Double? {
        string.split(whereSeparator: { $0.isWhitespace })
            .compactMap { number(from: String($0)) }
            .first
    }

    /// Equalizer APO accepts attached units (`100Hz`, `-3dB`) and converts a
    /// localized decimal comma before parsing.
    private func number(from token: String) -> Double? {
        var normalized = token.lowercased().replacingOccurrences(of: ",", with: ".")
        for suffix in ["samples", "sample", "oct", "hz", "db", "ms"] where normalized.hasSuffix(suffix) {
            normalized.removeLast(suffix.count)
            break
        }
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    private func qFromBandwidth(_ bandwidth: Double) -> Double {
        1 / (2 * sinh(log(2) / 2 * bandwidth))
    }

    private func qFromShelfSlope(_ slopeDBPerOctave: Double, gainDB: Double) -> Double {
        let slope = slopeDBPerOctave / 12
        let amplitude = pow(10, gainDB / 40)
        return 1 / sqrt((amplitude + 1 / amplitude) * (1 / slope - 1) + 2)
    }
}
