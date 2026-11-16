//
//  MarkdownStyler.swift
//  mdbook
//
//  Applies `MarkdownSpans` to an `NSTextStorage` as attributes.
//

import AppKit

struct MarkdownStyler {
    let theme: EditorTheme

    /// Restyles the whole document. `activeRegion` is the paragraph containing the caret
    /// (widened to the whole table when the caret is inside one); markup there stays
    /// visible so the user can edit it. Tables drawn as grids are fitted to `tableWidth`.
    func applyAll(to storage: NSTextStorage, spans: MarkdownSpans, activeRegion: NSRange?, tableWidth: CGFloat = .greatestFiniteMagnitude) {
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
                    // Rendered tables reserve their own height in the layout (see
                    // `MarkdownTableRendering`), so their lines get no extra spacing.
                    let style = mutableParagraphStyle()
                    style.lineSpacing = asGrid ? 0 : 2
                    style.paragraphSpacingBefore = 0
                    style.paragraphSpacing = 0
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

        for table in spans.tables {
            styleTable(table, storage: storage, asGrid: rendersAsGrid(table, activeRegion: activeRegion))
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

        // Last, so cells are built from fully styled text with markers known.
        for table in spans.tables where rendersAsGrid(table, activeRegion: activeRegion) {
            renderTable(table, storage: storage, width: tableWidth)
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

    private func styleTable(_ table: MarkdownSpans.Table, storage: NSTextStorage, asGrid: Bool) {
        guard NSMaxRange(table.range) <= storage.length else { return }
        addTrait(.bold, in: table.headerLine, storage: storage)
        guard !asGrid else { return }
        storage.addAttribute(.markdownTableHeader, value: true, range: table.headerLine)
        storage.addAttribute(.foregroundColor, value: theme.markerColor, range: table.delimiterLine)
        for pipe in table.pipes {
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: pipe)
        }
    }

    /// Replaces a table's source with a drawn grid: builds the cells from the styled text,
    /// stores the rendering on the table and hides every source glyph. Line terminators stay
    /// visible to the layout so each row is still its own line fragment.
    private func renderTable(_ table: MarkdownSpans.Table, storage: NSTextStorage, width: CGFloat) {
        guard NSMaxRange(table.range) <= storage.length else { return }
        let ns = storage.string as NSString
        let alignments = MarkdownTableFormatter.cells(in: ns.substring(with: table.delimiterLine))
            .map(MarkdownTableFormatter.alignment(ofDelimiterCell:))
        let rows = table.lines
            .filter { $0 != table.delimiterLine }
            .map { line in
                cells(inLine: line, pipes: table.pipes, ns: ns).enumerated().map { column, cell in
                    let alignment = column < alignments.count ? alignments[column] : .none
                    return cellContent(cell, alignment: alignment, storage: storage)
                }
            }
        let font = theme.baseFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let rendering = MarkdownTableRendering(range: table.range, rows: rows, availableWidth: width, minimumLineHeight: lineHeight)

        storage.addAttribute(.markdownTableRendering, value: rendering, range: table.range)
        for line in table.lines {
            storage.addAttribute(.markdownHidden, value: true, range: line)
        }
    }

    /// A cell's visible text: its styled characters without markdown markers or the
    /// whitespace around them, aligned as its column says.
    private func cellContent(_ range: NSRange, alignment: MarkdownTableFormatter.Alignment, storage: NSTextStorage) -> MarkdownTableRendering.Cell {
        let text = NSMutableAttributedString()
        storage.enumerateAttribute(.markdownMarker, in: range, options: []) { marker, subrange, _ in
            guard marker == nil else { return }
            text.append(storage.attributedSubstring(from: subrange))
        }
        // `\|` is an escaped pipe; show the pipe.
        var escape = text.mutableString.range(of: "\\|")
        while escape.location != NSNotFound {
            text.deleteCharacters(in: NSRange(location: escape.location, length: 1))
            escape = text.mutableString.range(of: "\\|")
        }
        let whitespace = CharacterSet.whitespaces
        while text.length > 0, let scalar = UnicodeScalar(text.mutableString.character(at: 0)), whitespace.contains(scalar) {
            text.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        while text.length > 0, let scalar = UnicodeScalar(text.mutableString.character(at: text.length - 1)), whitespace.contains(scalar) {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }

        let full = NSRange(location: 0, length: text.length)
        for key: NSAttributedString.Key in [.markdownHidden, .markdownMarker, .markdownTableHeader, .kern, .cursor, .markdownTask] {
            text.removeAttribute(key, range: full)
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        switch alignment {
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        case .left, .none: style.alignment = .left
        }
        text.addAttribute(.paragraphStyle, value: style, range: full)

        // Place the caret at the start of the content rather than in the padding.
        let ns = storage.string as NSString
        var start = range.location
        while start < NSMaxRange(range), ns.character(at: start) == 0x20 || ns.character(at: start) == 0x09 { start += 1 }
        return MarkdownTableRendering.Cell(text: text, source: NSRange(location: start, length: 0))
    }

    /// Splits a table line into cells by its pipes, skipping the blank segments outside
    /// a leading or trailing pipe.
    private func cells(inLine line: NSRange, pipes: [NSRange], ns: NSString) -> [NSRange] {
        let linePipes = pipes.filter { NSLocationInRange($0.location, line) }
        var cells: [NSRange] = []
        var start = line.location
        for pipe in linePipes {
            let range = NSRange(location: start, length: pipe.location - start)
            let isBlankLeading = cells.isEmpty && ns.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty
            if !isBlankLeading {
                cells.append(range)
            }
            start = NSMaxRange(pipe)
        }
        let tail = NSRange(location: start, length: NSMaxRange(line) - start)
        if tail.length > 0, !ns.substring(with: tail).trimmingCharacters(in: .whitespaces).isEmpty {
            cells.append(tail)
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
