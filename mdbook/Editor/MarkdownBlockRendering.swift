//
//  MarkdownBlockRendering.swift
//  mdbook
//
//  Something the editor draws in place of (or under) a run of markdown source: a table
//  or a line of images. The styler stores a rendering on the source's characters; the
//  coordinator's line-fragment delegate grows the fragment holding `anchor` by
//  `reservedHeight`; the layout manager draws the rendering in that space. The text
//  storage still holds only the markdown source.
//

import AppKit

class MarkdownBlockRendering: NSObject {
    /// Space above and below what's drawn.
    static let margin: CGFloat = 4

    /// The source the rendering stands for (without its final line terminator).
    let range: NSRange
    /// Whether the source's glyphs are hidden (caret elsewhere) or shown above the rendering.
    let hidesSource: Bool
    /// Height of the visible content sharing the anchor's line fragment above the rendering.
    /// Hidden glyphs join the fragment of the line before, so this is that line's height
    /// when the source is hidden, or the source's own last line when it's shown. Set during
    /// layout.
    var offsetInFragment: CGFloat = 0

    init(range: NSRange, hidesSource: Bool) {
        self.range = range
        self.hidesSource = hidesSource
    }

    /// The character whose line fragment makes room for the rendering. Tables use their
    /// first character; images their last, so a wrapped source line stays above them.
    var anchor: Int { range.location }

    /// The size of what's drawn.
    var size: NSSize { .zero }

    /// The height added to the anchor's line fragment.
    var reservedHeight: CGFloat { size.height + Self.margin * 2 }

    /// Draws with the top-left corner at `frame.origin` (flipped coordinates).
    func draw(in frame: NSRect, headerFill: NSColor, gridColor: NSColor) {}

    /// Where a click at `point` (relative to the drawn frame) puts the caret.
    func sourceLocation(at point: NSPoint) -> Int? { range.location }
}

extension NSAttributedString.Key {
    /// A `MarkdownBlockRendering`, present on every character of the source it stands for.
    static let markdownBlockRendering = NSAttributedString.Key("mdbook.blockRendering")
}
