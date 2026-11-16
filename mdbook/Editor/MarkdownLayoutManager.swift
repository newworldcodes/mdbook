//
//  MarkdownLayoutManager.swift
//  mdbook
//
//  Draws panels behind fenced code blocks and table header rows so they read
//  as blocks rather than highlights hugging each line of text.
//

import AppKit

final class MarkdownLayoutManager: NSLayoutManager {
    var codeBlockBackground: NSColor = .quaternarySystemFill
    var tableHeaderBackground: NSColor = .quaternarySystemFill
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

        // Table headers hug the text so the panel matches the table's width.
        drawPanels(for: .markdownTableHeader, in: characterRange, storage: textStorage, color: tableHeaderBackground, origin: origin) { usedWidth in
            let padding = textContainer.lineFragmentPadding
            return (origin.x + padding - panelHorizontalPadding / 2, usedWidth + panelHorizontalPadding)
        }
    }

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
        var drawn = Set<Int>()
        storage.enumerateAttribute(attribute, in: characterRange, options: []) { value, range, _ in
            guard value != nil else { return }
            // Extend to the whole run so the panel's corners are stable while scrolling.
            var fullRange = NSRange(location: NSNotFound, length: 0)
            _ = storage.attribute(attribute, at: range.location, longestEffectiveRange: &fullRange, in: NSRange(location: 0, length: storage.length))
            guard fullRange.location != NSNotFound, !drawn.contains(fullRange.location) else { return }
            drawn.insert(fullRange.location)

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
}

extension NSAttributedString.Key {
    /// Present on every character of a fenced code block (including the fences).
    static let markdownCodeBlock = NSAttributedString.Key("mdbook.codeBlock")
    /// Present on the header row of a table.
    static let markdownTableHeader = NSAttributedString.Key("mdbook.tableHeader")
}
