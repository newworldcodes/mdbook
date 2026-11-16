//
//  MarkdownTableFormatter.swift
//  mdbook
//
//  Re-pads a GFM table so every row's pipes line up in a monospaced font.
//

import Foundation

nonisolated enum MarkdownTableFormatter {
    enum Alignment: Equatable {
        case none, left, center, right
    }

    /// Splits a table row into trimmed cell strings, ignoring escaped pipes and
    /// pipes inside inline code.
    static func cells(in line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                current.append(character)
                escaped = true
            case "`":
                inCode.toggle()
                current.append(character)
            case "|" where !inCode:
                cells.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        cells.append(current)

        // A leading / trailing pipe produces an empty outer cell; drop those.
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty, cells.count > 1 {
            cells.removeFirst()
        }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty, cells.count > 1 {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func alignment(ofDelimiterCell cell: String) -> Alignment {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let left = trimmed.hasPrefix(":")
        let right = trimmed.hasSuffix(":") && trimmed.count > 1
        switch (left, right) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return .none
        }
    }

    /// Returns the table with padded, aligned columns. `source` is the table's lines
    /// (header, delimiter, rows) joined by newlines; the result has the same line count.
    static func format(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        guard lines.count >= 2 else { return source }
        let indent = String(lines[0].prefix(while: { $0 == " " || $0 == "\t" }))

        let rows = lines.map(cells(in:))
        let alignments = rows[1].map(alignment(ofDelimiterCell:))
        let columnCount = rows.enumerated().map { $0.offset == 1 ? alignments.count : $0.element.count }.max() ?? 0
        guard columnCount > 0 else { return source }

        var widths = Array(repeating: 3, count: columnCount)
        for (index, row) in rows.enumerated() where index != 1 {
            for (column, cell) in row.enumerated() where column < columnCount {
                widths[column] = max(widths[column], cell.count)
            }
        }

        var output: [String] = []
        for (index, row) in rows.enumerated() {
            var pieces: [String] = []
            for column in 0..<columnCount {
                let width = widths[column]
                let align = column < alignments.count ? alignments[column] : .none
                if index == 1 {
                    pieces.append(delimiter(width: width, alignment: align))
                } else {
                    let cell = column < row.count ? row[column] : ""
                    pieces.append(pad(cell, to: width, alignment: align))
                }
            }
            output.append(indent + "| " + pieces.joined(separator: " | ") + " |")
        }
        return output.joined(separator: "\n")
    }

    private static func delimiter(width: Int, alignment: Alignment) -> String {
        switch alignment {
        case .none: return String(repeating: "-", count: width)
        case .left: return ":" + String(repeating: "-", count: width - 1)
        case .right: return String(repeating: "-", count: width - 1) + ":"
        case .center: return ":" + String(repeating: "-", count: max(1, width - 2)) + ":"
        }
    }

    private static func pad(_ text: String, to width: Int, alignment: Alignment) -> String {
        let missing = max(0, width - text.count)
        switch alignment {
        case .right:
            return String(repeating: " ", count: missing) + text
        case .center:
            let leading = missing / 2
            return String(repeating: " ", count: leading) + text + String(repeating: " ", count: missing - leading)
        case .none, .left:
            return text + String(repeating: " ", count: missing)
        }
    }
}
