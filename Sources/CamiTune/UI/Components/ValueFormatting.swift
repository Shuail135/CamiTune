import Foundation
import SwiftUI

private struct MonospacedDigits: ViewModifier {
    @Environment(\.font) private var font
    func body(content: Content) -> some View {
        content.font((font ?? .body).monospacedDigit())
    }
}

extension View {
    /// Keep the surrounding caption, headline and weight when aligning digits.
    func monospacedDigits() -> some View { modifier(MonospacedDigits()) }
}

/// Locale-aware decimal presentation shared by editable fields and their labels.
/// Cached formatters are configured once and never mutated by callers.
struct DecimalFormat {
    let fractionDigits: ClosedRange<Int>
    var grouping = true
    var locale = Locale.autoupdatingCurrent

    init(_ fractionDigits: ClosedRange<Int> = 0...6, grouping: Bool = true) {
        self.fractionDigits = fractionDigits
        self.grouping = grouping
    }

    init(_ fractionDigits: Int, grouping: Bool = true) {
        self.init(fractionDigits...fractionDigits, grouping: grouping)
    }

    private static let cache: NSCache<NSString, NumberFormatter> = {
        let cache = NSCache<NSString, NumberFormatter>()
        cache.countLimit = 64
        return cache
    }()

    var formatter: NumberFormatter {
        let key = "\(locale.identifier):\(fractionDigits):\(grouping)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        let value = NumberFormatter()
        value.locale = locale
        value.numberStyle = .decimal
        value.minimumFractionDigits = fractionDigits.lowerBound
        value.maximumFractionDigits = fractionDigits.upperBound
        value.usesGroupingSeparator = grouping
        value.isLenient = false
        Self.cache.setObject(value, forKey: key)
        return value
    }

    func string(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func parse(_ text: String) throws -> Double {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var value: AnyObject?
        var range = NSRange(location: 0, length: (input as NSString).length)
        try formatter.getObjectValue(&value, for: input, range: &range)
        guard range.length == (input as NSString).length,
              let number = value as? NSNumber, number.doubleValue.isFinite else {
            throw CocoaError(.formatting)
        }
        return number.doubleValue
    }
}

extension BinaryFloatingPoint {
    func decimalText(_ format: DecimalFormat = DecimalFormat()) -> String {
        format.string(Double(self))
    }
}

extension Int {
    func decimalText() -> String {
        DecimalFormat(0).formatter.string(from: NSNumber(value: Int64(self))) ?? String(self)
    }
}

enum DatePresentation {
    private static let dates: NSCache<NSString, DateFormatter> = {
        let cache = NSCache<NSString, DateFormatter>()
        cache.countLimit = 16
        return cache
    }()
    private static let iso = ISO8601DateFormatter()

    static func string(_ date: Date, template: String = "yMdjmm") -> String {
        let locale = Locale.current, zone = TimeZone.current
        let key = "\(locale.identifier):\(zone.identifier):\(template)" as NSString
        if let formatter = dates.object(forKey: key) { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(template)
        dates.setObject(formatter, forKey: key)
        return formatter.string(from: date)
    }

    static func iso8601(_ date: Date) -> String { iso.string(from: date) }
}
