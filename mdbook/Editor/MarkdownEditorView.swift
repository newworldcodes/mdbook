//
//  MarkdownEditorView.swift
//  mdbook
//
//  SwiftUI wrapper around `MarkdownTextView` that keeps the markdown text in
//  sync with the model and applies live styling.
//

import AppKit
import SwiftUI

struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var mode: EditorTheme.Mode
    var onOpenLink: (String) -> Void
    /// Scroll to the heading matching this anchor whenever a new request arrives.
    var anchorRequest: AnchorRequest? = nil
    /// Reports the vertical scroll position as a 0...1 fraction (used for split-pane sync).
    var onScroll: ((Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = MarkdownTextView.makeScrollable()
        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.layoutManager?.delegate = coordinator
        coordinator.configure(textView)
        coordinator.observeScrolling(of: scrollView)
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.restyleEverything()

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            if let request = anchorRequest, coordinator.handledAnchorID != request.id {
                coordinator.reveal(anchor: request)
            } else {
                textView.scroll(.zero)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        var needsRestyle = false
        if coordinator.theme.mode != mode {
            coordinator.theme = EditorTheme(mode: mode)
            coordinator.configure(textView)
            needsRestyle = true
        }
        if !coordinator.isPushingChange, textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            needsRestyle = true
        }
        if needsRestyle {
            coordinator.restyleEverything()
        }
        if let request = anchorRequest, coordinator.handledAnchorID != request.id {
            coordinator.reveal(anchor: request)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: MarkdownEditorView
        weak var textView: MarkdownTextView?
        var theme: EditorTheme
        var isPushingChange = false
        var handledAnchorID: UUID?
        private var activeParagraph: NSRange?
        private var spans = MarkdownSpans()
        private var scrollObserver: NSObjectProtocol?
        private var restyleForWidthPending = false

        init(parent: MarkdownEditorView) {
            self.parent = parent
            self.theme = EditorTheme(mode: parent.mode)
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func configure(_ textView: MarkdownTextView) {
            textView.onFormatTable = { [weak self] in self?.formatTableAtCaret() }
            textView.onWidthChange = { [weak self] in self?.widthDidChange() }
            textView.textContainerInset = theme.textContainerInset
            textView.font = theme.baseFont
            textView.textColor = theme.textColor
            textView.typingAttributes = theme.baseAttributes
            textView.linkTextAttributes = theme.linkTextAttributes
            textView.insertionPointColor = theme.accentColor
            if let layoutManager = textView.layoutManager as? MarkdownLayoutManager {
                layoutManager.codeBlockBackground = theme.codeBackground
                layoutManager.tableHeaderBackground = theme.codeBackground
            }
        }

        func observeScrolling(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: nil
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView, let onScroll = self.parent.onScroll,
                          let document = scrollView.documentView else { return }
                    let visible = scrollView.contentView.bounds
                    let scrollable = document.frame.height - visible.height
                    let fraction = scrollable > 0 ? Double(visible.origin.y / scrollable) : 0
                    onScroll(min(max(fraction, 0), 1))
                }
            }
        }

        // MARK: Tables

        /// Aligns the columns of the table containing the caret.
        func formatTableAtCaret() {
            guard let textView else { return }
            let location = textView.selectedRange().location
            guard let table = spans.tables.first(where: { $0.contains(location) }) else {
                NSSound.beep()
                return
            }
            formatTable(table)
        }

        private func formatTable(_ table: MarkdownSpans.Table) {
            guard let textView, let storage = textView.textStorage,
                  NSMaxRange(table.range) <= storage.length else { return }
            let ns = storage.string as NSString
            let source = ns.substring(with: table.range)
            let formatted = MarkdownTableFormatter.format(source)
            guard formatted != source,
                  textView.shouldChangeText(in: table.range, replacementString: formatted) else { return }

            let selection = textView.selectedRange()
            storage.replaceCharacters(in: table.range, with: formatted)
            textView.didChangeText()

            // Keep the caret where the user left it, shifted if the table grew or shrank above it.
            let delta = (formatted as NSString).length - table.range.length
            var restored = selection
            if selection.location >= NSMaxRange(table.range) {
                restored.location += delta
            } else if table.contains(selection.location) {
                restored = NSRange(location: min(selection.location, NSMaxRange(table.range) + delta), length: 0)
            }
            let length = storage.length
            restored.location = min(max(0, restored.location), length)
            restored.length = min(restored.length, length - restored.location)
            textView.setSelectedRange(restored)
        }

        /// When the caret leaves a table, tidy its columns.
        private func formatTableIfLeft(from oldParagraph: NSRange?, to newParagraph: NSRange) {
            guard theme.mode == .wysiwyg, let oldParagraph,
                  let table = spans.tables.first(where: { $0.contains(oldParagraph.location) }),
                  !table.contains(newParagraph.location) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let current = self.spans.tables.first(where: { $0.range == table.range }) else { return }
                self.formatTable(current)
            }
        }

        // MARK: Anchors

        func reveal(anchor request: AnchorRequest) {
            handledAnchorID = request.id
            guard let textView else { return }
            let ns = textView.string as NSString
            guard let heading = spans.headings.first(where: { heading in
                let source = ns.substring(with: heading.content)
                return HeadingSlug.matches(anchor: request.anchor, headingText: HeadingSlug.plainText(ofHeadingSource: source))
            }) else {
                NSSound.beep()
                return
            }
            textView.setSelectedRange(NSRange(location: heading.line.location, length: 0))
            textView.scrollToTop(of: heading.line)
        }

        // MARK: Styling

        /// Rescans the document and reapplies every attribute.
        func restyleEverything() {
            guard let textView, let storage = textView.textStorage else { return }
            spans = MarkdownHighlighter.scan(storage.string)
            let caretParagraph = paragraphRange(for: textView)
            activeParagraph = caretParagraph
            MarkdownStyler(theme: theme).applyAll(to: storage, spans: spans, activeRegion: activeRegion(for: caretParagraph), tableWidth: tableWidth(of: textView))
            invalidateGlyphs(in: NSRange(location: 0, length: storage.length), textView: textView)
            textView.typingAttributes = theme.baseAttributes
        }

        /// The width a rendered table may use: the text container minus its line padding.
        private func tableWidth(of textView: NSTextView) -> CGFloat {
            guard let container = textView.textContainer else { return .greatestFiniteMagnitude }
            return max(0, container.size.width - container.lineFragmentPadding * 2)
        }

        /// Rendered tables are fitted to the width, so refit them when it changes. Live
        /// resizing sends many changes; restyle once per run-loop turn.
        private func widthDidChange() {
            guard theme.mode == .wysiwyg, !spans.tables.isEmpty, !restyleForWidthPending else { return }
            restyleForWidthPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restyleForWidthPending = false
                self.restyleEverything()
            }
        }

        /// The paragraph itself, or the whole table when the paragraph is a table row:
        /// tables switch between rendered grid and editable source as a unit.
        private func activeRegion(for paragraph: NSRange) -> NSRange {
            if let table = spans.tables.first(where: { $0.contains(paragraph.location) }) {
                return table.range
            }
            return paragraph
        }

        /// Called when the caret moves: reveal markers in the new paragraph and hide
        /// them in the paragraph that was left.
        private func updateActiveParagraph() {
            guard let textView, let storage = textView.textStorage, theme.hidesMarkers else { return }
            let newRange = paragraphRange(for: textView)
            guard newRange != activeParagraph else { return }
            formatTableIfLeft(from: activeParagraph, to: newRange)

            // Entering or leaving a table changes fonts and kerning, so restyle fully.
            let oldInTable = activeParagraph.map { activeRegion(for: $0) != $0 } ?? false
            let newInTable = activeRegion(for: newRange) != newRange
            if oldInTable || newInTable {
                restyleEverything()
                return
            }
            let styler = MarkdownStyler(theme: theme)
            if let old = activeParagraph, NSMaxRange(old) <= storage.length {
                styler.setMarkersVisible(false, in: old, storage: storage)
                invalidateGlyphs(in: old, textView: textView)
            }
            styler.setMarkersVisible(true, in: newRange, storage: storage)
            invalidateGlyphs(in: newRange, textView: textView)
            activeParagraph = newRange
        }

        private func paragraphRange(for textView: NSTextView) -> NSRange {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let location = min(selection.location, ns.length)
            return ns.paragraphRange(for: NSRange(location: location, length: 0))
        }

        private func invalidateGlyphs(in range: NSRange, textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, range.length > 0 else { return }
            layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isPushingChange = true
            parent.text = textView.string
            isPushingChange = false
            restyleEverything()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            // Never let hidden/marker/link attributes leak into newly typed text.
            var typing = textView.typingAttributes
            typing.removeValue(forKey: .markdownHidden)
            typing.removeValue(forKey: .markdownMarker)
            typing.removeValue(forKey: .markdownTask)
            typing.removeValue(forKey: .link)
            typing.removeValue(forKey: .strikethroughStyle)
            typing.removeValue(forKey: .backgroundColor)
            typing[.foregroundColor] = theme.textColor
            textView.typingAttributes = typing
            updateActiveParagraph()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let destination = link as? String {
                parent.onOpenLink(destination)
                return true
            }
            if let url = link as? URL {
                parent.onOpenLink(url.absoluteString)
                return true
            }
            return false
        }

        // MARK: NSLayoutManagerDelegate

        /// The line fragment holding a rendered table's first character grows by the drawn
        /// table's height and the table's other fragments collapse, so the grid the layout
        /// manager draws has room and nothing else does. Hidden glyphs join the fragment of
        /// the line before, so the table is found anywhere in the fragment, not at its start.
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard let rendering = (layoutManager as? MarkdownLayoutManager)?.tableRendering(in: characters) else { return false }

            if NSLocationInRange(rendering.location, characters) {
                // Keep the height of whatever precedes the table in this fragment.
                let leading = characters.location < rendering.location ? lineFragmentUsedRect.pointee.height : 0
                rendering.offsetInFragment = leading
                lineFragmentRect.pointee.size.height = leading + rendering.reservedHeight
                lineFragmentUsedRect.pointee.size.height = leading + rendering.reservedHeight
                return true
            }
            // Only collapse fragments made entirely of the table's hidden source.
            guard characters.location > rendering.location,
                  NSMaxRange(characters) <= NSMaxRange(rendering.range) + 1 else { return false }
            lineFragmentRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size.height = 0
            baselineOffset.pointee = 0
            return true
        }

        /// Replaces glyphs for hidden markers with null glyphs so they take no space.
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes: UnsafePointer<Int>,
            font: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard theme.hidesMarkers, let storage = layoutManager.textStorage else { return 0 }
            let count = glyphRange.length
            var newProperties = Array(UnsafeBufferPointer(start: properties, count: count))
            var changed = false
            let length = storage.length
            for index in 0..<count {
                let charIndex = characterIndexes[index]
                guard charIndex < length else { continue }
                if storage.attribute(.markdownHidden, at: charIndex, effectiveRange: nil) != nil {
                    newProperties[index] = .null
                    changed = true
                }
            }
            guard changed else { return 0 }
            newProperties.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                layoutManager.setGlyphs(glyphs, properties: base, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            }
            return count
        }
    }
}
