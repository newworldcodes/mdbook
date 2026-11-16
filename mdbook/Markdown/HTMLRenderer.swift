//
//  HTMLRenderer.swift
//  mdbook
//
//  Renders markdown to HTML from the swift-markdown tree. The output is XHTML-compatible
//  (void elements self-closed, everything escaped) so the same markup works for HTML
//  export, the attributed-string conversion behind PDF/printing/rich-text copy, and EPUB.
//

import Foundation
import Markdown

nonisolated struct HTMLRenderer {
    /// Turns an image destination into the `src` to emit (e.g. a data URI).
    var imageSource: (String) -> String = { $0 }
    /// Turns a link destination into the `href` to emit (e.g. a chapter's in-book anchor).
    var linkTarget: (String) -> String = { $0 }
    /// Prefixed to every heading id, so ids stay unique when chapters share a page.
    var idPrefix = ""

    /// Code colours (Xcode's light theme), inlined so they survive every consumer.
    static let codeColors: [CodeToken.Kind: String] = [
        .keyword: "#ad3da4", .string: "#c41a16", .comment: "#5d6c79", .number: "#1c00cf",
        .type: "#0b4f79", .attribute: "#643820", .tag: "#881280", .property: "#3e8087",
    ]

    func render(_ markdown: String) -> String {
        let prepared = MarkdownExtensions.prepare(markdown)
        let document = Document(parsing: LinkResolver.encodingSpacesInLinkDestinations(prepared.markdown), options: [.disableSmartOpts])
        var output = ""
        var slugs: [String: Int] = [:]
        for block in document.children {
            renderBlock(block, into: &output, slugs: &slugs)
        }
        if !prepared.footnotes.isEmpty {
            output += "<section class=\"footnotes\">\n<hr/>\n<ol>\n"
            for note in prepared.footnotes {
                let backlink = "<a class=\"footnote-back\" href=\"#\(idPrefix)fnref-\(note.number)\">↩</a>"
                var body = render(note.markdown).trimmingCharacters(in: .whitespacesAndNewlines)
                if body.hasSuffix("</p>") {
                    body = String(body.dropLast(4)) + " \(backlink)</p>"
                } else {
                    body += backlink
                }
                output += "<li id=\"\(idPrefix)fn-\(note.number)\">\(body)</li>\n"
            }
            output += "</ol>\n</section>\n"
        }
        return output
    }

    // MARK: Blocks

    private func renderBlock(_ markup: Markup, into out: inout String, slugs: inout [String: Int]) {
        switch markup {
        case let heading as Heading:
            let level = min(max(heading.level, 1), 6)
            // GitHub-style ids, de-duplicated with -1, -2… as the preview does.
            let base = HeadingSlug.slug(for: heading.plainText)
            let count = slugs[base, default: 0]
            slugs[base] = count + 1
            let id = idPrefix + (count == 0 ? base : "\(base)-\(count)")
            out += "<h\(level) id=\"\(Self.escape(id))\">\(childrenHTML(heading))</h\(level)>\n"
        case let paragraph as Paragraph:
            out += "<p>\(childrenHTML(paragraph))</p>\n"
        case let code as CodeBlock:
            out += codeBlock(code)
        case let html as HTMLBlock:
            out += html.rawHTML
        case let quote as BlockQuote:
            out += "<blockquote>\n"
            for child in quote.children { renderBlock(child, into: &out, slugs: &slugs) }
            out += "</blockquote>\n"
        case let list as OrderedList:
            let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
            out += "<ol\(start)>\n"
            for item in list.listItems { renderItem(item, into: &out, slugs: &slugs) }
            out += "</ol>\n"
        case let list as UnorderedList:
            let isTaskList = list.listItems.contains { $0.checkbox != nil }
            out += isTaskList ? "<ul class=\"tasks\">\n" : "<ul>\n"
            for item in list.listItems { renderItem(item, into: &out, slugs: &slugs) }
            out += "</ul>\n"
        case let table as Markdown.Table:
            out += self.table(table)
        case is ThematicBreak:
            out += "<hr/>\n"
        default:
            for child in markup.children { renderBlock(child, into: &out, slugs: &slugs) }
        }
    }

    private func renderItem(_ item: ListItem, into out: inout String, slugs: inout [String: Int]) {
        out += "<li>"
        if let checkbox = item.checkbox {
            out += checkbox == .checked
                ? "<input type=\"checkbox\" disabled=\"disabled\" checked=\"checked\"/> "
                : "<input type=\"checkbox\" disabled=\"disabled\"/> "
        }
        // A single paragraph reads better without <p> margins (tight lists).
        if item.childCount == 1, let paragraph = item.child(at: 0) as? Paragraph {
            out += childrenHTML(paragraph)
        } else {
            out += "\n"
            for child in item.children { renderBlock(child, into: &out, slugs: &slugs) }
        }
        out += "</li>\n"
    }

    private func codeBlock(_ code: CodeBlock) -> String {
        var source = code.code
        if source.hasSuffix("\n") { source.removeLast() }
        let language = code.language?.split(whereSeparator: \.isWhitespace).first.map(String.init)
        if language == "math" {
            return "<div class=\"math\">\(Self.escape(MathText.unicode(fromTeX: source)))</div>\n"
        }
        let ns = source as NSString
        var html = ""
        var location = 0
        for token in CodeHighlighter.tokens(in: source, language: language) where token.range.location >= location {
            html += Self.escape(ns.substring(with: NSRange(location: location, length: token.range.location - location)))
            let text = Self.escape(ns.substring(with: token.range))
            if let color = Self.codeColors[token.kind] {
                html += "<span style=\"color:\(color)\">\(text)</span>"
            } else {
                html += text
            }
            location = NSMaxRange(token.range)
        }
        html += Self.escape(ns.substring(from: min(location, ns.length)))
        let languageClass = language.map { " class=\"language-\(Self.escape($0))\"" } ?? ""
        return "<pre><code\(languageClass)>\(html)</code></pre>\n"
    }

    private func table(_ table: Markdown.Table) -> String {
        let alignments = table.columnAlignments
        func cell(_ cell: Markdown.Table.Cell, tag: String, column: Int) -> String {
            var style = ""
            if column < alignments.count, let alignment = alignments[column] {
                switch alignment {
                case .left: style = " style=\"text-align:left\""
                case .center: style = " style=\"text-align:center\""
                case .right: style = " style=\"text-align:right\""
                }
            }
            return "<\(tag)\(style)>\(childrenHTML(cell))</\(tag)>"
        }
        var html = "<table>\n<thead><tr>"
        for (column, headCell) in table.head.cells.enumerated() { html += cell(headCell, tag: "th", column: column) }
        html += "</tr></thead>\n<tbody>\n"
        for row in table.body.rows {
            html += "<tr>"
            for (column, bodyCell) in row.cells.enumerated() { html += cell(bodyCell, tag: "td", column: column) }
            html += "</tr>\n"
        }
        return html + "</tbody>\n</table>\n"
    }

    // MARK: Inlines

    private func inline(_ markup: Markup) -> String {
        switch markup {
        case let text as Markdown.Text:
            return MarkdownExtensions.segments(in: text.string).map { segment in
                switch segment {
                case .text(let plain):
                    return autolinked(MarkdownExtensions.replacingEmojiShortcodes(in: plain))
                case .footnoteReference(let number):
                    return "<sup class=\"footnote-ref\" id=\"\(idPrefix)fnref-\(number)\"><a href=\"#\(idPrefix)fn-\(number)\">\(number)</a></sup>"
                case .math(let tex):
                    return "<span class=\"math\">\(Self.escape(MathText.unicode(fromTeX: tex)))</span>"
                }
            }.joined()
        case is SoftBreak:
            return "\n"
        case is LineBreak:
            return "<br/>\n"
        case let code as InlineCode:
            return "<code>\(Self.escape(code.code))</code>"
        case let html as InlineHTML:
            return html.rawHTML
        case is Emphasis:
            return "<em>\(childrenHTML(markup))</em>"
        case let strong as Strong:
            return "<strong>\(childrenHTML(strong))</strong>"
        case let strike as Strikethrough:
            return "<del>\(childrenHTML(strike))</del>"
        case let link as Link:
            let href = Self.escape(linkTarget(link.destination ?? ""))
            return "<a href=\"\(href)\">\(childrenHTML(link))</a>"
        case let image as Image:
            let src = Self.escape(imageSource(image.source ?? ""))
            return "<img src=\"\(src)\" alt=\"\(Self.escape(image.plainText))\"/>"
        default:
            return childrenHTML(markup)
        }
    }

    private func childrenHTML(_ markup: Markup) -> String {
        markup.children.map(inline).joined()
    }

    /// Escapes text and turns bare URLs into links (swift-markdown has no autolink extension).
    private func autolinked(_ string: String) -> String {
        let ns = string as NSString
        var html = ""
        var location = 0
        for url in LinkResolver.bareURLs(in: string) {
            html += Self.escape(ns.substring(with: NSRange(location: location, length: url.location - location)))
            let target = ns.substring(with: url)
            html += "<a href=\"\(Self.escape(target))\">\(Self.escape(target))</a>"
            location = NSMaxRange(url)
        }
        return html + Self.escape(ns.substring(from: location))
    }

    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for character in string {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }
}
