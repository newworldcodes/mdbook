//
//  MarkdownBlockParser.swift
//  mdbook
//
//  Converts GitHub Flavored Markdown into a block tree using Foundation's
//  markdown parser (cmark-gfm under the hood). The tree is what the rendered
//  preview draws.
//

import Foundation

nonisolated enum MarkdownTextAlignment: Hashable, Sendable {
    case left, center, right
}

nonisolated enum MarkdownInlineSegment: Hashable, Sendable {
    case text(AttributedString)
    case image(source: String, alt: String)
}

nonisolated enum MarkdownTaskState: Hashable, Sendable {
    case unchecked
    case checked
}

nonisolated struct MarkdownListItem: Hashable, Sendable {
    var ordinal: Int
    var task: MarkdownTaskState?
    var blocks: [MarkdownBlock]
}

nonisolated struct MarkdownTable: Hashable, Sendable {
    var alignments: [MarkdownTextAlignment]
    var header: [AttributedString]
    var rows: [[AttributedString]]
}

nonisolated indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, content: AttributedString)
    case paragraph([MarkdownInlineSegment])
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownBlock])
    case list(ordered: Bool, items: [MarkdownListItem])
    case table(MarkdownTable)
    case thematicBreak
}

nonisolated enum MarkdownBlockParser {
    /// A run of the parsed attributed string together with its block nesting,
    /// ordered from the outermost block to the innermost.
    private struct Run {
        var text: AttributedString
        var imageSource: String?
        var components: [PresentationIntent.IntentType]
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let prepared = LinkResolver.encodingSpacesInLinkDestinations(markdown)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        options.allowsExtendedAttributes = true
        guard let attributed = try? AttributedString(markdown: prepared, options: options) else {
            return [.paragraph([.text(AttributedString(markdown))])]
        }

        var runs: [Run] = []
        for run in attributed.runs {
            var piece = AttributedString(attributed[run.range])
            piece.presentationIntent = nil
            let components = (run.presentationIntent?.components ?? []).reversed()
            runs.append(Run(text: piece, imageSource: run.imageURL?.absoluteString, components: Array(components)))
        }
        return buildBlocks(runs[...], depth: 0)
    }

    // MARK: - Tree construction

    /// Splits `runs` into consecutive groups that share the same block at `depth`.
    private static func group(_ runs: ArraySlice<Run>, depth: Int) -> [ArraySlice<Run>] {
        var groups: [ArraySlice<Run>] = []
        var start = runs.startIndex
        var index = runs.startIndex
        var currentIdentity: Int? = runs.first.flatMap { identity(of: $0, depth: depth) }
        while index < runs.endIndex {
            let id = identity(of: runs[index], depth: depth)
            if id != currentIdentity {
                groups.append(runs[start..<index])
                start = index
                currentIdentity = id
            }
            index += 1
        }
        if start < runs.endIndex { groups.append(runs[start..<runs.endIndex]) }
        return groups
    }

    private static func identity(of run: Run, depth: Int) -> Int? {
        run.components.indices.contains(depth) ? run.components[depth].identity : nil
    }

    private static func buildBlocks(_ runs: ArraySlice<Run>, depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for part in group(runs, depth: depth) {
            guard let first = part.first else { continue }
            guard first.components.indices.contains(depth) else {
                blocks.append(.paragraph(segments(from: part)))
                continue
            }
            switch first.components[depth].kind {
            case .paragraph:
                blocks.append(.paragraph(segments(from: part)))
            case .header(let level):
                blocks.append(.heading(level: level, content: mergedText(from: part)))
            case .codeBlock(let languageHint):
                var code = part.map { String($0.text.characters) }.joined()
                if code.hasSuffix("\n") { code.removeLast() }
                let language = languageHint?.isEmpty == false ? languageHint : nil
                blocks.append(.codeBlock(language: language, code: code))
            case .blockQuote:
                blocks.append(.blockQuote(buildBlocks(part, depth: depth + 1)))
            case .orderedList:
                blocks.append(.list(ordered: true, items: buildListItems(part, depth: depth + 1)))
            case .unorderedList:
                blocks.append(.list(ordered: false, items: buildListItems(part, depth: depth + 1)))
            case .listItem:
                // A list item without an enclosing list; treat it as an unordered list.
                blocks.append(.list(ordered: false, items: buildListItems(part, depth: depth)))
            case .table(let columns):
                blocks.append(.table(buildTable(part, columns: columns, depth: depth + 1)))
            case .thematicBreak:
                blocks.append(.thematicBreak)
            default:
                blocks.append(.paragraph(segments(from: part)))
            }
        }
        return blocks
    }

    private static func buildListItems(_ runs: ArraySlice<Run>, depth: Int) -> [MarkdownListItem] {
        var items: [MarkdownListItem] = []
        for part in group(runs, depth: depth) {
            guard let first = part.first, first.components.indices.contains(depth),
                  case .listItem(let ordinal) = first.components[depth].kind else {
                items.append(MarkdownListItem(ordinal: items.count + 1, task: nil, blocks: buildBlocks(part, depth: depth)))
                continue
            }
            var blocks = buildBlocks(part, depth: depth + 1)
            let task = extractTaskState(from: &blocks)
            items.append(MarkdownListItem(ordinal: ordinal, task: task, blocks: blocks))
        }
        return items
    }

    /// GitHub task lists (`- [ ] item`) come through as literal text; detect and strip them.
    private static func extractTaskState(from blocks: inout [MarkdownBlock]) -> MarkdownTaskState? {
        guard case .paragraph(var segments) = blocks.first,
              case .text(var text) = segments.first else { return nil }
        let plain = String(text.characters)
        let state: MarkdownTaskState
        let prefixLength: Int
        if plain.hasPrefix("[ ] ") || plain == "[ ]" {
            state = .unchecked
            prefixLength = min(4, plain.count)
        } else if plain.hasPrefix("[x] ") || plain.hasPrefix("[X] ") || plain.lowercased() == "[x]" {
            state = .checked
            prefixLength = min(4, plain.count)
        } else {
            return nil
        }
        let cutoff = text.characters.index(text.startIndex, offsetBy: prefixLength)
        text.removeSubrange(text.startIndex..<cutoff)
        segments[0] = .text(text)
        blocks[0] = .paragraph(segments)
        return state
    }

    private static func buildTable(_ runs: ArraySlice<Run>, columns: [PresentationIntent.TableColumn], depth: Int) -> MarkdownTable {
        let alignments: [MarkdownTextAlignment] = columns.map {
            switch $0.alignment {
            case .center: return .center
            case .right: return .right
            default: return .left
            }
        }
        var header: [AttributedString] = Array(repeating: AttributedString(), count: columns.count)
        var rows: [[AttributedString]] = []

        for rowPart in group(runs, depth: depth) {
            guard let first = rowPart.first, first.components.indices.contains(depth) else { continue }
            var cells = Array(repeating: AttributedString(), count: max(columns.count, 1))
            for cellPart in group(rowPart, depth: depth + 1) {
                guard let cellFirst = cellPart.first, cellFirst.components.indices.contains(depth + 1),
                      case .tableCell(let columnIndex) = cellFirst.components[depth + 1].kind else { continue }
                if columnIndex < cells.count {
                    cells[columnIndex] = mergedText(from: cellPart)
                }
            }
            switch first.components[depth].kind {
            case .tableHeaderRow: header = cells
            case .tableRow: rows.append(cells)
            default: break
            }
        }
        return MarkdownTable(alignments: alignments, header: header, rows: rows)
    }

    // MARK: - Inline content

    private static func segments(from runs: ArraySlice<Run>) -> [MarkdownInlineSegment] {
        var segments: [MarkdownInlineSegment] = []
        var pending = AttributedString()
        for run in runs {
            if let source = run.imageSource {
                if !pending.characters.isEmpty {
                    segments.append(.text(pending))
                    pending = AttributedString()
                }
                segments.append(.image(source: source, alt: String(run.text.characters)))
            } else {
                pending.append(run.text)
            }
        }
        if !pending.characters.isEmpty || segments.isEmpty {
            segments.append(.text(pending))
        }
        return segments
    }

    private static func mergedText(from runs: ArraySlice<Run>) -> AttributedString {
        var result = AttributedString()
        for run in runs where run.imageSource == nil {
            result.append(run.text)
        }
        return result
    }
}
