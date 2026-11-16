//
//  MarkdownStyler.swift
//  mdbook
//
//  Applies `MarkdownSpans` to an `NSTextStorage` as attributes.
//

import AppKit

struct MarkdownStyler {
    let theme: EditorTheme

    /// Restyles the whole document. `activeParagraph` is the paragraph containing the
    /// caret; markers inside it stay visible so the user can edit them.
    func applyAll(to storage: NSTextStorage, spans: MarkdownSpans, activeParagraph: NSRange?) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: full)

        // Block-level constructs first; inline styling layers on top of them.
        for block in spans.codeBlocks {
            // The layout manager draws a full-width panel for `.markdownCodeBlock`.
            storage.addAttributes([.font: theme.codeFont, .markdownCodeBlock: true], range: block.range)
            if theme.mode == .wysiwyg {
                let style = mutableParagraphStyle()
                style.lineSpacing = 1
                style.paragraphSpacing = 0
                storage.addAttribute(.paragraphStyle, value: style, range: block.range)
            }
            for fence in block.fenceLines {
                storage.addAttribute(.foregroundColor, value: theme.markerColor, range: fence)
            }
        }

        for heading in spans.headings {
            storage.addAttribute(.font, value: theme.headingFont(level: heading.level), range: heading.line)
            if theme.mode == .wysiwyg {
                let style = mutableParagraphStyle()
                style.paragraphSpacingBefore = heading.level <= 2 ? 14 : 8
                style.paragraphSpacing = 8
                storage.addAttribute(.paragraphStyle, value: style, range: heading.line)
            } else {
                storage.addAttribute(.foregroundColor, value: theme.accentColor, range: heading.line)
            }
        }

        for quote in spans.blockQuotes {
            storage.addAttribute(.foregroundColor, value: theme.quoteColor, range: quote.line)
            if theme.mode == .wysiwyg {
                let style = mutableParagraphStyle()
                style.firstLineHeadIndent = 4
                style.headIndent = 4 + quoteMarkerWidth(for: quote, in: storage)
                storage.addAttribute(.paragraphStyle, value: style, range: quote.line)
            }
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: quote.marker)
        }

        for item in spans.listItems {
            storage.addAttribute(.foregroundColor, value: theme.accentColor, range: item.marker)
            if let task = item.task {
                storage.addAttributes([.foregroundColor: theme.accentColor, .markdownTask: true], range: task)
                storage.addAttribute(.cursor, value: NSCursor.pointingHand, range: task)
            }
            if theme.mode == .wysiwyg {
                // Wrapped lines align with the start of the item text.
                let style = mutableParagraphStyle()
                let indent = CGFloat(item.indent) * 8
                let markerWidth = width(of: NSRange(location: item.marker.location, length: NSMaxRange(item.task ?? item.marker) - item.marker.location), in: storage)
                style.firstLineHeadIndent = indent
                style.headIndent = indent + markerWidth + (item.task == nil ? 0 : width(of: " ", font: theme.baseFont))
                style.paragraphSpacing = 2
                storage.addAttribute(.paragraphStyle, value: style, range: item.line)
            }
        }

        for line in spans.tableLines {
            storage.addAttribute(.font, value: theme.codeFont, range: line)
        }

        for line in spans.thematicBreaks {
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: line)
        }

        // Inline constructs.
        for range in spans.bold { addTrait(.bold, in: range, storage: storage) }
        for range in spans.italic { addTrait(.italic, in: range, storage: storage) }
        for range in spans.strikethrough {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        for range in spans.inlineCode {
            convertToMonospaced(in: range, storage: storage)
            storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: range)
        }
        for link in spans.links {
            if link.isImage {
                storage.addAttribute(.foregroundColor, value: theme.accentColor, range: link.text)
            } else {
                storage.addAttribute(.link, value: link.destination as NSString, range: link.text)
            }
        }

        // Markers last so they pick up the font of their surroundings.
        for marker in spans.markers where marker.length > 0 && NSMaxRange(marker) <= storage.length {
            let visibleFont = storage.attribute(.font, at: marker.location, effectiveRange: nil) as? NSFont ?? theme.baseFont
            storage.addAttribute(.markdownMarker, value: visibleFont, range: marker)
            let isActive = activeParagraph.map { intersects($0, marker) } ?? true
            if theme.hidesMarkers && !isActive {
                storage.addAttribute(.markdownHidden, value: true, range: marker)
            } else {
                storage.addAttribute(.foregroundColor, value: theme.markerColor, range: marker)
            }
        }

        storage.endEditing()
    }

    /// Shows or hides the markers inside `range` without restyling anything else.
    func setMarkersVisible(_ visible: Bool, in range: NSRange, storage: NSTextStorage) {
        guard theme.hidesMarkers, range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.markdownMarker, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            if visible {
                storage.removeAttribute(.markdownHidden, range: subrange)
                storage.addAttribute(.foregroundColor, value: theme.markerColor, range: subrange)
            } else {
                storage.addAttribute(.markdownHidden, value: true, range: subrange)
            }
        }
        storage.endEditing()
    }

    // MARK: - Helpers

    private func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        NSIntersectionRange(a, b).length > 0 || (b.length > 0 && NSLocationInRange(b.location, a)) || b.location == NSMaxRange(a)
    }

    private func mutableParagraphStyle() -> NSMutableParagraphStyle {
        // swiftlint:disable:next force_cast
        theme.baseParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
    }

    private func width(of range: NSRange, in storage: NSTextStorage) -> CGFloat {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return 0 }
        return storage.attributedSubstring(from: range).size().width
    }

    private func width(of string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private func quoteMarkerWidth(for quote: MarkdownSpans.BlockQuote, in storage: NSTextStorage) -> CGFloat {
        width(of: quote.marker, in: storage)
    }

    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, in range: NSRange, storage: NSTextStorage) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
            if let styled = NSFont(descriptor: descriptor, size: font.pointSize) {
                storage.addAttribute(.font, value: styled, range: subrange)
            }
        }
    }

    private func convertToMonospaced(in range: NSRange, storage: NSTextStorage) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            let size = font.pointSize * (theme.mode == .wysiwyg ? 0.9 : 1)
            var mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            if font.fontDescriptor.symbolicTraits.contains(.bold) {
                mono = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
            }
            storage.addAttribute(.font, value: mono, range: subrange)
        }
    }
}
