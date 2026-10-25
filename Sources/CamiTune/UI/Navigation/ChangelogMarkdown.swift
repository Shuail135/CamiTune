import AppKit
import SwiftUI

/// Foundation parses Markdown; this adapter supplies the block layout that Text
/// does not render, without a web view or a second Markdown parser.
enum ChangelogMarkdown {
    static func render(_ markdown: String) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: markdown,
            options: .init(interpretedSyntax: .full)) else {
            return NSAttributedString(string: markdown, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
            ])
        }
        let result = NSMutableAttributedString()
        var seenListItems = Set<Int>()
        var tables: [Int: NSTextTable] = [:]
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            let fragment = NSAttributedString(AttributedString(parsed[range]))
            var font = NSFont.systemFont(ofSize: 13)
            var color = NSColor.labelColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 10
            paragraph.lineSpacing = 3
            let listDepth = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count
            let quoteDepth = components.filter { $0.kind == .blockQuote }.count
            paragraph.headIndent = CGFloat(listDepth * 22 + quoteDepth * 16)
            paragraph.firstLineHeadIndent = paragraph.headIndent
            var prefix = ""
            var isCodeBlock = false
            var handledListItem = false
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .header(let level):
                    font = .systemFont(ofSize: [24, 20, 17, 15, 14, 13][min(max(level, 1), 6) - 1], weight: .bold)
                    paragraph.paragraphSpacingBefore = result.length == 0 ? 0 : 8
                case .listItem(let ordinal) where !handledListItem:
                    handledListItem = true
                    // A second paragraph within the same item has no extra marker.
                    if seenListItems.insert(component.identity).inserted {
                        let ordered = components.dropFirst(index + 1).first?.kind == .orderedList
                        prefix = ordered ? "\(ordinal).\t" : "•\t"
                        paragraph.firstLineHeadIndent = max(0, paragraph.headIndent - 22)
                        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                    }
                    paragraph.paragraphSpacing = 4
                case .codeBlock:
                    isCodeBlock = true
                    font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                    paragraph.headIndent += 8
                    paragraph.firstLineHeadIndent += 8
                case .blockQuote:
                    color = .secondaryLabelColor
                case .tableHeaderRow:
                    font = .boldSystemFont(ofSize: 13)
                case .tableCell(let column):
                    if let tableIntent = components.first(where: { if case .table = $0.kind { return true }; return false }),
                       case .table(let columns) = tableIntent.kind {
                        let table = tables[tableIntent.identity] ?? NSTextTable()
                        table.numberOfColumns = columns.count
                        table.collapsesBorders = true
                        table.setContentWidth(100, type: .percentageValueType)
                        tables[tableIntent.identity] = table
                        let row = components.compactMap { element -> Int? in
                            if case .tableRow(let index) = element.kind { return index }; return nil
                        }.first ?? 0
                        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                            startingColumn: column, columnSpan: 1)
                        cell.setWidth(6, type: .absoluteValueType, for: .padding)
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                        cell.setBorderColor(.separatorColor)
                        paragraph.textBlocks = [cell]
                        paragraph.paragraphSpacing = 0
                        if columns.indices.contains(column) {
                            switch columns[column].alignment {
                            case .left: paragraph.alignment = .left
                            case .center: paragraph.alignment = .center
                            case .right: paragraph.alignment = .right
                            @unknown default: break
                            }
                        }
                    }
                default: break
                }
            }
            if isCodeBlock { paragraph.paragraphSpacing = 0 }
            let styled = NSMutableAttributedString(attributedString: fragment)
            let fullRange = NSRange(location: 0, length: styled.length)
            styled.addAttributes([.font: font, .foregroundColor: color], range: fullRange)
            if isCodeBlock { styled.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: fullRange) }
            // Keep Foundation's link attributes while giving inline styles real
            // AppKit fonts, including combinations such as bold italic headings.
            fragment.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, inlineRange, _ in
                guard let value = value as? NSNumber else { return }
                let inline = InlinePresentationIntent(rawValue: value.uintValue)
                var inlineFont = inline.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : font
                if inline.contains(.stronglyEmphasized) { inlineFont = NSFontManager.shared.convert(inlineFont, toHaveTrait: .boldFontMask) }
                if inline.contains(.emphasized) { inlineFont = NSFontManager.shared.convert(inlineFont, toHaveTrait: .italicFontMask) }
                styled.addAttribute(.font, value: inlineFont, range: inlineRange)
                if inline.contains(.code) { styled.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: inlineRange) }
                if inline.contains(.strikethrough) { styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: inlineRange) }
            }
            styled.removeAttribute(.presentationIntentAttributeName, range: fullRange)
            styled.removeAttribute(.inlinePresentationIntent, range: fullRange)
            let block = NSMutableAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: color])
            block.append(styled)
            if !block.string.hasSuffix("\n") { block.append(NSAttributedString(string: "\n")) }
            block.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: block.length))
            if isCodeBlock {
                let lastParagraph = (block.string as NSString).paragraphRange(for: NSRange(location: block.length - 1, length: 0))
                let ending = paragraph.mutableCopy() as! NSMutableParagraphStyle
                ending.paragraphSpacing = 10
                block.addAttribute(.paragraphStyle, value: ending, range: lastParagraph)
            }
            result.append(block)
        }
        return result
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
