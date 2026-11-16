//
//  MarkdownHighlighter.swift
//  mdbook
//
//  Finds the ranges of markdown constructs in source text by walking the swift-markdown
//  (cmark-gfm) syntax tree. The editor uses these ranges to style text in place and to
//  hide syntax markers for a WYSIWYG feel. Ranges are UTF-16 `NSRange`s so they can be
//  applied directly to an `NSTextStorage`.
//

import Foundation
import Markdown

nonisolated struct MarkdownSpans: Sendable {
    struct Heading: Sendable {
        var level: Int
        var line: NSRange
        var content: NSRange
    }

    struct CodeBlock: Sendable {
        /// The full range including fence lines.
        var range: NSRange
        /// The opening and (if present) closing fence. Empty for indented code blocks.
        var fenceLines: [NSRange]
        var language: String?
    }

    struct BlockQuote: Sendable {
        var line: NSRange
        var marker: NSRange
    }

    struct ListItem: Sendable {
        var line: NSRange
        var marker: NSRange
        var indent: Int
        var ordered: Bool
        /// The `[ ]` / `[x]` checkbox, if the item is a task.
        var task: NSRange?
    }

    struct Link: Sendable {
        var text: NSRange
        var destination: String
        var isImage: Bool
        /// The whole construct including its syntax (`![alt](src)`); equals `text` for bare URLs.
        var range: NSRange
    }

    struct Table: Sendable {
        /// From the start of the header line to the end of the last row (no trailing newline).
        var range: NSRange
        var headerLine: NSRange
        var delimiterLine: NSRange
        var lines: [NSRange]
        /// Every unescaped `|` outside inline code, across all lines.
        var pipes: [NSRange]

        func contains(_ location: Int) -> Bool {
            location >= range.location && location <= NSMaxRange(range)
        }
    }

    var headings: [Heading] = []
    var codeBlocks: [CodeBlock] = []
    var blockQuotes: [BlockQuote] = []
    var listItems: [ListItem] = []
    var tables: [Table] = []
    var tableLines: [NSRange] = []
    var thematicBreaks: [NSRange] = []
    var bold: [NSRange] = []
    var italic: [NSRange] = []
    var strikethrough: [NSRange] = []
    var inlineCode: [NSRange] = []
    var links: [Link] = []
    /// HTML blocks and inline tags, dimmed like syntax but never hidden.
    var html: [NSRange] = []
    /// The id inside each `[^id]` footnote reference (its brackets are markers).
    var footnoteReferences: [NSRange] = []
    /// The `[^id]:` label starting each footnote definition.
    var footnoteLabels: [NSRange] = []
    /// Inline `$…$` and display `$$…$$` math, dollars included.
    var math: [NSRange] = []
    /// Syntax markers that can be hidden when the containing paragraph is not being edited.
    var markers: [NSRange] = []
}

