//
//  mdbookTests.swift
//  mdbookTests
//

import Foundation
import Testing
@testable import mdbook

// MARK: - Block parser

@Suite("Markdown block parser")
struct MarkdownBlockParserTests {
    @Test("Headings, paragraphs and thematic breaks")
    func basicBlocks() {
        let blocks = MarkdownBlockParser.parse("# Title\n\nSome *text*.\n\n---\n")
        #expect(blocks.count == 3)
        guard case .heading(let level, let content) = blocks[0] else { Issue.record("expected heading"); return }
        #expect(level == 1)
        #expect(String(content.characters) == "Title")
        guard case .paragraph(let segments) = blocks[1], case .text(let text) = segments[0] else { Issue.record("expected paragraph"); return }
        #expect(String(text.characters) == "Some text.")
        #expect(blocks[2] == .thematicBreak)
    }

    @Test("GFM task lists are detected and stripped")
    func taskLists() {
        let blocks = MarkdownBlockParser.parse("- [ ] todo\n- [x] done\n- plain\n")
        guard case .list(let ordered, let items) = blocks.first else { Issue.record("expected list"); return }
        #expect(!ordered)
        #expect(items.count == 3)
        #expect(items[0].task == .unchecked)
        #expect(items[1].task == .checked)
        #expect(items[2].task == nil)
        guard case .paragraph(let segments) = items[1].blocks[0], case .text(let text) = segments[0] else { Issue.record("expected paragraph"); return }
        #expect(String(text.characters) == "done")
    }

    @Test("Nested lists keep their structure")
    func nestedLists() {
        let blocks = MarkdownBlockParser.parse("1. one\n2. two\n   - inner\n")
        guard case .list(let ordered, let items) = blocks.first else { Issue.record("expected list"); return }
        #expect(ordered)
        #expect(items.count == 2)
        #expect(items[1].blocks.count == 2)
        guard case .list(let innerOrdered, let inner) = items[1].blocks[1] else { Issue.record("expected nested list"); return }
        #expect(!innerOrdered)
        #expect(inner.count == 1)
    }

    @Test("Tables carry header, rows and alignment")
    func tables() {
        let blocks = MarkdownBlockParser.parse("| Name | Value |\n|:-----|------:|\n| a | 1 |\n| b | 2 |\n")
        guard case .table(let table) = blocks.first else { Issue.record("expected table"); return }
        #expect(table.alignments == [.left, .right])
        #expect(table.header.map { String($0.characters) } == ["Name", "Value"])
        #expect(table.rows.count == 2)
        #expect(table.rows[1].map { String($0.characters) } == ["b", "2"])
    }

    @Test("Fenced code blocks keep their language")
    func codeBlocks() {
        let blocks = MarkdownBlockParser.parse("```swift\nlet x = 1\n```\n")
        #expect(blocks.first == .codeBlock(language: "swift", code: "let x = 1"))
    }

    @Test("Relative links with spaces survive parsing")
    func relativeLinks() {
        let blocks = MarkdownBlockParser.parse("See [chapter](my chapter.md) and [other](other.md).")
        guard case .paragraph(let segments) = blocks.first, case .text(let text) = segments[0] else { Issue.record("expected paragraph"); return }
        let links = text.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["my%20chapter.md", "other.md"])
    }

    @Test("Images become image segments")
    func images() {
        let blocks = MarkdownBlockParser.parse("![Logo](img/logo.png)")
        guard case .paragraph(let segments) = blocks.first else { Issue.record("expected paragraph"); return }
        #expect(segments.contains(.image(source: "img/logo.png", alt: "Logo")))
    }

    @Test("Block quotes contain nested blocks")
    func blockQuotes() {
        let blocks = MarkdownBlockParser.parse("> quoted\n>\n> - item\n")
        guard case .blockQuote(let children) = blocks.first else { Issue.record("expected quote"); return }
        #expect(children.count == 2)
    }
}

// MARK: - Highlighter

@Suite("Markdown highlighter")
struct MarkdownHighlighterTests {
    private func range(of needle: String, in haystack: String) -> NSRange {
        (haystack as NSString).range(of: needle)
    }

