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
    /// Text size multiplier (zoom); 1 is 16 pt body text in the WYSIWYG editor.
    var scale: CGFloat = 1
    /// The reading typeface for the WYSIWYG editor (source mode is always monospaced).
    var font: ReadingFont = .system

    var hidesMarkers: Bool { mode == .wysiwyg }

    /// A system font at `size` (before scaling) in the chosen design.
    private func readingFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size * scale, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(font.systemDesign) else { return base }
        return NSFont(descriptor: descriptor, size: size * scale) ?? base
    }

    var baseFont: NSFont {
        switch mode {
        case .wysiwyg: return readingFont(ofSize: 16)
        case .source: return NSFont.monospacedSystemFont(ofSize: 13 * scale, weight: .regular)
        }
    }

    var codeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: (mode == .wysiwyg ? 14 : 13) * scale, weight: .regular)
    }

    var textColor: NSColor { .textColor }
    var markerColor: NSColor { mode == .wysiwyg ? .tertiaryLabelColor : .secondaryLabelColor }
    var accentColor: NSColor { .controlAccentColor }
    var quoteColor: NSColor { .secondaryLabelColor }
    var codeBackground: NSColor { .quaternarySystemFill }
    var linkColor: NSColor { .linkColor }

    /// Colours for syntax-highlighted code, shared by the editor and the preview.
    static func color(for kind: CodeToken.Kind) -> NSColor {
        switch kind {
        case .keyword: return .systemPink
        case .string: return .systemRed
        case .comment: return .secondaryLabelColor
        case .number: return .systemOrange
        case .type: return .systemTeal
        case .attribute: return .systemPurple
        case .tag: return .systemBlue
        case .property: return .systemIndigo
        }
    }

    var textContainerInset: NSSize {
        mode == .wysiwyg ? NSSize(width: 28, height: 24) : NSSize(width: 12, height: 12)
    }

    func headingFont(level: Int) -> NSFont {
        switch mode {
        case .wysiwyg:
            let sizes: [CGFloat] = [30, 24, 20, 18, 16, 16]
            let size = sizes[max(0, min(level - 1, sizes.count - 1))]
            return readingFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
        case .source:
            return NSFont.monospacedSystemFont(ofSize: 13 * scale, weight: .bold)
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
