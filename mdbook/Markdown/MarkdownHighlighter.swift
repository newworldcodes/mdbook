//
//  MarkdownHighlighter.swift
//  mdbook
//
//  A line-oriented scanner that finds the ranges of markdown constructs in
//  source text. The editor uses these ranges to style text in place and to
//  hide syntax markers for a WYSIWYG feel. Ranges are UTF-16 `NSRange`s so
//  they can be applied directly to an `NSTextStorage`.
//

import Foundation

nonisolated struct MarkdownSpans: Sendable {
    struct Heading: Sendable {
        var level: Int
        var line: NSRange
        var content: NSRange
    }

    struct CodeBlock: Sendable {
        /// The full range including fence lines.
        var range: NSRange
        var fenceLines: [NSRange]
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
    /// Syntax markers that can be hidden when the containing paragraph is not being edited.
    var markers: [NSRange] = []
}

nonisolated enum MarkdownHighlighter {
    private struct Patterns {
        let fence = regex(#"^\s{0,3}(`{3,}|~{3,})"#)
        let atxHeading = regex(#"^\s{0,3}(#{1,6})(?:[ \t]+(.*?))??(?:[ \t]+#+)?[ \t]*$"#)
        let setextUnderline = regex(#"^\s{0,3}(=+|-+)\s*$"#)
        let blockQuote = regex(#"^\s{0,3}((?:>[ \t]?)+)"#)
        let thematicBreak = regex(#"^\s{0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
        let listItem = regex(#"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+|$)(\[[ xX]\](?=[ \t]|$))?"#)
        let tableDelimiter = regex(#"^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$"#)

        let codeSpan = regex(#"(`+)(.+?)\1"#)
        let image = regex(#"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)
        // The label may contain plain text or a nested image (badge-style links).
        let link = regex(#"(?<!!)\[((?:[^\[\]]|!\[[^\]]*\]\([^)]*\))+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)
        let autolink = regex(#"<((?:https?://|mailto:)[^>\s]+)>"#)
        let bareURL = regex(#"(?<![\w"(<\]/])https?://[^\s<>)]+"#)
        let boldItalic = regex(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
        let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
        let italicStar = regex(#"(?<![*\w\\])\*(?=[^\s*])(.+?)(?<=[^\s*\\])\*(?![*\w])"#)
        let italicUnderscore = regex(#"(?<![_\w\\])_(?=[^\s_])(.+?)(?<=[^\s_\\])_(?![_\w])"#)
        let strikethrough = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)

        private static func regex(_ pattern: String) -> NSRegularExpression {
            // Patterns are compile-time constants, so a failure here is a programming error.
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern)
        }
    }

    private static let patterns = Patterns()

    static func scan(_ text: String) -> MarkdownSpans {
        let ns = text as NSString
        var spans = MarkdownSpans()

        // Collect line ranges (excluding terminators) and the ranges including terminators.
        var lines: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lines.append(range)
        }
        if ns.length == 0 || ns.hasSuffix("\n") {
            lines.append(NSRange(location: ns.length, length: 0))
        }

        // First pass: table delimiter rows tell us which neighbouring lines form a table.
        var tableLineIndices = Set<Int>()
        for (index, line) in lines.enumerated() where index > 0 {
            guard !tableLineIndices.contains(index), line.length > 0, ns.substring(with: line).contains("-"),
                  patterns.tableDelimiter.firstMatch(in: text, range: line) != nil else { continue }
            let header = lines[index - 1]
            guard header.length > 0, ns.substring(with: header).contains("|") else { continue }
            var tableLines = [header, line]
            var next = index + 1
            while next < lines.count, lines[next].length > 0, ns.substring(with: lines[next]).contains("|") {
                tableLines.append(lines[next])
                next += 1
            }
            for tableIndex in (index - 1)..<next { tableLineIndices.insert(tableIndex) }
            guard let last = tableLines.last else { continue }
            spans.tables.append(.init(
                range: NSRange(location: header.location, length: NSMaxRange(last) - header.location),
                headerLine: header,
                delimiterLine: line,
                lines: tableLines,
                pipes: tableLines.flatMap { pipeRanges(in: $0, ns: ns) }
            ))
        }

        var fenceStart: Int?
        var fenceMarker = ""
        var fenceOpenLine = NSRange(location: 0, length: 0)
        var previousWasParagraph = false
        var previousLine = NSRange(location: 0, length: 0)

        for (index, line) in lines.enumerated() {
            let lineText = ns.substring(with: line)
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks swallow everything until the closing fence.
            if let start = fenceStart {
                if let match = patterns.fence.firstMatch(in: text, range: line),
                   ns.substring(with: match.range(at: 1)).hasPrefix(fenceMarker),
                   let fenceCharacter = fenceMarker.first,
                   trimmed.allSatisfy({ $0 == fenceCharacter }) {
                    let range = NSRange(location: start, length: NSMaxRange(line) - start)
                    spans.codeBlocks.append(.init(range: range, fenceLines: [fenceOpenLine, line]))
                    fenceStart = nil
                }
                previousWasParagraph = false
                continue
            }

            if let match = patterns.fence.firstMatch(in: text, range: line) {
                fenceStart = line.location
                fenceMarker = ns.substring(with: match.range(at: 1))
                fenceOpenLine = line
                previousWasParagraph = false
                previousLine = line
                continue
            }

            if trimmed.isEmpty {
                previousWasParagraph = false
                previousLine = line
                continue
            }

            if tableLineIndices.contains(index) {
                spans.tableLines.append(line)
                scanInline(text, ns: ns, in: line, into: &spans)
                previousWasParagraph = false
                previousLine = line
                continue
            }

            // Setext headings: a paragraph line followed by === or ---.
            if previousWasParagraph, let match = patterns.setextUnderline.firstMatch(in: text, range: line) {
                let level = ns.substring(with: match.range(at: 1)).hasPrefix("=") ? 1 : 2
                if let existing = spans.headings.firstIndex(where: { $0.line == previousLine }) {
                    spans.headings.remove(at: existing)
                }
                spans.headings.append(.init(level: level, line: previousLine, content: previousLine))
                spans.markers.append(line)
                previousWasParagraph = false
                previousLine = line
                continue
            }

            if patterns.thematicBreak.firstMatch(in: text, range: line) != nil {
                spans.thematicBreaks.append(line)
                previousWasParagraph = false
                previousLine = line
                continue
            }

            if let match = patterns.atxHeading.firstMatch(in: text, range: line) {
                let hashes = match.range(at: 1)
                let contentRange = match.range(at: 2)
                let content = contentRange.location == NSNotFound
                    ? NSRange(location: NSMaxRange(line), length: 0)
                    : contentRange
                spans.headings.append(.init(level: hashes.length, line: line, content: content))
                spans.markers.append(NSRange(location: line.location, length: content.location - line.location))
                if NSMaxRange(content) < NSMaxRange(line) {
                    spans.markers.append(NSRange(location: NSMaxRange(content), length: NSMaxRange(line) - NSMaxRange(content)))
                }
                scanInline(text, ns: ns, in: content, into: &spans)
                previousWasParagraph = false
                previousLine = line
                continue
            }

            var contentRange = line
            if let match = patterns.blockQuote.firstMatch(in: text, range: line) {
                let marker = match.range(at: 1)
                spans.blockQuotes.append(.init(line: line, marker: marker))
                contentRange = NSRange(location: NSMaxRange(marker), length: NSMaxRange(line) - NSMaxRange(marker))
            }

            if let match = patterns.listItem.firstMatch(in: text, range: contentRange) {
                let indent = match.range(at: 1).length
                let markerRange = NSRange(location: match.range(at: 2).location, length: NSMaxRange(match.range(at: 3)) - match.range(at: 2).location)
                let ordered = ns.substring(with: match.range(at: 2)).first?.isNumber == true
                let taskRange = match.range(at: 4).location == NSNotFound ? nil : match.range(at: 4)
                spans.listItems.append(.init(line: line, marker: markerRange, indent: indent, ordered: ordered, task: taskRange))
                let contentStart = NSMaxRange(match.range)
                contentRange = NSRange(location: contentStart, length: NSMaxRange(line) - contentStart)
            }

            scanInline(text, ns: ns, in: contentRange, into: &spans)
            previousWasParagraph = true
            previousLine = line
        }

        // An unterminated fence runs to the end of the document.
        if let start = fenceStart {
            spans.codeBlocks.append(.init(range: NSRange(location: start, length: ns.length - start), fenceLines: [fenceOpenLine]))
        }

        // Inline passes run per construct type; report links in document order.
        spans.links.sort { $0.text.location < $1.text.location }
        return spans
    }

    /// Positions of cell-separating pipes in a table line (escaped pipes and pipes in
    /// inline code don't count).
    private static func pipeRanges(in line: NSRange, ns: NSString) -> [NSRange] {
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

    // MARK: - Inline constructs

    private static func scanInline(_ text: String, ns: NSString, in range: NSRange, into spans: inout MarkdownSpans) {
        guard range.length > 0 else { return }
        var protected: [NSRange] = []

        func isFree(_ candidate: NSRange) -> Bool {
            !protected.contains { NSIntersectionRange($0, candidate).length > 0 }
        }

        for match in patterns.codeSpan.matches(in: text, range: range) where isFree(match.range) {
            let ticks = match.range(at: 1)
            spans.inlineCode.append(match.range(at: 2))
            spans.markers.append(ticks)
            spans.markers.append(NSRange(location: NSMaxRange(match.range) - ticks.length, length: ticks.length))
            protected.append(match.range)
        }

        for match in patterns.image.matches(in: text, range: range) where isFree(match.range) {
            let alt = match.range(at: 1)
            spans.links.append(.init(text: alt, destination: ns.substring(with: match.range(at: 2)), isImage: true))
            spans.markers.append(NSRange(location: match.range.location, length: alt.location - match.range.location))
            spans.markers.append(NSRange(location: NSMaxRange(alt), length: NSMaxRange(match.range) - NSMaxRange(alt)))
            protected.append(match.range)
        }

        for match in patterns.link.matches(in: text, range: range) {
            let label = match.range(at: 1)
            // Only the delimiters must be free: the label may legitimately wrap a protected image.
            let opening = NSRange(location: match.range.location, length: 1)
            let closing = NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label))
            guard isFree(opening), isFree(closing) else { continue }
            spans.links.append(.init(text: label, destination: ns.substring(with: match.range(at: 2)), isImage: false))
            spans.markers.append(opening)
            spans.markers.append(NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)))
            // Only the destination is protected so emphasis inside the label still works.
            protected.append(NSRange(location: match.range.location, length: 1))
            protected.append(NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)))
        }

        for match in patterns.autolink.matches(in: text, range: range) where isFree(match.range) {
            let url = match.range(at: 1)
            spans.links.append(.init(text: url, destination: ns.substring(with: url), isImage: false))
            spans.markers.append(NSRange(location: match.range.location, length: 1))
            spans.markers.append(NSRange(location: NSMaxRange(match.range) - 1, length: 1))
            protected.append(match.range)
        }

        for match in patterns.bareURL.matches(in: text, range: range) where isFree(match.range) {
            spans.links.append(.init(text: match.range, destination: ns.substring(with: match.range), isImage: false))
            protected.append(match.range)
        }

        for match in patterns.boldItalic.matches(in: text, range: range) where isFree(match.range) {
            let content = match.range(at: 2)
            spans.bold.append(content)
            spans.italic.append(content)
            appendDelimiters(match, content: content, into: &spans, protected: &protected)
        }

        for match in patterns.bold.matches(in: text, range: range) where isFree(match.range) {
            let content = match.range(at: 2)
            spans.bold.append(content)
            appendDelimiters(match, content: content, into: &spans, protected: &protected)
        }

        for regex in [patterns.italicStar, patterns.italicUnderscore] {
            for match in regex.matches(in: text, range: range) where isFree(match.range) {
                let content = match.range(at: 1)
                spans.italic.append(content)
                appendDelimiters(match, content: content, into: &spans, protected: &protected)
            }
        }

        for match in patterns.strikethrough.matches(in: text, range: range) where isFree(match.range) {
            let content = match.range(at: 1)
            spans.strikethrough.append(content)
            appendDelimiters(match, content: content, into: &spans, protected: &protected)
        }
    }

    /// Records the opening and closing delimiters around `content` as hideable markers.
    private static func appendDelimiters(_ match: NSTextCheckingResult, content: NSRange, into spans: inout MarkdownSpans, protected: inout [NSRange]) {
        let opening = NSRange(location: match.range.location, length: content.location - match.range.location)
        let closing = NSRange(location: NSMaxRange(content), length: NSMaxRange(match.range) - NSMaxRange(content))
        spans.markers.append(opening)
        spans.markers.append(closing)
        protected.append(opening)
        protected.append(closing)
    }
}
