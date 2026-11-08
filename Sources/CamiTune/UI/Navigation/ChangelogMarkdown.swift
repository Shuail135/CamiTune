import AppKit
import SwiftUI

/// Release notes intentionally support headings, lists and links rather than a
/// general Markdown document. Native text keeps selection/copying continuous.
enum ChangelogMarkdown {
    private struct Block {
        var text: String
        var heading = 0
        var depth = 0
        var prefix = ""
        var bold = false
    }

    private struct ListLevel {
        let indent: Int
        var contentIndent: Int
        let marker: Character
        var nextNumber: Int?
    }

    static func render(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks(markdown) {
            let font: NSFont = block.heading > 0
                ? .systemFont(ofSize: [24, 20, 17, 15, 14, 13][block.heading - 1], weight: .bold)
                : .systemFont(ofSize: 13, weight: block.bold ? .bold : .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = block.depth > 0 ? 4 : 10
            paragraph.headIndent = CGFloat(block.depth * 22)
            paragraph.firstLineHeadIndent = block.prefix.isEmpty ? paragraph.headIndent : max(0, paragraph.headIndent - 22)
            if !block.prefix.isEmpty {
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
            }
            if block.heading > 0 { paragraph.paragraphSpacingBefore = result.length == 0 ? 0 : 8 }
            let text = NSMutableAttributedString(string: block.prefix, attributes: attributes)
            text.append(links(in: block.text, attributes: attributes))
            text.append(NSAttributedString(string: "\n"))
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            result.append(text)
        }
        return result
    }

    private static func blocks(_ markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var result: [Block] = []
        var lists: [ListLevel] = []
        var canContinue = false
        for line in lines {
            var indent = 0
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            for character in leading { indent += character == "\t" ? 4 - indent % 4 : 1 }
            let text = String(line.dropFirst(leading.count)).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { canContinue = false; continue }

            let hashes = text.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), text.count == hashes || text.dropFirst(hashes).first == " " || text.dropFirst(hashes).first == "\t" {
                var title = String(text.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                let ending = title.reversed().prefix { $0 == "#" }.count
                if ending > 0, title.dropLast(ending).last?.isWhitespace == true {
                    title = String(title.dropLast(ending)).trimmingCharacters(in: .whitespaces)
                }
                result.append(Block(text: unwrappedTitle(title), heading: hashes))
                lists.removeAll()
                canContinue = false
                continue
            }
            // Existing user-authored notes contain wrapped titles and dividers.
            // Keep those readable without changing the bundled source document.
            if let first = text.first, "*-_".contains(first), text.filter({ !$0.isWhitespace }).count >= 3,
               text.allSatisfy({ $0 == first || $0.isWhitespace }) {
                result.append(Block(text: "⸻"))
                lists.removeAll()
                canContinue = false
                continue
            }
            if let marker = listMarker(text, indent: indent) {
                while let last = lists.last, indent < last.contentIndent && indent != last.indent { lists.removeLast() }
                if let last = lists.last, last.indent == indent, last.marker != marker.marker { lists.removeLast() }
                if lists.last?.indent != indent {
                    lists.append(ListLevel(indent: indent, contentIndent: marker.contentIndent, marker: marker.marker, nextNumber: marker.number))
                }
                lists[lists.count - 1].contentIndent = marker.contentIndent
                let prefix: String
                if let number = lists[lists.count - 1].nextNumber {
                    prefix = "\(number).\t"
                    lists[lists.count - 1].nextNumber = number + 1
                } else { prefix = "•\t" }
                result.append(Block(text: marker.text, depth: lists.count, prefix: prefix))
                canContinue = true
                continue
            }

            var depth = lists.lastIndex(where: { indent >= $0.contentIndent }).map { $0 + 1 } ?? 0
            // Unindented soft-wrapped text continues the preceding list item.
            if depth == 0, canContinue, let previous = result.last { depth = previous.depth }
            if depth == 0 { lists.removeAll() }
            else if depth < lists.count { lists.removeLast(lists.count - depth) }
            let unwrapped = unwrappedTitle(text)
            let bold = unwrapped != text
            if canContinue, !bold, let previous = result.last, previous.heading == 0, !previous.bold, previous.depth == depth {
                result[result.count - 1].text += " " + text
            } else {
                result.append(Block(text: unwrapped, depth: depth, bold: bold))
            }
            canContinue = !bold
        }
        return result
    }

    private static func unwrappedTitle(_ text: String) -> String {
        for wrapper in ["**", "__"] where text.count > 4 && text.hasPrefix(wrapper) && text.hasSuffix(wrapper) {
            let title = String(text.dropFirst(2).dropLast(2))
            if !title.contains(wrapper) { return title }
        }
        return text
    }

    private static func listMarker(_ text: String, indent: Int) -> (marker: Character, number: Int?, contentIndent: Int, text: String)? {
        var cursor = text.startIndex
        let digits = text.prefix { $0 >= "0" && $0 <= "9" }
        let number: Int?
        let marker: Character
        if !digits.isEmpty {
            guard digits.count <= 9, let value = Int(digits) else { return nil }
            cursor = text.index(cursor, offsetBy: digits.count)
            guard cursor < text.endIndex, text[cursor] == "." || text[cursor] == ")" else { return nil }
            number = value
            marker = text[cursor]
        } else {
            guard let first = text.first, "-+*".contains(first) else { return nil }
            marker = first
            number = nil
        }
        cursor = text.index(after: cursor)
        guard cursor == text.endIndex || text[cursor] == " " || text[cursor] == "\t" else { return nil }
        var column = indent + text.distance(from: text.startIndex, to: cursor)
        let markerEnd = column
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            column += text[cursor] == "\t" ? 4 - column % 4 : 1
            cursor = text.index(after: cursor)
        }
        return (marker, number, max(markerEnd + 1, column), String(text[cursor...]))
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func links(in source: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let next = source.index(after: cursor)
            if source[cursor] == "\\", next < source.endIndex, isEscapable(source[next]) {
                result.append(NSAttributedString(string: String(source[next]), attributes: attributes))
                cursor = source.index(after: next)
            } else if source[cursor] == "[", let label = delimited(source, at: cursor, open: "[", close: "]"),
                      label.end < source.endIndex, source[label.end] == "(",
                      let destination = delimited(source, at: label.end, open: "(", close: ")"),
                      let url = linkURL(destination.text) {
                var linked = attributes
                linked[.link] = url
                result.append(NSAttributedString(string: unescape(label.text), attributes: linked))
                cursor = destination.end
            } else if source[cursor] == "<", let end = source[next...].firstIndex(of: ">"),
                      let url = linkURL(String(source[next..<end])) {
                var linked = attributes
                linked[.link] = url
                result.append(NSAttributedString(string: String(source[next..<end]), attributes: linked))
                cursor = source.index(after: end)
            } else {
                result.append(NSAttributedString(string: String(source[cursor]), attributes: attributes))
                cursor = next
            }
        }
        let range = NSRange(location: 0, length: result.length)
        linkDetector?.enumerateMatches(in: result.string, range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            var overlapsLink = false
            result.enumerateAttribute(.link, in: match.range) { value, _, _ in
                if value != nil { overlapsLink = true }
            }
            if !overlapsLink { result.addAttribute(.link, value: url, range: match.range) }
        }
        return result
    }

