//
//  MarkdownBlockParser.swift
//  mdbook
//
//  Converts GitHub Flavored Markdown into a block tree using swift-markdown
//  (cmark-gfm), the same parser the editor's highlighter uses, so the preview and
//  the editor agree on structure. The tree is what the rendered preview draws.
//

import Foundation
import Markdown

nonisolated enum MarkdownTextAlignment: Hashable, Sendable {
    case left, center, right
}

nonisolated enum MarkdownInlineSegment: Hashable, Sendable {
    case text(AttributedString)
    case image(source: String, alt: String)
}

nonisolated enum MarkdownTaskState: Hashable, Sendable {
    case unchecked
    case checked
}

nonisolated struct MarkdownListItem: Hashable, Sendable {
    var ordinal: Int
    var task: MarkdownTaskState?
    var blocks: [MarkdownBlock]
}

nonisolated struct MarkdownTable: Hashable, Sendable {
    var alignments: [MarkdownTextAlignment]
    var header: [AttributedString]
    var rows: [[AttributedString]]
}

nonisolated indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, content: AttributedString)
    case paragraph([MarkdownInlineSegment])
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownBlock])
    case list(ordered: Bool, items: [MarkdownListItem])
    case table(MarkdownTable)
    case thematicBreak
    /// Display math, already converted to Unicode.
    case math(String)
}

nonisolated enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        // CommonMark doesn't allow spaces in link destinations, but books often contain
        // `[chapter](my chapter.md)`; encode them so those still parse as links.
        let prepared = MarkdownExtensions.prepare(markdown)
        let source = LinkResolver.encodingSpacesInLinkDestinations(prepared.markdown)
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var result = blocks(in: document.children)
        // Footnotes are listed, numbered, under a rule at the end.
        if !prepared.footnotes.isEmpty {
            result.append(.thematicBreak)
            result.append(.list(ordered: true, items: prepared.footnotes.map {
                MarkdownListItem(ordinal: $0.number, task: nil, blocks: parse($0.markdown))
            }))
        }
        return result
    }

    // MARK: - Blocks

    private static func blocks(in children: MarkupChildren) -> [MarkdownBlock] {
        children.compactMap(block)
    }

    private static func block(_ markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let paragraph as Paragraph:
            return .paragraph(segments(paragraph))
        case let heading as Heading:
            return .heading(level: heading.level, content: text(heading))
        case let code as CodeBlock:
            var source = code.code
            if source.hasSuffix("\n") { source.removeLast() }
            // `language` is the whole info string; the first word names the language.
            let language = code.language?.split(whereSeparator: \.isWhitespace).first.map(String.init)
            if language == "math" { return .math(MathText.unicode(fromTeX: source)) }
            return .codeBlock(language: language, code: source)
        case let html as HTMLBlock:
            // Raw HTML isn't rendered; show it as source rather than dropping it.
            var source = html.rawHTML
            if source.hasSuffix("\n") { source.removeLast() }
            return .codeBlock(language: "html", code: source)
        case let quote as BlockQuote:
            return .blockQuote(blocks(in: quote.children))
        case let list as OrderedList:
            return .list(ordered: true, items: items(list.listItems, start: Int(list.startIndex)))
        case let list as UnorderedList:
            return .list(ordered: false, items: items(list.listItems, start: 1))
        case let table as Markdown.Table:
            return .table(self.table(table))
        case is ThematicBreak:
            return .thematicBreak
        default:
            return nil
        }
    }

    private static func items(_ listItems: some Sequence<ListItem>, start: Int) -> [MarkdownListItem] {
        listItems.enumerated().map { index, item in
            let task: MarkdownTaskState? = switch item.checkbox {
            case .checked: .checked
            case .unchecked: .unchecked
            case nil: nil
            }
            return MarkdownListItem(ordinal: start + index, task: task, blocks: blocks(in: item.children))
        }
    }

    private static func table(_ table: Markdown.Table) -> MarkdownTable {
        let alignments: [MarkdownTextAlignment] = table.columnAlignments.map {
            switch $0 {
            case .center: .center
            case .right: .right
            case .left, nil: .left
            }
        }
        let columns = max(table.maxColumnCount, 1)
        func cells(_ row: some Sequence<Markdown.Table.Cell>) -> [AttributedString] {
            var cells = row.map(text)
            cells.append(contentsOf: Array(repeating: AttributedString(), count: max(0, columns - cells.count)))
            return Array(cells.prefix(columns))
        }
        return MarkdownTable(
            alignments: alignments,
            header: cells(table.head.cells),
            rows: table.body.rows.map { cells($0.cells) }
        )
    }

    // MARK: - Inline content

    /// Inline content split into text runs and the images between them.
    private static func segments(_ container: Markup) -> [MarkdownInlineSegment] {
        var renderer = InlineRenderer(imagesAsSegments: true)
        renderer.render(children: container)
        return renderer.finish()
    }

    /// Inline content as one attributed string (images contribute their alt text).
    private static func text(_ container: Markup) -> AttributedString {
        var renderer = InlineRenderer(imagesAsSegments: false)
        renderer.render(children: container)
        return renderer.pending
    }
}

