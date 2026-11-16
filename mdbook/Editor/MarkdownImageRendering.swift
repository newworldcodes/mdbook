//
//  MarkdownImageRendering.swift
//  mdbook
//
//  The images of a line that holds nothing but images (a figure, or a row of badges),
//  flowed left to right and scaled down to fit the editor's width.
//

import AppKit

/// An image drawn inline, on the character that stands in for it (see
/// `MarkdownStyler.renderInlineImages`).
final class MarkdownInlineImage: NSObject {
    let image: NSImage
    let size: NSSize

    init(image: NSImage, size: NSSize) {
        self.image = image
        self.size = size
    }
}

extension NSAttributedString.Key {
    /// A `MarkdownInlineImage` on the last character of an image's source.
    static let markdownInlineImage = NSAttributedString.Key("mdbook.inlineImage")
}

final class MarkdownImageRendering: MarkdownBlockRendering {
    struct Item {
        var image: NSImage
        /// Position and size relative to the rendering's top-left.
        var frame: NSRect
        /// Start of this image's source, for placing the caret on click.
        var source: Int
    }

    static let spacing: CGFloat = 6

    let items: [Item]
    private let drawnSize: NSSize

    init(range: NSRange, images: [(image: NSImage, source: Int)], availableWidth: CGFloat, hidesSource: Bool) {
        let available = max(availableWidth, 1)
        var items: [Item] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for (image, source) in images {
            var size = image.size
            if size.width > available {
                size = NSSize(width: available, height: size.height * available / size.width)
            }
            if x > 0, x + size.width > available {
                y += rowHeight + Self.spacing
                x = 0
                rowHeight = 0
            }
            items.append(Item(image: image, frame: NSRect(origin: NSPoint(x: x, y: y), size: size), source: source))
            x += size.width + Self.spacing
            width = max(width, x - Self.spacing)
            rowHeight = max(rowHeight, size.height)
        }
        self.items = items
        self.drawnSize = NSSize(width: width, height: y + rowHeight)
        super.init(range: range, hidesSource: hidesSource)
    }

    /// The line's last character, so a wrapped source line being edited stays above.
    override var anchor: Int { max(range.location, NSMaxRange(range) - 1) }

    override var size: NSSize { drawnSize }

    override func draw(in frame: NSRect, headerFill: NSColor, gridColor: NSColor) {
        for item in items {
            let rect = item.frame.offsetBy(dx: frame.minX, dy: frame.minY)
            item.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }

    override func sourceLocation(at point: NSPoint) -> Int? {
        // While the source is shown, a click on the image just moves to the end of the line.
        guard hidesSource else { return NSMaxRange(range) }
        return items.first { $0.frame.contains(point) }?.source ?? range.location
    }
}
