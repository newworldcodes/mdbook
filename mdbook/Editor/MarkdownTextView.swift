//
//  MarkdownTextView.swift
//  mdbook
//
//  An NSTextView with markdown-aware behaviour: list continuation on Return,
//  clickable task checkboxes and formatting actions reachable from the menu bar.
//

import AppKit

final class MarkdownTextView: NSTextView {
    nonisolated(unsafe) private static let listItemPattern = try? NSRegularExpression(
        pattern: #"^([ \t]*)([-*+]|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#
    )

    /// Builds a text view inside a scroll view using an explicit TextKit 1 stack so
    /// the layout manager delegate can hide glyphs and draw code block panels.
    static func makeScrollable() -> (scrollView: NSScrollView, textView: MarkdownTextView) {
        let storage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Markdown is full of identifiers and paths; leave spell checking to the Edit menu.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    /// Scrolls so the given character range sits at the top of the visible area.
    func scrollToTop(of range: NSRange) {
        guard let layoutManager, let textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let y = max(0, rect.minY + textContainerOrigin.y - textContainerInset.height)
        scroll(NSPoint(x: 0, y: y))
    }

    // MARK: - Task checkboxes

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, toggleTaskCheckbox(at: event) {
            return
        }
        super.mouseDown(with: event)
    }

    private func toggleTaskCheckbox(at event: NSEvent) -> Bool {
        guard let layoutManager, let textContainer, let textStorage else { return false }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(point) else { return false }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < textStorage.length else { return false }
        var range = NSRange(location: NSNotFound, length: 0)
        guard textStorage.attribute(.markdownTask, at: charIndex, effectiveRange: &range) != nil,
              range.location != NSNotFound else { return false }
        let current = (textStorage.string as NSString).substring(with: range)
        let replacement = current == "[ ]" ? "[x]" : "[ ]"
        insertText(replacement, replacementRange: range)
        return true
    }

    // MARK: - List continuation

    override func insertNewline(_ sender: Any?) {
        guard let pattern = Self.listItemPattern, let textStorage else {
            super.insertNewline(sender)
            return
        }
        let selection = selectedRange()
        let ns = textStorage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: selection.location, length: 0))
        var line = ns.substring(with: paragraph)
        if line.hasSuffix("\n") { line.removeLast() }
        let lineNS = line as NSString

        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) else {
            super.insertNewline(sender)
            return
        }
        let prefixLength = NSMaxRange(match.range)
        // Only continue the list when the caret is past the marker.
        guard selection.location >= paragraph.location + prefixLength else {
            super.insertNewline(sender)
            return
        }

        let content = lineNS.substring(from: prefixLength).trimmingCharacters(in: .whitespaces)
        if content.isEmpty {
            // Return on an empty item ends the list.
            insertText("", replacementRange: NSRange(location: paragraph.location, length: prefixLength))
            return
        }

        let indent = lineNS.substring(with: match.range(at: 1))
        var marker = lineNS.substring(with: match.range(at: 2))
        if match.range(at: 3).location != NSNotFound,
           let number = Int(lineNS.substring(with: match.range(at: 3))) {
            marker = "\(number + 1)" + lineNS.substring(with: match.range(at: 4))
        }
        let spacing = lineNS.substring(with: match.range(at: 5))
        let task = match.range(at: 6).location == NSNotFound ? "" : "[ ] "
        insertText("\n" + indent + marker + spacing + task, replacementRange: selection)
    }

    // MARK: - Formatting actions (reached through the responder chain)

    @objc func toggleBoldMarkdown(_ sender: Any?) { toggleWrapping(with: "**") }
    @objc func toggleItalicMarkdown(_ sender: Any?) { toggleWrapping(with: "*") }
    @objc func toggleStrikethroughMarkdown(_ sender: Any?) { toggleWrapping(with: "~~") }
    @objc func toggleInlineCodeMarkdown(_ sender: Any?) { toggleWrapping(with: "`") }

    @objc func insertLinkMarkdown(_ sender: Any?) {
        let selection = selectedRange()
        let ns = string as NSString
        let label = selection.length > 0 ? ns.substring(with: selection) : "link text"
        let placeholder = "url"
        let replacement = "[\(label)](\(placeholder))"
        insertText(replacement, replacementRange: selection)
        let urlLocation = selection.location + (label as NSString).length + 3
        setSelectedRange(NSRange(location: urlLocation, length: (placeholder as NSString).length))
    }

    @objc func toggleHeadingMarkdown(_ sender: Any?) {
        let ns = string as NSString
        let paragraph = ns.paragraphRange(for: selectedRange())
        var line = ns.substring(with: paragraph)
        let hadNewline = line.hasSuffix("\n")
        if hadNewline { line.removeLast() }

        let replacement: String
        let hashes = line.prefix(while: { $0 == "#" }).count
        if hashes > 0, line.dropFirst(hashes).first == " " || line.count == hashes {
            let next = hashes >= 6 ? 0 : hashes + 1
            let body = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
            replacement = next == 0 ? body : String(repeating: "#", count: next) + " " + body
        } else {
            replacement = "# " + line
        }
        let target = NSRange(location: paragraph.location, length: paragraph.length - (hadNewline ? 1 : 0))
        insertText(replacement, replacementRange: target)
    }

    private func toggleWrapping(with marker: String) {
        let ns = string as NSString
        let selection = selectedRange()
        let markerLength = (marker as NSString).length
        let selected = ns.substring(with: selection)

        // Case 1: the selection itself includes the markers -> unwrap.
        if selection.length >= markerLength * 2, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: markerLength, length: selection.length - markerLength * 2))
            insertText(inner, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location, length: (inner as NSString).length))
            return
        }

        // Case 2: the markers surround the selection -> unwrap.
        let outer = NSRange(location: selection.location - markerLength, length: selection.length + markerLength * 2)
        if outer.location >= 0, NSMaxRange(outer) <= ns.length,
           ns.substring(with: NSRange(location: outer.location, length: markerLength)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(selection), length: markerLength)) == marker {
            insertText(selected, replacementRange: outer)
            setSelectedRange(NSRange(location: outer.location, length: selection.length))
            return
        }

        // Case 3: wrap the selection (or insert an empty pair and park the caret inside).
        insertText(marker + selected + marker, replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + markerLength, length: selection.length))
    }
}
