//
//  MarkdownLayoutManager.swift
//  mdbook
//
//  Draws full-width backgrounds behind fenced code blocks so they read as a
//  single panel rather than a highlight hugging each line of text.
//

import AppKit

final class MarkdownLayoutManager: NSLayoutManager {
    var codeBlockBackground: NSColor = .quaternarySystemFill
    var codeBlockCornerRadius: CGFloat = 6
    /// How far the panel extends beyond the text on each side.
    var codeBlockHorizontalPadding: CGFloat = 8

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let textContainer = textContainers.first else { return }

        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.markdownCodeBlock, in: characterRange, options: []) { value, range, _ in
            guard value != nil else { return }
            // Extend to the whole block so the panel's corners are stable while scrolling.
            var blockRange = NSRange(location: NSNotFound, length: 0)
            _ = textStorage.attribute(.markdownCodeBlock, at: range.location, longestEffectiveRange: &blockRange, in: NSRange(location: 0, length: textStorage.length))
            guard blockRange.location != NSNotFound else { return }

            let glyphRange = self.glyphRange(forCharacterRange: blockRange, actualCharacterRange: nil)
            var top = CGFloat.greatestFiniteMagnitude
            var bottom: CGFloat = 0
            enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                top = min(top, rect.minY)
                bottom = max(bottom, rect.maxY)
            }
            guard top < bottom else { return }

            let padding = textContainer.lineFragmentPadding
            let panel = NSRect(
                x: origin.x + padding - codeBlockHorizontalPadding,
                y: origin.y + top,
                width: textContainer.size.width - padding * 2 + codeBlockHorizontalPadding * 2,
                height: bottom - top
            )
            codeBlockBackground.setFill()
            NSBezierPath(roundedRect: panel, xRadius: codeBlockCornerRadius, yRadius: codeBlockCornerRadius).fill()
        }
    }
}

extension NSAttributedString.Key {
    /// Present on every character of a fenced code block (including the fences).
    static let markdownCodeBlock = NSAttributedString.Key("mdbook.codeBlock")
}