nonisolated enum MarkdownHighlighter {
    static func scan(_ text: String) -> MarkdownSpans {
        let document = Document(parsing: text, options: [.disableSmartOpts])
        var walker = SpanWalker(text: text, map: MarkdownSourceMap(text))
        walker.visit(document)
        walker.spans.links.sort { $0.text.location < $1.text.location }
        applyMath(to: &walker.spans, in: text)
        applyFootnoteDefinitions(to: &walker.spans, in: text)
        return walker.spans
    }

    /// Dims the `[^id]:` label of footnote definitions. cmark reads most of them as link
    /// reference definitions, which leave no node behind, so look at the lines directly.
    private static func applyFootnoteDefinitions(to spans: inout MarkdownSpans, in text: String) {
        guard text.contains("[^") else { return }
        let ns = text as NSString
        let code = spans.codeBlocks.map(\.range)
        var labels: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, lineRange, _, _ in
            guard let line, line.contains("]:"), let definition = MarkdownExtensions.footnoteDefinition(line),
                  !code.contains(where: { NSLocationInRange(lineRange.location, $0) }) else { return }
            let start = lineRange.location + (line.prefix { $0 == " " }.utf16.count)
            labels.append(NSRange(location: start, length: ("[^\(definition.id)]:" as NSString).length))
        }
        spans.footnoteLabels += labels
    }

    /// Finds math and drops what cmark wrongly parsed inside it (`$a_1 b_2$` isn't emphasis).
    private static func applyMath(to spans: inout MarkdownSpans, in text: String) {
        guard text.contains("$") else { return }
        let ns = text as NSString
        let code = spans.codeBlocks.map(\.range) + spans.inlineCode
        func inCode(_ range: NSRange) -> Bool {
            code.contains { NSIntersectionRange($0, range).length > 0 }
        }

        var math = MarkdownExtensions.inlineMathRanges(in: text).map(\.range).filter { !inCode($0) }
        // Display math: a line starting with $$ through the line ending with $$.
        var lineStart = 0
        var openLine: Int?
        while lineStart < ns.length {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !inCode(line) {
                if let start = openLine {
                    if content.hasSuffix("$$") {
                        math.append(NSRange(location: start, length: NSMaxRange(line) - start))
                        openLine = nil
                    }
                } else if content.hasPrefix("$$") {
                    if content.count > 2, content.dropFirst(2).hasSuffix("$$") {
                        math.append(line)
                    } else {
                        openLine = line.location
                    }
                }
            }
            lineStart = NSMaxRange(line)
        }
        guard !math.isEmpty else { return }
        // Trim line terminators so styling stays inside the lines.
        math = math.map { range in
            var range = range
            while range.length > 0, [0x0A, 0x0D].contains(ns.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
            return range
        }

        func outsideMath(_ range: NSRange) -> Bool {
            !math.contains { NSIntersectionRange($0, range).length > 0 }
        }
        spans.bold = spans.bold.filter(outsideMath)
        spans.italic = spans.italic.filter(outsideMath)
        spans.strikethrough = spans.strikethrough.filter(outsideMath)
        spans.markers = spans.markers.filter(outsideMath)
        spans.links = spans.links.filter { outsideMath($0.range) }
        spans.footnoteReferences = spans.footnoteReferences.filter(outsideMath)
        spans.math = math
    }

    /// Positions of cell-separating pipes in a table line (escaped pipes and pipes in
    /// inline code don't count).
    static func pipeRanges(in line: NSRange, ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var inCode = false
        var escaped = false
        var index = line.location
        while index < NSMaxRange(line) {
            let character = ns.character(at: index)
            if escaped {
                escaped = false
            } else if character == 0x5C { // backslash
                escaped = true
            } else if character == 0x60 { // backtick
                inCode.toggle()
            } else if character == 0x7C, !inCode { // pipe
                ranges.append(NSRange(location: index, length: 1))
            }
            index += 1
        }
        return ranges
    }
}

// MARK: - Tree walker

