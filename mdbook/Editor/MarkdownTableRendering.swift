//
//  MarkdownTableRendering.swift
//  mdbook
//
//  A table laid out to fit the editor's width, with cells that wrap. When the caret is
//  outside a table, the styler hides the table's source glyphs and stores one of these on
//  its characters; the coordinator reserves its height as the first line fragment and the
//  layout manager draws it there. The text storage still holds only the markdown source.
//

import AppKit

final class MarkdownTableRendering: NSObject {
    struct Cell {
        var text: NSAttributedString
        /// Where the cell's content lives in the source, for placing the caret on click.
        var source: NSRange
    }

    static let padding = NSSize(width: 10, height: 6)
    /// Space above and below the drawn table.
    static let margin: CGFloat = 4

    /// The table's source (without the final line terminator).
    let range: NSRange
    var location: Int { range.location }
    /// Height of any visible content sharing the table's line fragment above it (the
    /// hidden header's glyphs join the fragment of the line before). Set during layout.
    var offsetInFragment: CGFloat = 0
    /// The header row first.
    let rows: [[Cell]]
    let columnWidths: [CGFloat]
    let rowHeights: [CGFloat]

    var tableSize: NSSize {
        NSSize(width: columnWidths.reduce(0, +), height: rowHeights.reduce(0, +))
    }

    /// The height to reserve in the text layout.
    var reservedHeight: CGFloat { tableSize.height + Self.margin * 2 }

    /// Measures `rows` (each padded to the header's column count) and fits them to `width`.
    init(range: NSRange, rows: [[Cell]], availableWidth: CGFloat, minimumLineHeight: CGFloat) {
        let location = range.location
        let columns = max(rows.first?.count ?? 1, 1)
        let rows = rows.map { row in
            Array((row + Array(repeating: Cell(text: NSAttributedString(), source: NSRange(location: location, length: 0)), count: max(0, columns - row.count))).prefix(columns))
        }
        let horizontalPadding = Self.padding.width * 2

        var natural = Array(repeating: horizontalPadding, count: columns)
        var minimum = Array(repeating: horizontalPadding, count: columns)
        for row in rows {
            for (column, cell) in row.enumerated() {
                natural[column] = max(natural[column], ceil(cell.text.size().width) + horizontalPadding)
                minimum[column] = max(minimum[column], Self.longestRunWidth(in: cell.text) + horizontalPadding)
            }
        }
        let widths = TableColumnSizer.widths(natural: natural, minimum: minimum, available: availableWidth)

        self.range = range
        self.rows = rows
        self.columnWidths = widths
        self.rowHeights = rows.map { row in
            let tallest = row.enumerated().map { column, cell in
                cell.text.length == 0 ? 0 : ceil(cell.text.boundingRect(
                    with: NSSize(width: max(1, widths[column] - horizontalPadding), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height)
            }.max() ?? 0
            return max(tallest, minimumLineHeight) + Self.padding.height * 2
        }
    }

    // MARK: Drawing

    /// Draws the table with its top-left corner at `frame.origin` (flipped coordinates).
    func draw(in frame: NSRect, headerFill: NSColor, gridColor: NSColor) {
        guard let headerHeight = rowHeights.first else { return }
        NSGraphicsContext.saveGraphicsState()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        outline.addClip()

        headerFill.setFill()
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: headerHeight).fill()

        let grid = NSBezierPath()
        grid.lineWidth = 1
        var y = frame.minY
        for (rowIndex, row) in rows.enumerated() {
            var x = frame.minX
            for (column, cell) in row.enumerated() {
                let textRect = NSRect(
                    x: x + Self.padding.width,
                    y: y + Self.padding.height,
                    width: columnWidths[column] - Self.padding.width * 2,
                    height: rowHeights[rowIndex] - Self.padding.height * 2
                )
                cell.text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
                x += columnWidths[column]
            }
            y += rowHeights[rowIndex]
            if rowIndex < rows.count - 1 {
                grid.move(to: NSPoint(x: frame.minX, y: y.rounded() + 0.5))
                grid.line(to: NSPoint(x: frame.maxX, y: y.rounded() + 0.5))
            }
        }
        var x = frame.minX
        for width in columnWidths.dropLast() {
            x += width
            grid.move(to: NSPoint(x: x.rounded() + 0.5, y: frame.minY))
            grid.line(to: NSPoint(x: x.rounded() + 0.5, y: frame.maxY))
        }
        gridColor.setStroke()
        grid.stroke()
        NSGraphicsContext.restoreGraphicsState()

        gridColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    // MARK: Hit testing

    /// The source location of the cell under `point` (relative to the table's top-left).
    func sourceLocation(at point: NSPoint) -> Int? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        var y: CGFloat = 0
        for (rowIndex, height) in rowHeights.enumerated() {
            y += height
            guard point.y < y else { continue }
            var x: CGFloat = 0
            for (column, width) in columnWidths.enumerated() {
                x += width
                if point.x < x { return rows[rowIndex][column].source.location }
            }
            return rows[rowIndex].last?.source.location
        }
        return nil
    }

    // MARK: Helpers

    /// The widest piece of the cell that can't be broken across lines.
    private static func longestRunWidth(in text: NSAttributedString) -> CGFloat {
        TableColumnSizer.unbreakableRuns(in: text.string)
            .map { ceil(text.attributedSubstring(from: $0).size().width) + 1 }
            .max() ?? 0
    }
}

extension NSAttributedString.Key {
    /// A `MarkdownTableRendering`, present on every character of a table drawn as a grid.
    static let markdownTableRendering = NSAttributedString.Key("mdbook.tableRendering")
}
