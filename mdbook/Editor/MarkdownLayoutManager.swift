//
//  MarkdownLayoutManager.swift
//  mdbook
//
//  Draws the decorations that attributes alone can't express: full-width panels
//  behind fenced code blocks, and grid lines plus a header fill for tables.
//

import AppKit

final class MarkdownLayoutManager: NSLayoutManager {
    var codeBlockBackground: NSColor = .quaternarySystemFill
    var tableHeaderBackground: NSColor = .quaternarySystemFill
    var gridColor: NSColor = .separatorColor
    var panelCornerRadius: CGFloat = 6
    /// How far a panel extends beyond the text on each side.
    var panelHorizontalPadding: CGFloat = 8

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let textContainer = textContainers.first else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        // Code blocks span the full container width.
        drawPanels(for: .markdownCodeBlock, in: characterRange, storage: textStorage, color: codeBlockBackground, origin: origin) { _ in
            let padding = textContainer.lineFragmentPadding
            return (origin.x + padding - panelHorizontalPadding, textContainer.size.width - padding * 2 + panelHorizontalPadding * 2)
        }

        // Header rows of tables being edited hug the text.
        drawPanels(for: .markdownTableHeader, in: characterRange, storage: textStorage, color: tableHeaderBackground, origin: origin) { usedWidth in
            let padding = textContainer.lineFragmentPadding
            return (origin.x + padding - panelHorizontalPadding / 2, usedWidth + panelHorizontalPadding)
        }

        drawTableGrids(in: characterRange, storage: textStorage, origin: origin)
    }

    // MARK: - Panels

    /// Fills a rounded rect behind each run of `attribute`. `horizontalExtent` returns the
    /// x origin and width given the widest line fragment in the run.
    private func drawPanels(
        for attribute: NSAttributedString.Key,
        in characterRange: NSRange,
        storage: NSTextStorage,
        color: NSColor,
        origin: NSPoint,
        horizontalExtent: (CGFloat) -> (x: CGFloat, width: CGFloat)
    ) {
        forEachRun(of: attribute, in: characterRange, storage: storage) { fullRange in
            let glyphRange = self.glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
            var top = CGFloat.greatestFiniteMagnitude
            var bottom: CGFloat = 0
            var usedWidth: CGFloat = 0
            enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, _, _, _ in
                top = min(top, rect.minY)
                bottom = max(bottom, rect.maxY)
                usedWidth = max(usedWidth, usedRect.width)
            }
            guard top < bottom else { return }

            let extent = horizontalExtent(usedWidth)
            // Line fragment rects are in container coordinates; `origin` moves them into view space.
            let panel = NSRect(x: extent.x, y: origin.y + top, width: extent.width, height: bottom - top)
            color.setFill()
            NSBezierPath(roundedRect: panel, xRadius: panelCornerRadius, yRadius: panelCornerRadius).fill()
        }
    }

    // MARK: - Table grids

    private func drawTableGrids(in characterRange: NSRange, storage: NSTextStorage, origin: NSPoint) {
        forEachRun(of: .markdownTableGrid, in: characterRange, storage: storage) { tableRange in
            // Column boundaries (relative to the row start) were computed by the styler.
            guard let edgeNumbers = storage.attribute(.markdownTableColumns, at: tableRange.location, effectiveRange: nil) as? [NSNumber],
                  let lastEdge = edgeNumbers.last else { return }
            let columnEdges = edgeNumbers.map { CGFloat($0.doubleValue) }

            let glyphRange = self.glyphRange(forCharacterRange: tableRange, actualCharacterRange: nil)
            var fragments: [NSRect] = []
            enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                fragments.append(rect)
            }
            guard let first = fragments.first, let last = fragments.last else { return }

            let leftEdge = first.minX + location(forGlyphAt: glyphRange.location).x
            let rightEdge = leftEdge + CGFloat(lastEdge.doubleValue)
            let frame = NSRect(x: origin.x + leftEdge, y: origin.y + first.minY, width: rightEdge - leftEdge, height: last.maxY - first.minY)

            // Header fill.
            tableHeaderBackground.setFill()
            let headerRect = NSRect(x: frame.minX, y: origin.y + first.minY, width: frame.width, height: first.height)
            NSBezierPath(rect: headerRect).fill()

            // Row separators (the collapsed delimiter row is a sliver; skip its own bottom edge).
            let path = NSBezierPath()
            path.lineWidth = 1
            for fragment in fragments.dropLast() where fragment.height >= 8 {
                let y = (origin.y + fragment.maxY).rounded() + 0.5
                path.move(to: NSPoint(x: frame.minX, y: y))
                path.line(to: NSPoint(x: frame.maxX, y: y))
            }
            // Column separators (all but the last edge, which is the outer border).
            for edge in columnEdges.dropLast() {
                let x = (frame.minX + edge).rounded() + 0.5
                path.move(to: NSPoint(x: x, y: frame.minY))
                path.line(to: NSPoint(x: x, y: frame.maxY))
            }
            gridColor.setStroke()
            path.stroke()

            let border = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            border.lineWidth = 1
            border.stroke()
        }
    }

    // MARK: - Helpers

    /// Calls `body` once per maximal run of `attribute` that touches `characterRange`.
    private func forEachRun(of attribute: NSAttributedString.Key, in characterRange: NSRange, storage: NSTextStorage, _ body: (NSRange) -> Void) {
        var seen = Set<Int>()
        storage.enumerateAttribute(attribute, in: characterRange, options: []) { value, range, _ in
            guard value != nil else { return }
            var fullRange = NSRange(location: NSNotFound, length: 0)
            _ = storage.attribute(attribute, at: range.location, longestEffectiveRange: &fullRange, in: NSRange(location: 0, length: storage.length))
            guard fullRange.location != NSNotFound, !seen.contains(fullRange.location) else { return }
            seen.insert(fullRange.location)
            body(fullRange)
        }
    }
}

extension NSAttributedString.Key {
    /// Present on every character of a fenced code block (including the fences).
    static let markdownCodeBlock = NSAttributedString.Key("mdbook.codeBlock")
    /// Present on the header row of a table that is being edited as source.
    static let markdownTableHeader = NSAttributedString.Key("mdbook.tableHeader")
    /// Present on every character of a table drawn as a grid.
    static let markdownTableGrid = NSAttributedString.Key("mdbook.tableGrid")
    /// Present on each cell-separating pipe of a table drawn as a grid.
    static let markdownTablePipe = NSAttributedString.Key("mdbook.tablePipe")
    /// `[NSNumber]` of cumulative column boundaries (points from the row start) for a grid table.
    static let markdownTableColumns = NSAttributedString.Key("mdbook.tableColumns")
}