    @Test("ATX headings")
    func headings() {
        let text = "## Hello\nbody"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.headings.count == 1)
        #expect(spans.headings[0].level == 2)
        #expect(spans.headings[0].content == range(of: "Hello", in: text))
        #expect(spans.markers.contains(range(of: "## ", in: text)))
    }

    @Test("Setext headings turn --- into an underline, not a rule")
    func setextHeadings() {
        let spans = MarkdownHighlighter.scan("Title\n---\n\n---\n")
        #expect(spans.headings.count == 1)
        #expect(spans.headings[0].level == 2)
        #expect(spans.thematicBreaks.count == 1)
    }

    @Test("Inline emphasis and markers")
    func emphasis() {
        let text = "a **bold** and *em* and ~~gone~~ and `code`"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.bold == [range(of: "bold", in: text)])
        #expect(spans.italic == [range(of: "em", in: text)])
        #expect(spans.strikethrough == [range(of: "gone", in: text)])
        #expect(spans.inlineCode == [range(of: "code", in: text)])
        // Two markers per construct.
        #expect(spans.markers.count == 8)
    }

    @Test("Emphasis inside code spans is ignored")
    func codeProtectsContents() {
        let spans = MarkdownHighlighter.scan("use `**not bold**` here")
        #expect(spans.bold.isEmpty)
        #expect(spans.inlineCode.count == 1)
    }

    @Test("Links and images")
    func links() {
        let text = "[Next](chapter2.md) ![pic](a.png) <https://x.org> https://y.org/path"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.links.count == 4)
        #expect(spans.links[0].destination == "chapter2.md")
        #expect(spans.links[0].text == range(of: "Next", in: text))
        #expect(spans.links[1].isImage)
        #expect(spans.links[2].destination == "https://x.org")
        #expect(spans.links[3].destination == "https://y.org/path")
    }

    @Test("Fenced code blocks swallow markdown inside them")
    func codeBlocks() {
        let text = "before\n```js\n# not a heading\n**nope**\n```\nafter **yes**"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.codeBlocks.count == 1)
        #expect(spans.codeBlocks[0].fenceLines.count == 2)
        #expect(spans.headings.isEmpty)
        #expect(spans.bold == [range(of: "yes", in: text)])
    }

    @Test("List items, tasks and block quotes")
    func listsAndQuotes() {
        let text = "- [ ] task\n  2. nested\n> quote"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.listItems.count == 2)
        #expect(spans.listItems[0].task == range(of: "[ ]", in: text))
        #expect(!spans.listItems[0].ordered)
        #expect(spans.listItems[1].ordered)
        #expect(spans.listItems[1].indent == 2)
        #expect(spans.blockQuotes.count == 1)
        #expect(spans.blockQuotes[0].marker == range(of: "> ", in: text))
    }

    @Test("Tables are recognised from their delimiter row")
    func tables() {
        let spans = MarkdownHighlighter.scan("| a | b |\n|---|---|\n| 1 | 2 |\n\nnot | table")
        #expect(spans.tableLines.count == 3)
    }
}

// MARK: - Link resolution

@Suite("Link resolver")
struct LinkResolverTests {
    let document = URL(fileURLWithPath: "/book/chapters/one.md")

    @Test("Relative paths resolve against the document folder")
    func relative() {
        #expect(LinkResolver.resolve("two.md", relativeTo: document) == .file(URL(fileURLWithPath: "/book/chapters/two.md"), fragment: nil))
        #expect(LinkResolver.resolve("../README.md#intro", relativeTo: document) == .file(URL(fileURLWithPath: "/book/README.md"), fragment: "intro"))
        #expect(LinkResolver.resolve("my%20file.md", relativeTo: document) == .file(URL(fileURLWithPath: "/book/chapters/my file.md"), fragment: nil))
    }

    @Test("External and anchor links")
    func externalAndAnchors() {
        #expect(LinkResolver.resolve("https://example.com/a", relativeTo: document) == .external(URL(string: "https://example.com/a")!))
        #expect(LinkResolver.resolve("mailto:a@b.c", relativeTo: document) == .external(URL(string: "mailto:a@b.c")!))
        #expect(LinkResolver.resolve("#section", relativeTo: document) == .anchor("section"))
        #expect(LinkResolver.resolve("   ", relativeTo: document) == .invalid)
    }

    @Test("Spaces in destinations are percent-encoded")
    func encoding() {
        let encoded = LinkResolver.encodingSpacesInLinkDestinations("[a](my file.md) and [b](ok.md) and [c](x.md \"title here\")")
        #expect(encoded == "[a](my%20file.md) and [b](ok.md) and [c](x.md \"title here\")")
    }
}

// MARK: - Heading anchors

@Suite("Heading slugs")
struct HeadingSlugTests {
    @Test("Slugs follow GitHub's rules")
    func slugs() {
        #expect(HeadingSlug.slug(for: "Hello, World!") == "hello-world")
        #expect(HeadingSlug.slug(for: "Status: design, not implementation") == "status-design-not-implementation")
        #expect(HeadingSlug.slug(for: "snake_case and-dashes") == "snake_case-and-dashes")
    }

    @Test("Inline markdown is stripped before slugging")
    func plainText() {
        #expect(HeadingSlug.plainText(ofHeadingSource: "Using `code` and **bold** ##") == "Using code and bold")
        #expect(HeadingSlug.plainText(ofHeadingSource: "See [the docs](docs.md)") == "See the docs")
    }

    @Test("Anchors match headings loosely")
    func matching() {
        #expect(HeadingSlug.matches(anchor: "#hello-world", headingText: "Hello World"))
        #expect(HeadingSlug.matches(anchor: "Hello%20World", headingText: "Hello World"))
        #expect(!HeadingSlug.matches(anchor: "other", headingText: "Hello World"))
    }
}

// MARK: - File tree

@Suite("File tree")
struct FileNodeTests {
    @Test("Only markdown files and folders that contain them are listed")
    func buildTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mdbook-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("docs")
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try "# A".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
        try "# B".write(to: docs.appendingPathComponent("b.markdown"), atomically: true, encoding: .utf8)

        let tree = FileNode.buildTree(at: root)
        #expect(tree.map(\.name) == ["docs", "README.md"])
        #expect(tree[0].children?.map(\.name) == ["b.markdown"])

        let nested = try #require(tree[0].children?.first)
        #expect(FileNode.ancestorFolders(of: nested.url, in: tree) == [tree[0].url])
    }
}
