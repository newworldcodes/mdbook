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
    /// The file being edited, for resolving relative image paths and saving dropped images.
    var documentURL: URL? = nil
    /// The project's markdown files, offered when typing a link destination.
    var projectFiles: [URL] = []
    /// Text size multiplier and typeface (from Settings / View ▸ Zoom).
    var textScale: CGFloat = 1
    var readingFont: ReadingFont = .system
    /// Dim everything but the paragraph being edited.
    var focusMode = false
    /// Keep the line being edited in the middle of the view.
    var typewriterMode = false
    /// Scroll to the heading matching this anchor whenever a new request arrives.
    var anchorRequest: AnchorRequest? = nil
    /// Select and scroll to this range whenever a new request arrives.
    var revealRequest: RevealRequest? = nil
    /// Reports the vertical scroll position as a 0...1 fraction (used for split-pane sync).
    var onScroll: ((Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = MarkdownTextView.makeScrollable()
        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.documentURL = documentURL
        textView.delegate = coordinator
        textView.layoutManager?.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.configure(textView)
        coordinator.observeScrolling(of: scrollView)
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.restyleEverything()

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            if let request = revealRequest, coordinator.handledRevealID != request.id {
                coordinator.reveal(request)
            } else if let request = anchorRequest, coordinator.handledAnchorID != request.id {
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
        textView.documentURL = documentURL

        var needsRestyle = false
        let theme = EditorTheme(mode: mode, scale: textScale, font: readingFont)
        if coordinator.theme != theme {
            coordinator.theme = theme
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
        if let request = revealRequest, coordinator.handledRevealID != request.id {
            coordinator.reveal(request)
        }
        coordinator.applyFocus()
        coordinator.updateTypewriterInsets()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditorView
        weak var textView: MarkdownTextView?
        var theme: EditorTheme
        var isPushingChange = false
        var handledAnchorID: UUID?
        var handledRevealID: UUID?
        private var activeParagraph: NSRange?
        private var spans = MarkdownSpans()
        private var scrollObserver: NSObjectProtocol?
        private var restyleForWidthPending = false
        /// Characters edited since the last restyle (in current coordinates) and the change
        /// in length, for restyling incrementally.
        private var pendingEdit: (range: NSRange, delta: Int)?
        /// Below this length a full restyle is cheap enough to do on every keystroke.
        static let incrementalThreshold = 20_000
        /// Above this length the rescan after a keystroke runs in the background.
        static let backgroundScanThreshold = 200_000
        /// Bumped on every edit, so a background scan of older text is discarded.
        private var textVersion = 0
        private var backgroundScan: Task<Void, Never>?
        private let imageCache = NSCache<NSString, NSImage>()
        /// Local images that failed to load; cleared on every edit (a dropped image may now exist).
        private var missingImages = Set<String>()
        private var loadingImages = Set<String>()

        init(parent: MarkdownEditorView) {
            self.parent = parent
            self.theme = EditorTheme(mode: parent.mode, scale: parent.textScale, font: parent.readingFont)
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func configure(_ textView: MarkdownTextView) {
            textView.onFormatTable = { [weak self] in self?.formatTableAtCaret() }
            textView.onWidthChange = { [weak self] in self?.widthDidChange() }
            textView.linkCompletions = { [weak self] partial in self?.linkCompletions(for: partial) ?? [] }
            textView.textContainerInset = theme.textContainerInset
            textView.font = theme.baseFont
            textView.textColor = theme.textColor
            textView.typingAttributes = theme.baseAttributes
            textView.linkTextAttributes = theme.linkTextAttributes
            textView.insertionPointColor = theme.accentColor
            if let layoutManager = textView.layoutManager as? MarkdownLayoutManager {
                layoutManager.codeBlockBackground = theme.codeBackground
                layoutManager.tableHeaderBackground = theme.codeBackground
                layoutManager.quoteIndent = MarkdownStyler(theme: theme).quoteIndent
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

        /// Selects a range (a search match), scrolls it into view and flashes it.
        func reveal(_ request: RevealRequest) {
            handledRevealID = request.id
            guard let textView, NSMaxRange(request.range) <= (textView.string as NSString).length else { return }
            textView.window?.makeFirstResponder(textView)
            // Selecting may restyle (e.g. a rendered table switches to source), so lay out first.
            textView.setSelectedRange(request.range)
            textView.layoutManager?.ensureLayout(forCharacterRange: request.range)
            textView.scrollRangeToVisible(request.range)
            textView.showFindIndicator(for: request.range)
        }

        // MARK: Styling

        /// After an edit: rescans, then restyles only the region whose styling changed (whole
        /// paragraphs and blocks), unless the document is short or most of it changed.
        private func restyleAfterEdit() {
            guard let textView, let storage = textView.textStorage, let edit = pendingEdit else {
                restyleEverything()
                return
            }
            pendingEdit = nil
            guard storage.length >= Self.incrementalThreshold else {
                restyleEverything()
                return
            }
            if storage.length >= Self.backgroundScanThreshold {
                restyleLargeDocumentAfterEdit(edit)
                return
            }
            let previous = spans
            let current = MarkdownHighlighter.scan(storage.string)
            let ns = storage.string as NSString
            let caretParagraph = paragraphRange(for: textView)
            var dirty = IncrementalStyling.dirtyRange(old: previous, new: current, edit: edit.range, delta: edit.delta) ?? edit.range
            // The caret's paragraph (or table) shows its markers; include it, and the one it left.
            dirty = NSUnionRange(dirty, caretParagraph)
            if let activeParagraph, NSMaxRange(activeParagraph) <= storage.length {
                dirty = NSUnionRange(dirty, activeParagraph)
            }
            let region = IncrementalStyling.expand(dirty, in: ns, spans: current)
            guard region.length < storage.length / 2 else {
                restyleEverything(spans: current)
                return
            }
            spans = current
            restyle(region: region)
        }

        /// Restyles `region` (whole paragraphs and blocks) with the current spans.
        private func restyle(region: NSRange) {
            guard let textView, let storage = textView.textStorage else { return }
            let caretParagraph = paragraphRange(for: textView)
            activeParagraph = caretParagraph
            MarkdownStyler(theme: theme).applyAll(
                to: storage,
                spans: spans,
                activeRegion: activeRegion(for: caretParagraph),
                blockWidth: blockWidth(of: textView),
                loadImage: { [weak self] in self?.image(for: $0) },
                region: region
            )
            invalidateGlyphs(in: region, textView: textView)
            textView.typingAttributes = theme.baseAttributes
            applyFocus()
        }

        /// Large documents: restyle the edited paragraph now with the previous spans shifted
        /// past the edit, and rescan in the background, restyling whatever that changes.
        private func restyleLargeDocumentAfterEdit(_ edit: (range: NSRange, delta: Int)) {
            guard let textView, let storage = textView.textStorage else { return }
            textVersion += 1
            let version = textVersion
            spans = spans.shifted(past: edit.range, delta: edit.delta)
            let ns = storage.string as NSString
            var local = NSUnionRange(edit.range, paragraphRange(for: textView))
            if let activeParagraph, NSMaxRange(activeParagraph) <= storage.length {
                local = NSUnionRange(local, activeParagraph)
            }
            restyle(region: IncrementalStyling.expand(local, in: ns, spans: spans))

            // Snapshot the text: the storage keeps changing while the scan runs.
            let snapshot = String(ns)
            backgroundScan?.cancel()
            backgroundScan = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let fresh = await Task.detached(priority: .userInitiated) { MarkdownHighlighter.scan(snapshot) }.value
                guard let self, !Task.isCancelled, version == self.textVersion,
                      let storage = self.textView?.textStorage else { return }
                let previous = self.spans
                self.spans = fresh
                guard let dirty = IncrementalStyling.dirtyRange(old: previous, new: fresh) else { return }
                let region = IncrementalStyling.expand(dirty, in: storage.string as NSString, spans: fresh)
                if region.length >= storage.length / 2 {
                    self.restyleEverything(spans: fresh)
                } else {
                    self.restyle(region: region)
                }
            }
        }

        // MARK: NSTextStorageDelegate

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            if let pending = pendingEdit {
                // Map the earlier edit into current coordinates, then merge.
                var earlier = pending.range
                if earlier.location >= NSMaxRange(editedRange) - delta { earlier.location += delta }
                pendingEdit = (NSUnionRange(earlier, editedRange), pending.delta + delta)
            } else {
                pendingEdit = (editedRange, delta)
            }
        }

        /// Rescans the document and reapplies every attribute.
        func restyleEverything(spans precomputed: MarkdownSpans? = nil) {
            guard let textView, let storage = textView.textStorage else { return }
            pendingEdit = nil
            if precomputed == nil {
                // A full rescan supersedes any scan still running.
                textVersion += 1
                backgroundScan?.cancel()
            }
            spans = precomputed ?? MarkdownHighlighter.scan(storage.string)
            let caretParagraph = paragraphRange(for: textView)
            activeParagraph = caretParagraph
            MarkdownStyler(theme: theme).applyAll(
                to: storage,
                spans: spans,
                activeRegion: activeRegion(for: caretParagraph),
                blockWidth: blockWidth(of: textView),
                loadImage: { [weak self] in self?.image(for: $0) }
            )
            invalidateGlyphs(in: NSRange(location: 0, length: storage.length), textView: textView)
            textView.typingAttributes = theme.baseAttributes
            applyFocus()
        }

        /// The width a rendered table or image may use: the text container minus its padding.
        private func blockWidth(of textView: NSTextView) -> CGFloat {
            guard let container = textView.textContainer else { return .greatestFiniteMagnitude }
            return max(0, container.size.width - container.lineFragmentPadding * 2)
        }

        /// Rendered tables and images are fitted to the width, so refit them when it changes.
        /// Live resizing sends many changes; restyle once per run-loop turn.
        private func widthDidChange() {
            let hasBlocks = !spans.tables.isEmpty || spans.links.contains(where: \.isImage)
            guard theme.mode == .wysiwyg, hasBlocks, !restyleForWidthPending else { return }
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

            // Entering or leaving a table or a line with images swaps its rendering, so
            // restyle those paragraphs (and whole blocks around them).
            let oldIsBlock = activeParagraph.map { needsRestyleOnCaretChange($0, storage: storage) } ?? false
            let newIsBlock = needsRestyleOnCaretChange(newRange, storage: storage)
            if oldIsBlock || newIsBlock {
                var region = newRange
                if let activeParagraph, NSMaxRange(activeParagraph) <= storage.length {
                    region = NSUnionRange(region, activeParagraph)
                }
                restyle(region: IncrementalStyling.expand(region, in: storage.string as NSString, spans: spans))
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
            applyFocus()
        }

        private func needsRestyleOnCaretChange(_ paragraph: NSRange, storage: NSTextStorage) -> Bool {
            activeRegion(for: paragraph) != paragraph
                || hasBlockRendering(in: paragraph, storage: storage)
                // A quote line's first-line indent depends on whether its `>` shows.
                || spans.blockQuotes.contains { NSIntersectionRange($0.line, paragraph).length > 0 && $0.marker.length > 0 }
                || spans.links.contains { $0.isImage && NSIntersectionRange($0.range, paragraph).length > 0 }
        }

        private func hasBlockRendering(in range: NSRange, storage: NSTextStorage) -> Bool {
            guard NSMaxRange(range) <= storage.length, range.length > 0 else { return false }
            var found = false
            storage.enumerateAttribute(.markdownBlockRendering, in: range, options: []) { value, _, stop in
                if value != nil {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        // MARK: Focus and typewriter modes

        /// Dims everything outside the caret's paragraph (or table) with temporary
        /// attributes, which leave the text storage alone.
        func applyFocus() {
            guard let textView, let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            guard parent.focusMode, theme.mode == .wysiwyg, full.length > 0 else { return }
            let active = activeRegion(for: paragraphRange(for: textView))
            let dimmed = NSColor.tertiaryLabelColor
            if active.location > 0 {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: dimmed, forCharacterRange: NSRange(location: 0, length: active.location))
            }
            if NSMaxRange(active) < full.length {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: dimmed, forCharacterRange: NSRange(location: NSMaxRange(active), length: full.length - NSMaxRange(active)))
            }
        }

        /// In typewriter mode, room below the text so the last lines can reach the middle.
        func updateTypewriterInsets() {
            guard let scrollView = textView?.enclosingScrollView else { return }
            let bottom = parent.typewriterMode ? scrollView.contentView.bounds.height / 2 : 0
            guard scrollView.contentInsets.bottom != bottom else { return }
            scrollView.automaticallyAdjustsContentInsets = !parent.typewriterMode
            var insets = scrollView.contentInsets
            insets.bottom = bottom
            scrollView.contentInsets = insets
        }

        /// Scrolls so the caret's line sits in the middle of the view.
        func centerCaret() {
            guard parent.typewriterMode, let textView, let layoutManager = textView.layoutManager,
                  let scrollView = textView.enclosingScrollView, textView.window != nil else { return }
            let length = (textView.string as NSString).length
            let location = min(textView.selectedRange().location, length)
            // Layout is non-contiguous: positions below unlaid-out text are only estimates.
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(location + 1, length)))
            var rect: NSRect
            if location >= length, !layoutManager.extraLineFragmentRect.isEmpty {
                rect = layoutManager.extraLineFragmentRect
            } else if layoutManager.numberOfGlyphs > 0 {
                let glyph = min(layoutManager.glyphIndexForCharacter(at: location), layoutManager.numberOfGlyphs - 1)
                rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                return
            }
            rect.origin.y += textView.textContainerOrigin.y
            let clip = scrollView.contentView
            let target = rect.midY - clip.bounds.height / 2
            let minimum = -scrollView.contentInsets.top
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(minimum, target)))
            scrollView.reflectScrolledClipView(clip)
        }

        // MARK: Link completion

        /// Destinations matching what's been typed after `](`: chapter paths relative to this
        /// document and `#anchors` for its headings, or after `file.md#`, that file's headings.
        func linkCompletions(for partial: String) -> [String] {
            let document = parent.documentURL
            if let hash = partial.firstIndex(of: "#") {
                let filePart = String(partial[..<hash])
                let anchorPart = String(partial[partial.index(after: hash)...])
                let slugs: [String]
                if filePart.isEmpty {
                    slugs = headingSlugs(in: textView?.string ?? "")
                } else if case .file(let url, _) = LinkResolver.resolve(filePart, relativeTo: document),
                          let source = try? TextFile.read(url).text {
                    slugs = headingSlugs(in: source)
                } else {
                    slugs = []
                }
                return slugs.filter { anchorPart.isEmpty || $0.localizedCaseInsensitiveContains(anchorPart) }
                    .map { filePart + "#" + $0 }
            }

            var candidates: [String] = []
            if let document {
                candidates += parent.projectFiles
                    .filter { $0.standardizedFileURL != document.standardizedFileURL }
                    .map { LinkResolver.relativePath(from: document, to: $0) }
            }
            candidates += headingSlugs(in: textView?.string ?? "").map { "#" + $0 }
            guard !partial.isEmpty else { return candidates }
            return candidates.filter { $0.localizedCaseInsensitiveContains(partial) }
        }

        private func headingSlugs(in source: String) -> [String] {
            let ns = source as NSString
            var seen = Set<String>()
            return MarkdownHighlighter.scan(source).headings
                .sorted { $0.line.location < $1.line.location }
                .map { HeadingSlug.slug(for: HeadingSlug.plainText(ofHeadingSource: ns.substring(with: $0.content))) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        // MARK: Images

        /// The image an image destination refers to, if it's available now. Local files load
        /// synchronously (and are cached); remote ones load in the background and restyle.
        private func image(for destination: String) -> NSImage? {
            switch LinkResolver.resolve(destination, relativeTo: parent.documentURL) {
            case .file(let url, _):
                let key = url.path as NSString
                if let cached = imageCache.object(forKey: key) { return cached }
                guard !missingImages.contains(url.path) else { return nil }
                guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
                    missingImages.insert(url.path)
                    return nil
                }
                imageCache.setObject(image, forKey: key)
                return image
            case .external(let url):
                let key = url.absoluteString as NSString
                if let cached = imageCache.object(forKey: key) { return cached }
                guard ["http", "https"].contains(url.scheme?.lowercased()), !loadingImages.contains(url.absoluteString) else { return nil }
                loadingImages.insert(url.absoluteString)
                Task { [weak self] in
                    // Needs the Outgoing Connections entitlement; without it this quietly fails.
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = NSImage(data: data), image.size.width > 0, let self else { return }
                    self.imageCache.setObject(image, forKey: key)
                    self.restyleEverything()
                }
                return nil
            case .anchor, .invalid:
                return nil
            }
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
            missingImages.removeAll()
            restyleAfterEdit()
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
            centerCaret()
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

        /// The line fragment holding a block rendering's anchor grows by the rendering's
        /// height, and fragments made only of its hidden source collapse, so what the layout
        /// manager draws has room. Hidden glyphs join the fragment of the line before, so the
        /// rendering is found anywhere in the fragment, not at its start.
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard let rendering = (layoutManager as? MarkdownLayoutManager)?.blockRendering(in: characters) else { return false }

            if NSLocationInRange(rendering.anchor, characters) {
                // Keep the height of whatever visible text shares this fragment.
                let hasVisibleText = !rendering.hidesSource || characters.location < rendering.range.location
                let leading = hasVisibleText ? lineFragmentUsedRect.pointee.height : 0
                rendering.offsetInFragment = leading
                lineFragmentRect.pointee.size.height = leading + rendering.reservedHeight
                lineFragmentUsedRect.pointee.size.height = leading + rendering.reservedHeight
                return true
            }
            // Only collapse fragments made entirely of hidden source.
            guard rendering.hidesSource, characters.location > rendering.range.location,
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
