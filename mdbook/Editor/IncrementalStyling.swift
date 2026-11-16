//
//  IncrementalStyling.swift
//  mdbook
//
//  Restyling only what an edit changed. The whole document is still rescanned (cmark is
//  fast), but the new spans are compared with the previous ones, shifted past the edit;
//  only the region whose styling differs is restyled and laid out again. Typing a word
//  touches one paragraph; opening a code fence still restyles everything after it.
//

import Foundation

nonisolated enum IncrementalStyling {
    /// One styled range and what about it affects the styling.
    struct Atom: Hashable {
        var kind: UInt8
        var range: NSRange
        var detail: Int

        func hash(into hasher: inout Hasher) {
            hasher.combine(kind)
            hasher.combine(range.location)
            hasher.combine(range.length)
            hasher.combine(detail)
        }

        static func == (lhs: Atom, rhs: Atom) -> Bool {
            lhs.kind == rhs.kind && lhs.range == rhs.range && lhs.detail == rhs.detail
        }
    }

    static func atoms(of spans: MarkdownSpans) -> [Atom] {
        var atoms: [Atom] = []
        func add(_ kind: UInt8, _ range: NSRange, _ detail: Int = 0) {
            atoms.append(Atom(kind: kind, range: range, detail: detail))
        }
        for block in spans.codeBlocks {
            var hasher = Hasher()
            hasher.combine(block.language)
            hasher.combine(block.fenceLines.count)
            add(0, block.range, hasher.finalize())
        }
        for heading in spans.headings { add(1, heading.line, heading.level &* 31 &+ heading.content.location) }
        for quote in spans.blockQuotes { add(2, quote.line, quote.marker.length &* 16 &+ quote.depth) }
        for item in spans.listItems {
            var hasher = Hasher()
            hasher.combine(item.marker.length)
            hasher.combine(item.indent)
            hasher.combine(item.ordered)
            hasher.combine(item.task?.location)
            add(3, item.line, hasher.finalize())
        }
        for table in spans.tables { add(4, table.range, table.pipes.count) }
        for line in spans.thematicBreaks { add(5, line) }
        for range in spans.bold { add(6, range) }
        for range in spans.italic { add(7, range) }
        for range in spans.strikethrough { add(8, range) }
        for range in spans.inlineCode { add(9, range) }
        for link in spans.links { add(link.isImage ? 11 : 10, link.range, link.destination.hashValue) }
        for range in spans.html { add(12, range) }
        for range in spans.footnoteReferences { add(13, range) }
        for range in spans.footnoteLabels { add(14, range) }
        for range in spans.math { add(15, range) }
        for range in spans.markers { add(16, range) }
        return atoms
    }

    /// The part of the new text whose styling changed, or nil if nothing did. `edit` is the
    /// edited range in the new text and `delta` the change in length; with no edit the two
    /// sets of spans are compared as they are.
    static func dirtyRange(old: MarkdownSpans, new: MarkdownSpans, edit: NSRange? = nil, delta: Int = 0) -> NSRange? {
        let edit = edit ?? NSRange(location: Int.max / 2, length: 0)
        let oldEditEnd = NSMaxRange(edit) - delta
        var changed: NSRange? = edit.location == Int.max / 2 ? nil : edit
        func include(_ range: NSRange) {
            changed = changed.map { NSUnionRange($0, range) } ?? range
        }
        var shifted = Set<Atom>()
        for var atom in atoms(of: old) {
            if atom.range.location >= oldEditEnd {
                atom.range.location += delta
            } else if NSMaxRange(atom.range) > edit.location {
                // Straddled the edit: whatever it styled there is dirty.
                atom.range.length = max(0, atom.range.length + delta)
                include(atom.range)
                continue
            }
            shifted.insert(atom)
        }
        let current = Set(atoms(of: new))
        for atom in current.symmetricDifference(shifted) {
            include(atom.range)
        }
        return changed
    }

    /// Widens `region` to whole paragraphs and to every block it touches, so a block is never
    /// half restyled.
    static func expand(_ region: NSRange, in ns: NSString, spans: MarkdownSpans) -> NSRange {
        let length = ns.length
        var blocks = spans.codeBlocks.map(\.range) + spans.tables.map(\.range) + spans.headings.map(\.line)
        blocks += spans.math + spans.html
        var result = NSIntersectionRange(region, NSRange(location: 0, length: length))
        if result.length == 0, region.location <= length {
            result = NSRange(location: min(region.location, length), length: 0)
        }
        var previous = NSRange(location: NSNotFound, length: 0)
        while result != previous {
            previous = result
            result = ns.paragraphRange(for: result)
            for block in blocks where NSIntersectionRange(block, result).length > 0
                || NSLocationInRange(block.location, result) || NSLocationInRange(result.location, block) {
                result = NSUnionRange(result, ns.paragraphRange(for: block))
            }
        }
        return result
    }
}

