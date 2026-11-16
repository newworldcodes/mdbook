//
//  MarkdownLayoutManager.swift
//  mdbook
//
//  Draws the decorations that attributes alone can't express: full-width panels
//  behind fenced code blocks, header fills for tables being edited, and rendered tables.
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

        forEachRun(of: .markdownTableRendering, in: characterRange, storage: textStorage) { range in
            guard let rendering = textStorage.attribute(.markdownTableRendering, at: range.location, effectiveRange: nil) as? MarkdownTableRendering,
                  let frame = tableFrame(for: rendering, origin: origin) else { return }
            rendering.draw(in: frame, headerFill: tableHeaderBackground, gridColor: gridColor)
        }
    }

    /// The rendered table whose (hidden) source falls in `characters`, if any. A table's
    /// glyphs join the line fragment of the line before it, so look across the whole range.
    func tableRendering(in characters: NSRange) -> MarkdownTableRendering? {
        guard let textStorage, NSMaxRange(characters) <= textStorage.length else { return nil }
        var found: MarkdownTableRendering?
        textStorage.enumerateAttribute(.markdownTableRendering, in: characters, options: []) { value, _, stop in
            if let rendering = value as? MarkdownTableRendering {
                found = rendering
                stop.pointee = true
            }
        }
        return found
    }

    /// Where a rendered table is drawn, in the coordinates `origin` is given in. The table
    /// sits in the tall line fragment the coordinator reserved for its first line.
    func tableFrame(for rendering: MarkdownTableRendering, origin: NSPoint) -> NSRect? {
        guard let textStorage, rendering.location < textStorage.length else { return nil }
        let glyph = glyphIndexForCharacter(at: rendering.location)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let padding = textContainers.first?.lineFragmentPadding ?? 0
        let size = rendering.tableSize
        return NSRect(x: origin.x + fragment.minX + padding, y: origin.y + fragment.minY + rendering.offsetInFragment + MarkdownTableRendering.margin, width: size.width, height: size.height)
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
}
