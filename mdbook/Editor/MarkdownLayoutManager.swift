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
    /// Gutter width per quote level (matches `MarkdownStyler.quoteIndent`).
    var quoteIndent: CGFloat = 22
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

        drawQuoteBars(in: characterRange, storage: textStorage, origin: origin)

        // Header rows of tables being edited hug the text.
        drawPanels(for: .markdownTableHeader, in: characterRange, storage: textStorage, color: tableHeaderBackground, origin: origin) { usedWidth in
            let padding = textContainer.lineFragmentPadding
            return (origin.x + padding - panelHorizontalPadding / 2, usedWidth + panelHorizontalPadding)
        }

        forEachRun(of: .markdownBlockRendering, in: characterRange, storage: textStorage) { range in
            guard let rendering = textStorage.attribute(.markdownBlockRendering, at: range.location, effectiveRange: nil) as? MarkdownBlockRendering,
                  let frame = frame(for: rendering, origin: origin) else { return }
            rendering.draw(in: frame, headerFill: tableHeaderBackground, gridColor: gridColor)
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        // After the glyphs: a linked image's stand-in character gets the text view's link
        // colour and underline regardless of its own attributes, so cover it.
        guard let textStorage else { return }
        drawInlineImages(in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil), storage: textStorage, origin: origin)
    }

    /// Images in running text, drawn over the kerned character standing in for each one and
    /// centred on the line.
    private func drawInlineImages(in characterRange: NSRange, storage: NSTextStorage, origin: NSPoint) {
        storage.enumerateAttribute(.markdownInlineImage, in: characterRange, options: []) { value, range, _ in
            guard let inline = value as? MarkdownInlineImage else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = location(forGlyphAt: glyph)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
            let lineHeight = font.ascender - font.descender
            let baseline = origin.y + line.minY + position.y
            let rect = NSRect(
                x: origin.x + line.minX + position.x,
                y: baseline - font.ascender + (lineHeight - inline.size.height) / 2,
                width: inline.size.width,
                height: inline.size.height
            )
            inline.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }

    /// The block rendering whose source falls in `characters`, if any. Hidden glyphs join
    /// the line fragment of the line before, so look across the whole range.
    func blockRendering(in characters: NSRange) -> MarkdownBlockRendering? {
        guard let textStorage, NSMaxRange(characters) <= textStorage.length else { return nil }
        var found: MarkdownBlockRendering?
        textStorage.enumerateAttribute(.markdownBlockRendering, in: characters, options: []) { value, _, stop in
            if let rendering = value as? MarkdownBlockRendering {
                found = rendering
                stop.pointee = true
            }
        }
        return found
    }

    /// Where a block rendering is drawn, in the coordinates `origin` is given in: below any
    /// visible text in the line fragment the coordinator grew for its anchor.
    func frame(for rendering: MarkdownBlockRendering, origin: NSPoint) -> NSRect? {
        guard let textStorage, rendering.anchor < textStorage.length else { return nil }
        let glyph = glyphIndexForCharacter(at: rendering.anchor)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let padding = textContainers.first?.lineFragmentPadding ?? 0
        let size = rendering.size
        return NSRect(
            x: origin.x + fragment.minX + padding,
            y: origin.y + fragment.minY + rendering.offsetInFragment + MarkdownBlockRendering.margin,
            width: size.width,
            height: size.height
        )
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

    // MARK: - Block quotes

    /// Bars down the left of quote lines, one per nesting level. Drawn per line fragment,
    /// using the depth at the fragment's first visible character, so bars join up across
    /// lines and levels, and a fragment that only holds the next line's hidden `>` markers
    /// (they join the line above) gets none.
    private func drawQuoteBars(in characterRange: NSRange, storage: NSTextStorage, origin: NSPoint) {
        guard let textContainer = textContainers.first, storage.length > 0 else { return }
        let glyphs = glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        // Opaque, so bars drawn in adjacent fragments don't darken where they meet.
        let color = NSColor.controlAccentColor.blended(withFraction: 0.45, of: .textBackgroundColor) ?? .controlAccentColor
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, fragmentGlyphs, _ in
            let characters = self.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            var index = characters.location
            while index < NSMaxRange(characters), index < storage.length,
                  storage.attribute(.markdownHidden, at: index, effectiveRange: nil) != nil {
                index += 1
            }
            guard index < min(NSMaxRange(characters), storage.length),
                  let depth = storage.attribute(.markdownQuoteDepth, at: index, effectiveRange: nil) as? Int, depth > 0 else { return }
            color.setFill()
            for level in 0..<depth {
                let x = origin.x + textContainer.lineFragmentPadding + CGFloat(level) * self.quoteIndent + 2
                NSRect(x: x, y: origin.y + rect.minY, width: 3, height: rect.height).fill()
            }
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
    /// The nesting depth (`Int`) of a block quote line, including its terminator.
    static let markdownQuoteDepth = NSAttributedString.Key("mdbook.quoteDepth")
    /// Present on the header row of a table that is being edited as source.
    static let markdownTableHeader = NSAttributedString.Key("mdbook.tableHeader")
}