private nonisolated struct SpanWalker: MarkupWalker {
    /// The source, kept as a `String` so regex calls don't re-bridge it.
    let text: String
    let map: MarkdownSourceMap
    var spans = MarkdownSpans()

    /// The paragraph or heading whose inline content is being visited. See `offset(_:)`.
    private var leaf: (line: Int, column: Int, quoteDepth: Int)?
    private var quoteDepth = 0
    private var linkDepth = 0
    /// Set while inside a table header that cmark mis-placed onto the line of the paragraph
    /// it interrupted. See `MarkdownSourceMap.offset(flowingFrom:)`.
    private var headerFlowsFromLine: Int?
    /// The table cell being visited and the byte columns of each `\|` in it. GFM removes
    /// those backslashes before parsing the cell, so later inline columns come up short.
    private var cellEscapes: (line: Int, columns: [Int])?

    private static let quoteMarkers = regex(#"[ \t]*((?:>[ \t]?)+)"#)
    private static let checkbox = regex(#"\[[ xX]\]"#)
    private static let tableDelimiter = regex(#"[ \t]*(?:>[ \t]?)*[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)

    init(text: String, map: MarkdownSourceMap) {
        self.text = text
        self.map = map
    }

    private var ns: NSString { map.ns }

    // MARK: Positions

    /// UTF-16 offset of a source location inside the current leaf block.
    ///
    /// cmark reports every inline column as `leaf start column + offset into the line's
    /// content`, using the leaf's *first* line start for all its lines. On continuation
    /// lines whose content starts elsewhere (lists with checkboxes, tab-indented or deeper
    /// lazy lines) that is wrong, so re-base it on where the content of that line really
    /// starts: after up to `quoteDepth` `>` markers and any whitespace.
    private func offset(_ location: SourceLocation) -> Int {
        if let headerFlowsFromLine, location.line == headerFlowsFromLine {
            return map.offset(flowingFrom: location)
        }
        if let cellEscapes, location.line == cellEscapes.line {
            var column = location.column
            for escape in cellEscapes.columns where escape < column { column += 1 }
            return map.offset(line: location.line, column: column)
        }
        guard let leaf, location.line > leaf.line else { return map.offset(location) }
        let contentStart = contentStartColumn(onLine: location.line, quoteDepth: leaf.quoteDepth)
        return map.offset(line: location.line, column: location.column - leaf.column + contentStart)
    }

    /// 1-based UTF-8 column of the first content character of a line. Everything skipped
    /// is ASCII, so the UTF-16 distance equals the byte distance.
    private func contentStartColumn(onLine line: Int, quoteDepth: Int) -> Int {
        let lineRange = map.lineRange(line)
        let end = NSMaxRange(lineRange)
        var index = lineRange.location
        func skipWhitespace() {
            while index < end, ns.character(at: index) == 0x20 || ns.character(at: index) == 0x09 { index += 1 }
        }
        for _ in 0..<quoteDepth {
            skipWhitespace()
            guard index < end, ns.character(at: index) == 0x3E else { break } // >
            index += 1
            if index < end, ns.character(at: index) == 0x20 || ns.character(at: index) == 0x09 { index += 1 }
        }
        skipWhitespace()
        return index - lineRange.location + 1
    }

    private func inlineRange(_ markup: Markup) -> NSRange? {
        guard let range = markup.range else { return nil }
        let start = offset(range.lowerBound)
        let end = offset(range.upperBound)
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The span covered by a node's children: its content without delimiters.
    private func childrenRange(_ markup: Markup) -> NSRange? {
        let ranges = markup.children.compactMap(inlineRange)
        guard let start = ranges.map(\.location).min(), let end = ranges.map(NSMaxRange).max() else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func blockLines(_ markup: Markup) -> ClosedRange<Int>? {
        markup.range.map(map.lines(of:))
    }

    private func consists(_ range: NSRange, of characters: Set<unichar>) -> Bool {
        (range.location..<NSMaxRange(range)).allSatisfy { characters.contains(ns.character(at: $0)) }
    }

    private mutating func addMarker(_ range: NSRange) {
        if range.length > 0 { spans.markers.append(range) }
    }

    /// Splits `outer` around `inner` into opening and closing delimiters.
    private func delimiters(_ outer: NSRange, around inner: NSRange) -> (opening: NSRange, closing: NSRange)? {
        guard inner.location >= outer.location, NSMaxRange(inner) <= NSMaxRange(outer) else { return nil }
        return (
            NSRange(location: outer.location, length: inner.location - outer.location),
            NSRange(location: NSMaxRange(inner), length: NSMaxRange(outer) - NSMaxRange(inner))
        )
    }

    // MARK: Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) {
        withLeaf(paragraph) { $0.descendInto(paragraph) }
    }

    mutating func visitHeading(_ heading: Heading) {
        defer { withLeaf(heading) { $0.descendInto(heading) } }
        guard let range = heading.range else { return }
        let content = withLeaf(heading) { $0.childrenRange(heading) }

        // A setext underline is the line after the last line of content. (cmark's range for
        // a multi-line setext heading can run on into the next block, so don't trust it.)
        let lastContentLine = heading.children.compactMap(\.range?.upperBound.line).max() ?? range.lowerBound.line
        let underline = lastContentLine + 1
        let isSetext = underline <= min(range.upperBound.line, map.lineCount)
            && isSetextUnderline(ns.substring(with: map.lineRange(underline)))

        if !isSetext {
            // ATX: `## Title ##`
            let line = map.lineRange(range.lowerBound.line)
            let start = map.offset(range.lowerBound)
            let content = content ?? NSRange(location: NSMaxRange(line), length: 0)
            spans.headings.append(.init(level: heading.level, line: line, content: content))
            addMarker(NSRange(location: start, length: content.location - start))
            addMarker(NSRange(location: NSMaxRange(content), length: NSMaxRange(line) - NSMaxRange(content)))
        } else {
            // Setext: text lines followed by a `===` or `---` underline.
            let line = map.range(ofLines: range.lowerBound.line...lastContentLine)
            spans.headings.append(.init(level: heading.level, line: line, content: content ?? line))
            addMarker(map.lineRange(underline))
        }
    }

    private func isSetextUnderline(_ line: String) -> Bool {
        let underline = line.drop { $0 == " " || $0 == "\t" || $0 == ">" }.trimmingCharacters(in: .whitespaces)
        guard let first = underline.first, first == "=" || first == "-" else { return false }
        return underline.allSatisfy { $0 == first }
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let range = codeBlock.range, let lines = blockLines(codeBlock) else { return }
        let firstLine = map.lineRange(lines.lowerBound)
        let start = map.offset(range.lowerBound)
        let opening = ns.substring(with: NSRange(location: start, length: NSMaxRange(firstLine) - start))
            .trimmingCharacters(in: .whitespaces)
        var fenceLines: [NSRange] = []

        if let fenceCharacter = opening.first, fenceCharacter == "`" || fenceCharacter == "~" {
            fenceLines.append(firstLine)
            let fenceLength = opening.prefix { $0 == fenceCharacter }.count
            if lines.count > 1 {
                let lastLine = map.lineRange(lines.upperBound)
                let closing = ns.substring(with: lastLine).drop { $0 == " " || $0 == "\t" || $0 == ">" }
                    .trimmingCharacters(in: .whitespaces)
                if closing.count >= fenceLength, closing.allSatisfy({ $0 == fenceCharacter }) {
                    fenceLines.append(lastLine)
                }
            }
        }

        // `language` is the whole info string (`rust title="x"`); the first word names it.
        let language = codeBlock.language?.split(whereSeparator: \.isWhitespace).first.map(String.init)
        spans.codeBlocks.append(.init(range: map.range(ofLines: lines), fenceLines: fenceLines, language: language))
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        guard let lines = blockLines(html) else { return }
        spans.html.append(map.range(ofLines: lines))
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        guard let lines = blockLines(thematicBreak) else { return }
        spans.thematicBreaks.append(map.range(ofLines: lines))
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        // Nested quotes share their outer quote's `> > ` marker run, so only the outermost
        // quote records lines.
        if quoteDepth == 0, let range = blockQuote.range, let lines = blockLines(blockQuote) {
            for lineNumber in lines {
                let line = map.lineRange(lineNumber)
                let start = lineNumber == lines.lowerBound ? map.offset(range.lowerBound) : line.location
                let searchRange = NSRange(location: start, length: NSMaxRange(line) - start)
                let marker = Self.quoteMarkers.firstMatch(in: text, options: .anchored, range: searchRange)?.range(at: 1)
                    // A lazy continuation line has no marker of its own.
                    ?? NSRange(location: start, length: 0)
                spans.blockQuotes.append(.init(line: line, marker: marker))
            }
        }
        quoteDepth += 1
        descendInto(blockQuote)
        quoteDepth -= 1
    }

    mutating func visitListItem(_ listItem: ListItem) {
        defer { descendInto(listItem) }
        guard let range = listItem.range else { return }
        let line = map.lineRange(range.lowerBound.line)
        let start = map.offset(range.lowerBound)
        var contentStart = NSMaxRange(line)
        if let first = listItem.child(at: 0)?.range, first.lowerBound.line == range.lowerBound.line {
            contentStart = map.offset(first.lowerBound)
        }
        guard contentStart >= start else { return }
        let gap = NSRange(location: start, length: contentStart - start)

        var marker = gap
        var task: NSRange?
        if listItem.checkbox != nil, let box = Self.checkbox.firstMatch(in: text, range: gap)?.range {
            task = box
            marker = NSRange(location: start, length: box.location - start)
        }

        // Indentation of the bullet, not counting any block quote markers before it.
        let prefix = NSRange(location: line.location, length: start - line.location)
        let quotePrefix = Self.quoteMarkers.firstMatch(in: text, options: .anchored, range: prefix)?.range ?? NSRange(location: line.location, length: 0)
        let indent = prefix.length - quotePrefix.length

        spans.listItems.append(.init(line: line, marker: marker, indent: indent, ordered: listItem.parent is OrderedList, task: task))
    }

    mutating func visitTable(_ table: Markdown.Table) {
        guard var lines = blockLines(table).map(Array.init) else {
            descendInto(table)
            return
        }
        // When a table interrupts a paragraph, cmark starts its range (and reports its header)
        // on the paragraph's first line. The header really is the line above the delimiter row.
        let reportedStart = lines[0]
        if let delimiterIndex = lines.firstIndex(where: { line in
            Self.tableDelimiter.firstMatch(in: text, options: .anchored, range: map.lineRange(line)) != nil
        }), delimiterIndex >= 1 {
            lines.removeFirst(delimiterIndex - 1)
        }
        while let last = lines.last, lines.count > 2, ns.substring(with: map.lineRange(last)).trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if lines[0] != reportedStart { headerFlowsFromLine = reportedStart }
        descendInto(table)
        headerFlowsFromLine = nil
        guard lines.count >= 2 else { return }
        let lineRanges = lines.map(map.lineRange)
        spans.tables.append(.init(
            range: map.range(ofLines: lines[0]...lines[lines.count - 1]),
            headerLine: lineRanges[0],
            delimiterLine: lineRanges[1],
            lines: lineRanges,
            pipes: lineRanges.flatMap { MarkdownHighlighter.pipeRanges(in: $0, ns: ns) }
        ))
        spans.tableLines.append(contentsOf: lineRanges)
    }

    mutating func visitTableCell(_ cell: Markdown.Table.Cell) {
        if let range = cell.range, range.lowerBound.line != headerFlowsFromLine {
            let line = map.lineRange(range.lowerBound.line)
            if ns.range(of: "\\|", options: .literal, range: line).location != NSNotFound {
                let bytes = Array(ns.substring(with: line).utf8)
                let cellBytes = max(0, range.lowerBound.column - 1)..<min(bytes.count, range.upperBound.column - 1)
                let columns = cellBytes.filter { $0 + 1 < bytes.count && bytes[$0] == 0x5C && bytes[$0 + 1] == 0x7C }.map { $0 + 1 }
                cellEscapes = (range.lowerBound.line, columns)
            }
        }
        withLeaf(cell) { $0.descendInto(cell) }
        cellEscapes = nil
    }

    /// Runs `body` with `markup` as the leaf block that inline positions are relative to.
    private mutating func withLeaf<Result>(_ markup: Markup, _ body: (inout SpanWalker) -> Result) -> Result {
        let saved = leaf
        if let start = markup.range?.lowerBound {
            leaf = (start.line, start.column, quoteDepth)
        }
        defer { leaf = saved }
        return body(&self)
    }

    // MARK: Inlines

    mutating func visitStrong(_ strong: Strong) {
        delimited(strong, by: [0x2A, 0x5F], into: \.bold) // * _
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        delimited(emphasis, by: [0x2A, 0x5F], into: \.italic)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        delimited(strikethrough, by: [0x7E], into: \.strikethrough) // ~
    }

    /// Records the content of an emphasis-like node and hides its delimiters, provided the
    /// delimiters really are the expected characters (guards against bad source positions).
    private mutating func delimited(_ markup: Markup, by characters: Set<unichar>, into keyPath: WritableKeyPath<MarkdownSpans, [NSRange]>) {
        defer { descendInto(markup) }
        guard let outer = inlineRange(markup), let inner = childrenRange(markup),
              let (opening, closing) = delimiters(outer, around: inner),
              consists(opening, of: characters), consists(closing, of: characters) else { return }
        spans[keyPath: keyPath].append(inner)
        addMarker(opening)
        addMarker(closing)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let outer = inlineRange(inlineCode), outer.length >= 2 else { return }
        let backtick: unichar = 0x60
        var ticks = 0
        while ticks < outer.length, ns.character(at: outer.location + ticks) == backtick { ticks += 1 }
        guard ticks > 0, outer.length >= ticks * 2,
              consists(NSRange(location: NSMaxRange(outer) - ticks, length: ticks), of: [backtick]) else { return }
        spans.inlineCode.append(NSRange(location: outer.location + ticks, length: outer.length - ticks * 2))
        addMarker(NSRange(location: outer.location, length: ticks))
        addMarker(NSRange(location: NSMaxRange(outer) - ticks, length: ticks))
    }

    mutating func visitLink(_ link: Link) {
        // `[^id]` with a matching `[^id]: …` line is a shortcut reference link to cmark
        // (the definition reads as a link reference definition); it's a footnote.
        if let outer = inlineRange(link), outer.length > 3, ns.character(at: outer.location + 1) == 0x5E, // ^
           ns.character(at: NSMaxRange(outer) - 1) == 0x5D { // ]
            spans.footnoteReferences.append(NSRange(location: outer.location + 2, length: outer.length - 3))
            addMarker(NSRange(location: outer.location, length: 2))
            addMarker(NSRange(location: NSMaxRange(outer) - 1, length: 1))
            return
        }
        defer {
            linkDepth += 1
            descendInto(link)
            linkDepth -= 1
        }
        // An empty label (`[](x)`) has nothing to show, so leave its syntax visible.
        guard let outer = inlineRange(link), let inner = childrenRange(link),
              let (opening, closing) = delimiters(outer, around: inner), opening.length > 0,
              [0x5B, 0x3C].contains(ns.character(at: opening.location)) else { return } // [ <
        spans.links.append(.init(text: inner, destination: link.destination ?? "", isImage: false, range: outer))
        addMarker(opening)
        addMarker(closing)
    }

    mutating func visitImage(_ image: Image) {
        defer {
            linkDepth += 1
            descendInto(image)
            linkDepth -= 1
        }
        guard let outer = inlineRange(image), let inner = childrenRange(image),
              let (opening, closing) = delimiters(outer, around: inner), opening.length >= 2,
              ns.character(at: opening.location) == 0x21 else { return } // !
        spans.links.append(.init(text: inner, destination: image.source ?? "", isImage: true, range: outer))
        addMarker(opening)
        addMarker(closing)
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        if let range = inlineRange(inlineHTML) { spans.html.append(range) }
    }

    mutating func visitText(_ textNode: Markdown.Text) {
        guard linkDepth == 0, let range = inlineRange(textNode), range.length > 0 else { return }
        for url in LinkResolver.bareURLs(in: text, range: range) {
            spans.links.append(.init(text: url, destination: ns.substring(with: url), isImage: false, range: url))
        }
        // `[^id]` footnote references: hide the brackets, raise the id.
        for (reference, id) in MarkdownExtensions.footnoteReferences(in: text, range: range) {
            spans.footnoteReferences.append(id)
            addMarker(NSRange(location: reference.location, length: id.location - reference.location))
            addMarker(NSRange(location: NSMaxRange(id), length: NSMaxRange(reference) - NSMaxRange(id)))
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants, so a failure here is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }
}
