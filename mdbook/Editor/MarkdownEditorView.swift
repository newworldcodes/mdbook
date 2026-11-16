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
            textView.textContainerInset = theme.textContainerInset
            textView.font = theme.baseFont
            textView.textColor = theme.textColor
            textView.typingAttributes = theme.baseAttributes
            textView.linkTextAttributes = theme.linkTextAttributes
            textView.insertionPointColor = theme.accentColor
            (textView.layoutManager as? MarkdownLayoutManager)?.codeBlockBackground = theme.codeBackground
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
            MarkdownStyler(theme: theme).applyAll(to: storage, spans: spans, activeParagraph: caretParagraph)
            invalidateGlyphs(in: NSRange(location: 0, length: storage.length), textView: textView)
            textView.typingAttributes = theme.baseAttributes
        }

        /// Called when the caret moves: reveal markers in the new paragraph and hide
        /// them in the paragraph that was left.
        private func updateActiveParagraph() {
            guard let textView, let storage = textView.textStorage, theme.hidesMarkers else { return }
            let newRange = paragraphRange(for: textView)
            guard newRange != activeParagraph else { return }
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