extension MarkdownSpans {
    /// These spans moved past an edit (`edit` in new coordinates, `delta` the change in
    /// length): ranges after it shift, ranges spanning it stretch. Used to keep styling
    /// sensible while a fresh scan of a large document runs in the background.
    nonisolated func shifted(past edit: NSRange, delta: Int) -> MarkdownSpans {
        let oldEnd = NSMaxRange(edit) - delta
        func map(_ range: NSRange) -> NSRange {
            if range.location >= oldEnd { return NSRange(location: range.location + delta, length: range.length) }
            if NSMaxRange(range) >= edit.location, range.location <= edit.location {
                return NSRange(location: range.location, length: max(0, range.length + delta))
            }
            return range
        }
        var spans = self
        spans.headings = headings.map { .init(level: $0.level, line: map($0.line), content: map($0.content)) }
        spans.codeBlocks = codeBlocks.map { .init(range: map($0.range), fenceLines: $0.fenceLines.map(map), language: $0.language) }
        spans.blockQuotes = blockQuotes.map { .init(line: map($0.line), marker: map($0.marker), depth: $0.depth) }
        spans.listItems = listItems.map { .init(line: map($0.line), marker: map($0.marker), indent: $0.indent, ordered: $0.ordered, task: $0.task.map(map)) }
        spans.tables = tables.map {
            .init(range: map($0.range), headerLine: map($0.headerLine), delimiterLine: map($0.delimiterLine), lines: $0.lines.map(map), pipes: $0.pipes.map(map))
        }
        spans.tableLines = tableLines.map(map)
        spans.thematicBreaks = thematicBreaks.map(map)
        spans.bold = bold.map(map)
        spans.italic = italic.map(map)
        spans.strikethrough = strikethrough.map(map)
        spans.inlineCode = inlineCode.map(map)
        spans.links = links.map { .init(text: map($0.text), destination: $0.destination, isImage: $0.isImage, range: map($0.range)) }
        spans.html = html.map(map)
        spans.footnoteReferences = footnoteReferences.map(map)
        spans.footnoteLabels = footnoteLabels.map(map)
        spans.math = math.map(map)
        spans.markers = markers.map(map)
        return spans
    }

    /// Only the spans that touch `region` (expanded so they lie inside it).
    nonisolated func limited(to region: NSRange) -> MarkdownSpans {
        func touches(_ range: NSRange) -> Bool {
            NSIntersectionRange(range, region).length > 0 || (range.length == 0 && NSLocationInRange(range.location, region))
        }
        var spans = MarkdownSpans()
        spans.headings = headings.filter { touches($0.line) }
        spans.codeBlocks = codeBlocks.filter { touches($0.range) }
        spans.blockQuotes = blockQuotes.filter { touches($0.line) }
        spans.listItems = listItems.filter { touches($0.line) }
        spans.tables = tables.filter { touches($0.range) }
        spans.tableLines = tableLines.filter(touches)
        spans.thematicBreaks = thematicBreaks.filter(touches)
        spans.bold = bold.filter(touches)
        spans.italic = italic.filter(touches)
        spans.strikethrough = strikethrough.filter(touches)
        spans.inlineCode = inlineCode.filter(touches)
        spans.links = links.filter { touches($0.range) }
        spans.html = html.filter(touches)
        spans.footnoteReferences = footnoteReferences.filter(touches)
        spans.footnoteLabels = footnoteLabels.filter(touches)
        spans.math = math.filter(touches)
        spans.markers = markers.filter(touches)
        return spans
    }
}