/// Builds `AttributedString`s whose `inlinePresentationIntent` and `link` attributes SwiftUI's
/// `Text` renders directly.
private nonisolated struct InlineRenderer {
    let imagesAsSegments: Bool
    var segments: [MarkdownInlineSegment] = []
    var pending = AttributedString()
    private var intent: InlinePresentationIntent = []
    private var link: URL?

    init(imagesAsSegments: Bool) {
        self.imagesAsSegments = imagesAsSegments
    }

    mutating func render(children markup: Markup) {
        for child in markup.children { render(child) }
    }

    mutating func finish() -> [MarkdownInlineSegment] {
        if !pending.characters.isEmpty || segments.isEmpty {
            segments.append(.text(pending))
        }
        return segments
    }

    private mutating func render(_ markup: Markup) {
        switch markup {
        case let text as Markdown.Text:
            append(text.string)
        case is SoftBreak:
            append(" ")
        case is LineBreak:
            append("\n")
        case let code as InlineCode:
            styled(.code) { $0.append(code.code) }
        case let html as InlineHTML:
            // A `<br>` is a line break; other tags are shown as typed.
            let tag = html.rawHTML.lowercased().filter { !$0.isWhitespace }
            append(["<br>", "<br/>"].contains(tag) ? "\n" : html.rawHTML)
        case let image as Image:
            if imagesAsSegments {
                if !pending.characters.isEmpty {
                    segments.append(.text(pending))
                    pending = AttributedString()
                }
                segments.append(.image(source: image.source ?? "", alt: image.plainText))
            } else {
                append(image.plainText)
            }
        case is Emphasis:
            styled(.emphasized) { $0.render(children: markup) }
        case is Strong:
            styled(.stronglyEmphasized) { $0.render(children: markup) }
        case is Strikethrough:
            styled(.strikethrough) { $0.render(children: markup) }
        case let linkNode as Link:
            let saved = link
            link = linkNode.destination.flatMap(Self.url)
            render(children: linkNode)
            link = saved
        default:
            render(children: markup)
        }
    }

    private mutating func styled(_ added: InlinePresentationIntent, _ body: (inout InlineRenderer) -> Void) {
        let saved = intent
        intent.formUnion(added)
        body(&self)
        intent = saved
    }

    /// Appends text from the prepared document: footnote references become superscript
    /// numbers, math becomes italic Unicode, and emoji shortcodes are replaced.
    private mutating func append(_ string: String) {
        for segment in MarkdownExtensions.segments(in: string) {
            switch segment {
            case .text(let text):
                appendText(MarkdownExtensions.replacingEmojiShortcodes(in: text))
            case .footnoteReference(let number):
                appendText(MathText.superscript(String(number)))
            case .math(let tex):
                styled(.emphasized) { $0.appendText(MathText.unicode(fromTeX: tex)) }
            }
        }
    }

    private mutating func appendText(_ string: String) {
        guard !string.isEmpty else { return }
        guard link == nil else {
            pending.append(piece(string, link: link))
            return
        }
        // Bare URLs become links, as they do in the editor.
        let ns = string as NSString
        var location = 0
        for url in LinkResolver.bareURLs(in: string) {
            if url.location > location {
                pending.append(piece(ns.substring(with: NSRange(location: location, length: url.location - location)), link: nil))
            }
            let urlString = ns.substring(with: url)
            pending.append(piece(urlString, link: URL(string: urlString)))
            location = NSMaxRange(url)
        }
        if location < ns.length {
            pending.append(piece(ns.substring(from: location), link: nil))
        }
    }

    private func piece(_ string: String, link: URL?) -> AttributedString {
        var piece = AttributedString(string)
        if !intent.isEmpty { piece.inlinePresentationIntent = intent }
        if let link { piece.link = link }
        return piece
    }

    private static func url(_ destination: String) -> URL? {
        URL(string: destination)
            ?? destination.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0) }
    }
}