    private static func delimited(_ source: String, at start: String.Index, open: Character, close: Character) -> (text: String, end: String.Index)? {
        var depth = 1
        var cursor = source.index(after: start)
        let content = cursor
        while cursor < source.endIndex {
            let character = source[cursor]
            let next = source.index(after: cursor)
            if character == "\\", next < source.endIndex, isEscapable(source[next]) {
                cursor = source.index(after: next)
                continue
            }
            if character == open { depth += 1 }
            if character == close {
                depth -= 1
                if depth == 0 { return (String(source[content..<cursor]), next) }
            }
            cursor = next
        }
        return nil
    }

    private static func isEscapable(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return (33...47).contains(ascii) || (58...64).contains(ascii) || (91...96).contains(ascii) || (123...126).contains(ascii)
    }

    private static func unescape(_ source: String) -> String {
        var result = ""
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let next = source.index(after: cursor)
            if source[cursor] == "\\", next < source.endIndex, isEscapable(source[next]) { cursor = next }
            result.append(source[cursor])
            cursor = source.index(after: cursor)
        }
        return result
    }

    private static func linkURL(_ source: String) -> URL? {
        var text = source.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<"), text.hasSuffix(">") { text = String(text.dropFirst().dropLast()) }
        text = unescape(text)
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme, ["http", "https", "mailto", "ftp"].contains(scheme.lowercased()) else { return nil }
        return url
    }
}
/// A single text view keeps selection and copying continuous across blocks.
struct ChangelogTextView: NSViewRepresentable {
    let content: NSAttributedString

    final class Coordinator {
        var content: NSAttributedString?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let text = NSTextView(usingTextLayoutManager: false)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.setAccessibilityLabel("Changelog")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.content !== content else { return }
        (scroll.documentView as? NSTextView)?.textStorage?.setAttributedString(content)
        context.coordinator.content = content
    }
}
