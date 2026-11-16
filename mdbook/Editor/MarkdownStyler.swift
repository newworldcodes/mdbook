//
//  MarkdownStyler.swift
//  mdbook
//
//  Applies `MarkdownSpans` to an `NSTextStorage` as attributes.
//

import AppKit

struct MarkdownStyler {
    let theme: EditorTheme

    /// Horizontal space added to every table column (split between the two sides of a cell).
    static let tableCellPadding: CGFloat = 28
    /// Vertical space above and below the text in each rendered table row.
    static let tableRowPadding: CGFloat = 6

    /// Restyles the whole document. `activeRegion` is the paragraph containing the caret
    /// (widened to the whole table when the caret is inside one); markup there stays
    /// visible so the user can edit it.
    func applyAll(to storage: NSTextStorage, spans: MarkdownSpans, activeRegion: NSRange?) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: full)

        // Block-level constructs first; inline styling layers on top of them.
        for block in spans.codeBlocks {
            // The layout manager draws a full-width panel for `.markdownCodeBlock`.
            storage.addAttributes([.font: theme.codeFont, .markdownCodeBlock: true], range: block.range)
            if theme.mode == .wysiwyg {
                let style = mutableParagraphStyle()
                style.lineSpacing = 1
                style.paragraphSpacing = 0
                storage.addAttribute(.paragraphStyle, value: style, range: block.range)
            }
            for fence in block.fenceLines {
                storage.addAttribute(.foregroundColor, value: theme.markerColor, range: fence)
            }
            highlightCode(in: block, storage: storage)
        }

        for heading in spans.headings {
            storage.addAttribute(.font, value: theme.headingFont(level: heading.level), range: heading.line)
            if theme.mode == .wysiwyg {
                let style = mutableParagraphStyle()
                style.paragraphSpacingBefore = heading.level <= 2 ? 14 : 8
                style.paragraphSpacing = 8
                storage.addAttribute(.paragraphStyle, value: style, range: heading.line)
            } else {
                storage.addAttribute(.foregroundColor, value: theme.accentColor, range: heading.line)
            }
        }

        for quote in spans.blockQuotes {
            storage.addAttribute(.foregroundColor, value: theme.quoteColor, range: quote.line)
            if theme.mode == .wysiwyg {
                let style = mutableParagraphStyle()
                style.firstLineHeadIndent = 4
                style.headIndent = 4 + width(of: quote.marker, in: storage)
                storage.addAttribute(.paragraphStyle, value: style, range: quote.line)
            }
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: quote.marker)
        }

        for item in spans.listItems {
            storage.addAttribute(.foregroundColor, value: theme.accentColor, range: item.marker)
            if let task = item.task {
                storage.addAttributes([.foregroundColor: theme.accentColor, .markdownTask: true], range: task)
                storage.addAttribute(.cursor, value: NSCursor.pointingHand, range: task)
            }
            if theme.mode == .wysiwyg {
                // Wrapped lines align with the start of the item text.
                let style = mutableParagraphStyle()
                let indent = CGFloat(item.indent) * 8
                let markerWidth = width(of: NSRange(location: item.marker.location, length: NSMaxRange(item.task ?? item.marker) - item.marker.location), in: storage)
                style.firstLineHeadIndent = indent
                style.headIndent = indent + markerWidth + (item.task == nil ? 0 : width(of: " ", font: theme.baseFont))
                style.paragraphSpacing = 2
                storage.addAttribute(.paragraphStyle, value: style, range: item.line)
            }
        }

        for table in spans.tables {
            // Rendered tables use the reading font; tables being edited use monospace so
            // the aligned source lines up.
            let asGrid = rendersAsGrid(table, activeRegion: activeRegion)
            let font = asGrid ? theme.baseFont : theme.codeFont
            for line in table.lines {
                storage.addAttribute(.font, value: font, range: line)
                if theme.mode == .wysiwyg {
                    let style = mutableParagraphStyle()
                    style.lineSpacing = 2
                    // Rendered rows get vertical padding; the collapsed delimiter row gets none.
                    let padded = asGrid && line != table.delimiterLine
                    style.paragraphSpacingBefore = padded ? Self.tableRowPadding : 0
                    style.paragraphSpacing = padded ? Self.tableRowPadding : 0
                    storage.addAttribute(.paragraphStyle, value: style, range: line)
                }
            }
        }

        for line in spans.thematicBreaks {
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: line)
        }

        // Inline constructs.
        for range in spans.bold { addTrait(.bold, in: range, storage: storage) }
        for range in spans.italic { addTrait(.italic, in: range, storage: storage) }
        for range in spans.strikethrough {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        for range in spans.inlineCode {
            convertToMonospaced(in: range, storage: storage)
            storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: range)
        }
        for link in spans.links {
            if link.isImage {
                storage.addAttribute(.foregroundColor, value: theme.accentColor, range: link.text)
            } else {
                storage.addAttribute(.link, value: link.destination as NSString, range: link.text)
            }
        }

        for range in spans.html where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: range)
        }

        // Tables after inline styling so cell measurements use their final fonts.
        for table in spans.tables {
            styleTable(table, storage: storage, asGrid: rendersAsGrid(table, activeRegion: activeRegion), hiddenMarkers: spans.markers)
        }

        // Markers last so they pick up the font of their surroundings.
        for marker in spans.markers where marker.length > 0 && NSMaxRange(marker) <= storage.length {
            let visibleFont = storage.attribute(.font, at: marker.location, effectiveRange: nil) as? NSFont ?? theme.baseFont
            storage.addAttribute(.markdownMarker, value: visibleFont, range: marker)
            let isActive = activeRegion.map { intersects($0, marker) } ?? true
            if theme.hidesMarkers && !isActive {
                storage.addAttribute(.markdownHidden, value: true, range: marker)
            } else {
                storage.addAttribute(.foregroundColor, value: theme.markerColor, range: marker)
            }
        }

        storage.endEditing()
    }

    /// Shows or hides the markers inside `range` without restyling anything else.
    func setMarkersVisible(_ visible: Bool, in range: NSRange, storage: NSTextStorage) {
        guard theme.hidesMarkers, range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.markdownMarker, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            if visible {
                storage.removeAttribute(.markdownHidden, range: subrange)
                storage.addAttribute(.foregroundColor, value: theme.markerColor, range: subrange)
            } else {
                storage.addAttribute(.markdownHidden, value: true, range: subrange)
            }
        }
        storage.endEditing()
    }

    /// Whether a table is drawn as a grid (caret elsewhere) rather than as aligned source.
    func rendersAsGrid(_ table: MarkdownSpans.Table, activeRegion: NSRange?) -> Bool {
        guard theme.mode == .wysiwyg else { return false }
        guard let activeRegion else { return false }
        return !intersects(activeRegion, table.range)
    }

    // MARK: - Code blocks

    /// Colours the tokens of a fenced code block according to its info string.
    private func highlightCode(in block: MarkdownSpans.CodeBlock, storage: NSTextStorage) {
        guard let openingFence = block.fenceLines.first else { return }
        let ns = storage.string as NSString
        let contentStart = min(NSMaxRange(openingFence) + 1, NSMaxRange(block.range))
        let contentEnd = block.fenceLines.count > 1 ? block.fenceLines[1].location : NSMaxRange(block.range)
        guard contentEnd > contentStart, contentEnd <= storage.length else { return }

        let contentRange = NSRange(location: contentStart, length: contentEnd - contentStart)
        let code = ns.substring(with: contentRange)
        for token in CodeHighlighter.tokens(in: code, language: block.language) {
            let range = NSRange(location: contentStart + token.range.location, length: token.range.length)
            guard NSMaxRange(range) <= contentEnd else { continue }
            storage.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind), range: range)
        }
    }

    // MARK: - Tables

    private struct TableCell {
        var range: NSRange
        var closingPipe: NSRange?
    }

    private func styleTable(_ table: MarkdownSpans.Table, storage: NSTextStorage, asGrid: Bool, hiddenMarkers: [NSRange]) {
        guard NSMaxRange(table.range) <= storage.length else { return }
        addTrait(.bold, in: table.headerLine, storage: storage)

        guard asGrid else {
            storage.addAttribute(.markdownTableHeader, value: true, range: table.headerLine)
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: table.delimiterLine)
            for pipe in table.pipes {
                storage.addAttribute(.foregroundColor, value: theme.markerColor, range: pipe)
            }
            return
        }

        // Rendered grid: pipes become invisible spacers whose advance is set by kerning so
        // every column occupies the same slot on every row, and the delimiter row collapses
        // to a sliver. The layout manager draws the grid at the slot boundaries.
        storage.addAttribute(.markdownTableGrid, value: true, range: table.range)
        for pipe in table.pipes {
            storage.addAttributes([.foregroundColor: NSColor.clear, .markdownTablePipe: true], range: pipe)
        }
        var delimiter = table.delimiterLine
        if NSMaxRange(delimiter) < storage.length { delimiter.length += 1 } // include its newline
        storage.addAttributes([.font: NSFont.systemFont(ofSize: 2), .foregroundColor: NSColor.clear], range: delimiter)

        let ns = storage.string as NSString
        let alignments = MarkdownTableFormatter.cells(in: ns.substring(with: table.delimiterLine))
            .map(MarkdownTableFormatter.alignment(ofDelimiterCell:))
        let rows = table.lines
            .filter { $0 != table.delimiterLine }
            .map { cells(inLine: $0, pipes: table.pipes, ns: ns) }

        // Visible width of each cell (hidden syntax such as `**` takes no space on screen).
        func visibleWidth(_ range: NSRange) -> CGFloat {
            var total = width(of: range, in: storage)
            for marker in hiddenMarkers {
                let overlap = NSIntersectionRange(marker, range)
                if overlap.length > 0 { total -= width(of: overlap, in: storage) }
            }
            return max(0, total)
        }

        var slots: [CGFloat] = []
        for row in rows {
            for (column, cell) in row.enumerated() {
                let cellWidth = visibleWidth(cell.range) + Self.tableCellPadding
                if column >= slots.count { slots.append(cellWidth) } else { slots[column] = max(slots[column], cellWidth) }
            }
        }

        // Each pipe's advance becomes: space after the cell on its left + space before the
        // cell on its right. A pipe at the start or end of a row only has one side.
        var targetAdvance: [Int: CGFloat] = [:]
        for row in rows {
            for (column, cell) in row.enumerated() {
                let slack = slots[column] - visibleWidth(cell.range)
                let alignment = column < alignments.count ? alignments[column] : .none
                let before: CGFloat
                switch alignment {
                case .right: before = slack - Self.tableCellPadding / 2
                case .center: before = slack / 2
                case .left, .none: before = Self.tableCellPadding / 2
                }
                let after = slack - before
                if cell.range.location > 0, storage.attribute(.markdownTablePipe, at: cell.range.location - 1, effectiveRange: nil) != nil {
                    targetAdvance[cell.range.location - 1, default: 0] += before
                }
                if let pipe = cell.closingPipe {
                    targetAdvance[pipe.location, default: 0] += after
                }
            }
        }
        for (location, advance) in targetAdvance where location < storage.length {
            let glyphWidth = width(of: NSRange(location: location, length: 1), in: storage)
            storage.addAttribute(.kern, value: advance - glyphWidth, range: NSRange(location: location, length: 1))
        }

        // Cumulative column boundaries, relative to the start of each row.
        var edges: [CGFloat] = []
        var runningEdge: CGFloat = 0
        for slot in slots {
            runningEdge += slot
            edges.append(runningEdge)
        }
        storage.addAttribute(.markdownTableColumns, value: edges.map { NSNumber(value: Double($0)) }, range: table.range)
    }

    /// Splits a table line into cells by its pipes, skipping the blank segments outside
    /// a leading or trailing pipe.
    private func cells(inLine line: NSRange, pipes: [NSRange], ns: NSString) -> [TableCell] {
        let linePipes = pipes.filter { NSLocationInRange($0.location, line) }
        var cells: [TableCell] = []
        var start = line.location
        for pipe in linePipes {
            let range = NSRange(location: start, length: pipe.location - start)
            let isBlankLeading = cells.isEmpty && ns.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty
            if !isBlankLeading {
                cells.append(TableCell(range: range, closingPipe: pipe))
            }
            start = NSMaxRange(pipe)
        }
        let tail = NSRange(location: start, length: NSMaxRange(line) - start)
        if tail.length > 0, !ns.substring(with: tail).trimmingCharacters(in: .whitespaces).isEmpty {
            cells.append(TableCell(range: tail, closingPipe: nil))
        }
        return cells
    }

    // MARK: - Helpers

    private func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        NSIntersectionRange(a, b).length > 0 || (b.length > 0 && NSLocationInRange(b.location, a)) || b.location == NSMaxRange(a)
    }

    private func mutableParagraphStyle() -> NSMutableParagraphStyle {
        // swiftlint:disable:next force_cast
        theme.baseParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
    }

    private func width(of range: NSRange, in storage: NSTextStorage) -> CGFloat {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return 0 }
        return storage.attributedSubstring(from: range).size().width
    }

    private func width(of string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, in range: NSRange, storage: NSTextStorage) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
            if let styled = NSFont(descriptor: descriptor, size: font.pointSize) {
                storage.addAttribute(.font, value: styled, range: subrange)
            }
        }
    }

    private func convertToMonospaced(in range: NSRange, storage: NSTextStorage) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            let size = font.pointSize * (theme.mode == .wysiwyg ? 0.9 : 1)
            var mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            if font.fontDescriptor.symbolicTraits.contains(.bold) {
                mono = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
            }
            storage.addAttribute(.font, value: mono, range: subrange)
        }
    }
}
