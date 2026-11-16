//
//  EditorTheme.swift
//  mdbook
//

import AppKit

/// Fonts, colours and spacing for the two editing modes.
struct EditorTheme: Equatable {
    enum Mode: Equatable {
        /// Live styling with syntax markers hidden away from the caret.
        case wysiwyg
        /// Plain monospaced source with coloured syntax.
        case source
    }

    let mode: Mode

    var hidesMarkers: Bool { mode == .wysiwyg }

    var baseFont: NSFont {
        switch mode {
        case .wysiwyg: return NSFont.systemFont(ofSize: 16)
        case .source: return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }
    }

    var codeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: mode == .wysiwyg ? 14 : 13, weight: .regular)
    }

    var textColor: NSColor { .textColor }
    var markerColor: NSColor { mode == .wysiwyg ? .tertiaryLabelColor : .secondaryLabelColor }
    var accentColor: NSColor { .controlAccentColor }
    var quoteColor: NSColor { .secondaryLabelColor }
    var codeBackground: NSColor { .quaternarySystemFill }
    var linkColor: NSColor { .linkColor }

    var textContainerInset: NSSize {
        mode == .wysiwyg ? NSSize(width: 28, height: 24) : NSSize(width: 12, height: 12)
    }

    func headingFont(level: Int) -> NSFont {
        switch mode {
        case .wysiwyg:
            let sizes: [CGFloat] = [30, 24, 20, 18, 16, 16]
            let size = sizes[max(0, min(level - 1, sizes.count - 1))]
            return NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
        case .source:
            return NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        }
    }

    var baseParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        if mode == .wysiwyg {
            style.lineSpacing = 3
            style.paragraphSpacing = 6
        }
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: textColor,
            .paragraphStyle: baseParagraphStyle,
        ]
    }

    var linkTextAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }
}

extension NSAttributedString.Key {
    /// Marks a syntax marker. The value is the `NSFont` to use when the marker is visible.
    static let markdownMarker = NSAttributedString.Key("mdbook.marker")
    /// Present on characters that should not be drawn (markers away from the caret).
    static let markdownHidden = NSAttributedString.Key("mdbook.hidden")
    /// Present on a `[ ]` / `[x]` task checkbox so clicks can toggle it.
    static let markdownTask = NSAttributedString.Key("mdbook.task")
}
