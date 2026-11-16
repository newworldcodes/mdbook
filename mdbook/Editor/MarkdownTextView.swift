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
        if event.clickCount == 1, toggleTaskCheckbox(at: event) || enterRenderedBlock(at: event) {
            return
        }
        super.mouseDown(with: event)
    }

    /// Called when the view's width changes (rendered tables are fitted to it).
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if newSize.width != oldWidth { onWidthChange?() }
    }

    /// A click on a rendered table or image puts the caret in its source (the clicked cell
    /// or image), which switches it to editable source.
    private func enterRenderedBlock(at event: NSEvent) -> Bool {
        guard let layoutManager = layoutManager as? MarkdownLayoutManager, let textContainer else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fragmentGlyphs = NSRange()
        _ = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndex(for: containerPoint, in: textContainer), effectiveRange: &fragmentGlyphs)
        let characters = layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
        guard let rendering = layoutManager.blockRendering(in: characters),
              let frame = layoutManager.frame(for: rendering, origin: textContainerOrigin),
              frame.contains(point) else { return false }
        let location = rendering.sourceLocation(at: NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)) ?? rendering.range.location
        setSelectedRange(NSRange(location: location, length: 0))
        return true
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
        var paragraph = ns.paragraphRange(for: NSRange(location: selection.location, length: 0))
        var line = ns.substring(with: paragraph)
        if line.hasSuffix("\n") { line.removeLast() }

        // Inside a block quote, continue the quote (and any list inside it).
        let quotePrefix = Self.quotePrefix(of: line)
        let quoteLength = (quotePrefix as NSString).length
        if quoteLength > 0 {
            guard selection.location >= paragraph.location + quoteLength else {
                super.insertNewline(sender)
                return
            }
            line = String(line.dropFirst(quotePrefix.count))
            paragraph = NSRange(location: paragraph.location + quoteLength, length: paragraph.length - quoteLength)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Return on an empty quote line ends the quote.
                insertText("", replacementRange: NSRange(location: paragraph.location - quoteLength, length: quoteLength + (line as NSString).length))
                return
            }
        }
        let lineNS = line as NSString

        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) else {
            if quoteLength > 0 {
                insertText("\n" + quotePrefix, replacementRange: selection)
            } else {
                super.insertNewline(sender)
            }
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
        insertText("\n" + quotePrefix + indent + marker + spacing + task, replacementRange: selection)
    }

    /// The `> > ` run starting a block quote line, normalised to `> ` per level.
    static func quotePrefix(of line: String) -> String {
        var depth = 0
        var rest = Substring(line)
        while true {
            let trimmed = rest.drop { $0 == " " || $0 == "\t" }
            guard trimmed.first == ">" else { break }
            depth += 1
            rest = trimmed.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }
        guard depth > 0 else { return "" }
        // Keep the line's own spelling so offsets stay right.
        return String(line.prefix(line.count - rest.count))
    }

    /// Format ▸ Quote: quotes the selected lines, or unquotes them one level if they're all
    /// quoted already.
    @objc func toggleQuoteMarkdown(_ sender: Any?) {
        let ns = string as NSString
        let span = ns.lineRange(for: selectedRange())
        var lines: [String] = []
        ns.enumerateSubstrings(in: span, options: [.byLines]) { line, _, _, _ in lines.append(line ?? "") }
        if lines.isEmpty { lines = [""] }
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let unquote = !content.isEmpty && content.allSatisfy { $0.drop { $0 == " " }.hasPrefix(">") }
        let changed = lines.map { line -> String in
            if unquote {
                let leading = line.prefix { $0 == " " }
                var rest = line.dropFirst(leading.count)
                guard rest.hasPrefix(">") else { return line }
                rest = rest.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                return String(leading) + rest
            }
            return line.isEmpty ? ">" : "> " + line
        }
        let hadTerminator = span.length > 0 && [0x0A, 0x0D].contains(ns.character(at: NSMaxRange(span) - 1))
        let replacement = changed.joined(separator: "\n") + (hadTerminator ? "\n" : "")
        insertText(replacement, replacementRange: span)
        setSelectedRange(NSRange(location: span.location, length: (replacement as NSString).length - (hadTerminator ? 1 : 0)))
    }

    // MARK: - Link completion

    /// Supplies link destinations (chapter paths and `#anchors`) for the text typed so far.
    var linkCompletions: ((String) -> [String])?

    /// The destination being typed inside `[text](…`, if the caret is in one.
    private var linkDestinationRange: NSRange? {
        let ns = string as NSString
        let caret = selectedRange()
        guard caret.length == 0, caret.location > 1 else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: caret.location, length: 0)).location
        var index = caret.location
        while index > lineStart {
            let character = ns.character(at: index - 1)
            if character == 0x28, index - 2 >= lineStart, ns.character(at: index - 2) == 0x5D { // "](" 
                return NSRange(location: index, length: caret.location - index)
            }
            // Destinations have no spaces or closing parentheses.
            if character == 0x20 || character == 0x29 || character == 0x09 { return nil }
            index -= 1
        }
        return nil
    }

    override var rangeForUserCompletion: NSRange {
        linkDestinationRange ?? super.rangeForUserCompletion
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard let destination = linkDestinationRange, destination == charRange, let linkCompletions else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        index.pointee = -1
        return linkCompletions((string as NSString).substring(with: charRange))
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        // Offer destinations as soon as a link's `](` or an anchor's `#` is typed.
        guard let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string,
              typed == "(" || typed == "#", linkCompletions != nil, linkDestinationRange != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.linkDestinationRange != nil else { return }
            self.complete(nil)
        }
    }

    // MARK: - List indentation

    override func insertTab(_ sender: Any?) {
        if !shiftListItems(outdent: false) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !shiftListItems(outdent: true) { super.insertBacktab(sender) }
    }

    /// A parsed list item line.
    private struct ListLine {
        var indent: Int
        var marker: String
        /// The marker plus the spacing after it: how far nested content must be indented.
        var contentOffset: Int
        var number: Int?
        var delimiter: String
        var rest: String
    }

    private static func parseListLine(_ line: String) -> ListLine? {
        let ns = line as NSString
        guard let pattern = listItemPattern,
              let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: match.range(at: 1)).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let number = match.range(at: 3).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: 3)))
        let delimiter = match.range(at: 4).location == NSNotFound ? "" : ns.substring(with: match.range(at: 4))
        let rest = ns.substring(from: match.range(at: 5).location)
        return ListLine(
            indent: indent,
            marker: ns.substring(with: match.range(at: 2)),
            contentOffset: match.range(at: 2).length + match.range(at: 5).length,
            number: number,
            delimiter: delimiter,
            rest: rest
        )
    }

    /// Indents (Tab) or outdents (Shift-Tab) every list item the selection touches.
    /// Returns false, leaving the key to the default behaviour, unless all of the
    /// non-blank selected lines are list items.
    private func shiftListItems(outdent: Bool) -> Bool {
        let ns = string as NSString
        let selection = selectedRange()
        let span = ns.lineRange(for: selection)
        var lines: [String] = []
        ns.enumerateSubstrings(in: span, options: [.byLines]) { line, _, _, _ in lines.append(line ?? "") }
        if lines.isEmpty { lines = [""] }
        let parsed = lines.map(Self.parseListLine)
        guard parsed.contains(where: { $0 != nil }),
              zip(lines, parsed).allSatisfy({ $1 != nil || $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }

        // The list items above the selection give the levels to indent to or out to.
        var context = listContext(above: span.location, in: ns)
        var output: [String] = []
        for (line, item) in zip(lines, parsed) {
            guard var item else {
                output.append(line)
                continue
            }
            let siblingAtLevel = { (indent: Int) in context.last { $0.indent == indent } }
            if outdent {
                guard item.indent > 0 else {
                    output.append(line)
                    context.append(item)
                    continue
                }
                let parent = context.last { $0.indent < item.indent }
                item.indent = parent?.indent ?? 0
                if item.number != nil { item.number = (siblingAtLevel(item.indent)?.number ?? 0) + 1 }
            } else {
                let sibling = siblingAtLevel(item.indent)
                item.indent += sibling?.contentOffset ?? item.contentOffset
                if item.number != nil { item.number = (siblingAtLevel(item.indent)?.number ?? 0) + 1 }
            }
            context.removeAll { $0.indent > item.indent }
            context.append(item)
            let marker = item.number.map { "\($0)\(item.delimiter)" } ?? item.marker
            output.append(String(repeating: " ", count: item.indent) + marker + item.rest)
        }

        let hadTerminator = span.length > 0 && [0x0A, 0x0D].contains(ns.character(at: NSMaxRange(span) - 1))
        let replacement = output.joined(separator: "\n") + (hadTerminator ? "\n" : "")
        let firstDelta = (output.first as NSString?)?.length ?? 0
        let lineDelta = firstDelta - ((lines.first as NSString?)?.length ?? 0)
        insertText(replacement, replacementRange: span)

        if selection.length == 0 {
            // Keep the caret on the same character of the item's text.
            let location = max(span.location, selection.location + lineDelta)
            setSelectedRange(NSRange(location: min(location, (string as NSString).length), length: 0))
        } else {
            let newLength = (replacement as NSString).length - (hadTerminator ? 1 : 0)
            setSelectedRange(NSRange(location: span.location, length: newLength))
        }
        return true
    }

    /// The nearest list item at each level above `location`, outermost first. Scanning
    /// up, items deeper than one already seen belong to other branches and are skipped;
    /// an unindented line that isn't a list item is where the list starts.
    private func listContext(above location: Int, in ns: NSString) -> [ListLine] {
        var nearest: [Int: ListLine] = [:]
        var shallowest = Int.max
        var end = location
        var scanned = 0
        while end > 0, scanned < 500 {
            let lineRange = ns.lineRange(for: NSRange(location: end - 1, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            end = lineRange.location
            scanned += 1
            if let item = Self.parseListLine(line) {
                guard item.indent <= shallowest else { continue }
                if nearest[item.indent] == nil { nearest[item.indent] = item }
                shallowest = item.indent
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") {
                break
            }
        }
        return nearest.values.sorted { $0.indent < $1.indent }
    }

    // MARK: - Formatting actions (reached through the responder chain)

    /// Set by the editor coordinator, which knows where the tables are.
    var onFormatTable: (() -> Void)?

    @objc func formatTableMarkdown(_ sender: Any?) { onFormatTable?() }

    @objc func insertTableMarkdown(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        let paragraph = ns.paragraphRange(for: selection)
        let lineIsEmpty = ns.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let table = "| Column 1 | Column 2 |\n| -------- | -------- |\n|          |          |\n"
        let prefix = lineIsEmpty || selection.location == paragraph.location ? "" : "\n\n"
        let insertion = prefix + table
        insertText(insertion, replacementRange: selection)
        // Park the caret in the first header cell.
        setSelectedRange(NSRange(location: selection.location + (prefix as NSString).length + 2, length: 8))
    }

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

    // MARK: - Dropping and pasting images

    /// The file being edited; dropped and pasted images are saved relative to it.
    var documentURL: URL?

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tif", "tiff", "bmp"]

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }

    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        if type == .fileURL, documentURL != nil, !imageFiles(on: dragInfo.draggingPasteboard).isEmpty {
            return .copy
        }
        return super.dragOperation(for: dragInfo, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = imageFiles(on: sender.draggingPasteboard)
        guard !files.isEmpty, documentURL != nil else { return super.performDragOperation(sender) }
        let location = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        return insertImages(files.compactMap(importImage(at:)), replacing: NSRange(location: location, length: 0))
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let selection = selectedRange()

        // Image files copied in Finder, or image data such as a screenshot.
        let files = imageFiles(on: pasteboard)
        if documentURL != nil, !files.isEmpty {
            if !insertImages(files.compactMap(importImage(at:)), replacing: selection) { NSSound.beep() }
            return
        }
        if documentURL != nil, pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard) {
            if !insertImages([savePastedImage(image)].compactMap { $0 }, replacing: selection) { NSSound.beep() }
            return
        }

        // A URL pasted over selected text links the text.
        let ns = string as NSString
        if selection.length > 0, let pasted = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           Self.looksLikeURL(pasted) {
            let label = ns.substring(with: selection)
            if !label.contains("\n") {
                insertText("[\(label)](\(pasted))", replacementRange: selection)
                return
            }
        }
        super.paste(sender)
    }

    static func looksLikeURL(_ string: String) -> Bool {
        guard !string.isEmpty, !string.contains(where: \.isWhitespace),
              let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }

    private func imageFiles(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Inserts image markdown on lines of its own. Returns false if there was nothing to insert.
    private func insertImages(_ markdown: [String], replacing range: NSRange) -> Bool {
        guard !markdown.isEmpty else { return false }
        let ns = string as NSString
        var text = markdown.joined(separator: "\n")
        if range.location > 0, ns.character(at: range.location - 1) != 0x0A { text = "\n" + text }
        if NSMaxRange(range) < ns.length, ns.character(at: NSMaxRange(range)) != 0x0A { text += "\n" }
        insertText(text, replacementRange: range)
        return true
    }

    /// Markdown for an image file: linked where it is if it's already beside the document
    /// (or below it), otherwise copied into an `images` folder next to the document.
    private func importImage(at source: URL) -> String? {
        guard let folder = documentURL?.deletingLastPathComponent().standardizedFileURL else { return nil }
        let name = source.deletingPathExtension().lastPathComponent
        let sourcePath = source.standardizedFileURL.path
        if sourcePath.hasPrefix(folder.path + "/") {
            return Self.imageMarkdown(alt: name, relativePath: String(sourcePath.dropFirst(folder.path.count + 1)))
        }
        do {
            let destination = try Self.uniqueURL(in: folder.appendingPathComponent("images"), name: source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: destination)
            return Self.imageMarkdown(alt: name, relativePath: "images/" + destination.lastPathComponent)
        } catch {
            return nil
        }
    }

    /// Saves pasted image data as a PNG in the `images` folder next to the document.
    private func savePastedImage(_ image: NSImage) -> String? {
        guard let folder = documentURL?.deletingLastPathComponent(),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Pasted image \(formatter.string(from: Date())).png"
        do {
            let destination = try Self.uniqueURL(in: folder.appendingPathComponent("images"), name: name)
            try png.write(to: destination)
            return Self.imageMarkdown(alt: "Pasted image", relativePath: "images/" + destination.lastPathComponent)
        } catch {
            return nil
        }
    }

    private static func imageMarkdown(alt: String, relativePath: String) -> String {
        // CommonMark destinations can't contain spaces; encode them (the resolver decodes).
        "![\(alt)](\(relativePath.replacingOccurrences(of: " ", with: "%20")))"
    }

    /// `folder/name`, or `folder/name-2`, `-3`… if taken. Creates `folder` if needed.
    private static func uniqueURL(in folder: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Copy as rich text

    /// Copies the selection (or the whole document) rendered: HTML and RTF for apps that
    /// take formatting, the markdown itself as plain text.
    @objc func copyAsRichText(_ sender: Any?) {
        let ns = string as NSString
        let range = selectedRange().length > 0 ? selectedRange() : NSRange(location: 0, length: ns.length)
        let markdown = ns.substring(with: range)
        var renderer = HTMLRenderer()
        if let documentURL {
            renderer.imageSource = { BookExport.embeddedImage($0, relativeTo: documentURL) }
        }
        let html = BookExport.page(title: documentURL?.lastPathComponent ?? "", body: renderer.render(markdown))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        if let attributed = PrintRenderer.attributedString(html: html),
           let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(markdown, forType: .string)
    }
}
