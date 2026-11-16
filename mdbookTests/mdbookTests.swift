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

    @Test("Inline styles become presentation intents")
    func inlineStyles() {
        let blocks = MarkdownBlockParser.parse("**b** *i* ~~s~~ `c` [l][r] https://x.org\n\n[r]: ref.md")
        guard case .paragraph(let segments) = blocks.first, case .text(let text) = segments[0] else { Issue.record("expected paragraph"); return }
        func intent(of needle: String) -> InlinePresentationIntent? {
            text.runs.first { String(text[$0.range].characters) == needle }?.inlinePresentationIntent
        }
        #expect(intent(of: "b") == .stronglyEmphasized)
        #expect(intent(of: "i") == .emphasized)
        #expect(intent(of: "s") == .strikethrough)
        #expect(intent(of: "c") == .code)
        #expect(text.runs.compactMap(\.link).map(\.absoluteString) == ["ref.md", "https://x.org"])
    }

    @Test("Ordered lists keep their start number and images inside links still render")
    func listStartAndLinkedImages() {
        let blocks = MarkdownBlockParser.parse("3. three\n4. four\n\n[![badge](b.svg)](https://ci)")
        guard case .list(true, let items) = blocks.first else { Issue.record("expected list"); return }
        #expect(items.map(\.ordinal) == [3, 4])
        guard case .paragraph(let segments) = blocks.last else { Issue.record("expected paragraph"); return }
        #expect(segments.contains(.image(source: "b.svg", alt: "badge")))
    }

    @Test("Indented code and HTML blocks")
    func indentedCodeAndHTML() {
        let blocks = MarkdownBlockParser.parse("    let x = 1\n\n<div>hi</div>\n")
        #expect(blocks.first == .codeBlock(language: nil, code: "let x = 1"))
        #expect(blocks.last == .codeBlock(language: "html", code: "<div>hi</div>"))
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

    @Test("Emphasis can wrap code spans and links")
    func compoundStyles() {
        let text = "**Supersedes `notes.md` point #11** and *see [docs](d.md)*"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.bold == [range(of: "Supersedes `notes.md` point #11", in: text)])
        #expect(spans.inlineCode == [range(of: "notes.md", in: text)])
        #expect(spans.italic == [range(of: "see [docs](d.md)", in: text)])
        #expect(spans.links.count == 1)
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
        // An ordered list must start at 1 to interrupt the item's paragraph and nest.
        let text = "- [ ] task\n  1. nested\n> quote"
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

    @Test("Ranges stay correct after multi-byte characters")
    func unicodeOffsets() {
        let text = "é 😀 **bold** 中文 `code`\n## 👋 Hi"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.bold == [range(of: "bold", in: text)])
        #expect(spans.inlineCode == [range(of: "code", in: text)])
        #expect(spans.headings.first?.content == range(of: "👋 Hi", in: text))
    }

    @Test("Inline ranges on continuation lines are re-based on the line's own content")
    func continuationLines() {
        let samples = [
            "- [ ] task\n  more *em* here",
            "1) x\n\t*em* lazy",
            "> > q\n> lazy *em*\nlazier *em2*",
            "para\n      deep *em*",
        ]
        for text in samples {
            let spans = MarkdownHighlighter.scan(text)
            let ns = text as NSString
            #expect(!spans.italic.isEmpty, "\(text.debugDescription)")
            for italic in spans.italic {
                #expect(ns.substring(with: italic).hasPrefix("em"), "\(text.debugDescription)")
            }
            for marker in spans.markers where marker.length == 1 && ns.substring(with: marker) != "-" {
                #expect(ns.substring(with: marker) == "*", "\(text.debugDescription)")
            }
        }
    }

    @Test("Reference links resolve their destination")
    func referenceLinks() {
        let text = "See [the docs][ref] and [ref].\n\n[ref]: https://example.com"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.links.count == 2)
        #expect(spans.links[0].text == range(of: "the docs", in: text))
        #expect(spans.links.allSatisfy { $0.destination == "https://example.com" })
        #expect(spans.markers.contains(range(of: "][ref]", in: text)))
    }

    @Test("Indented code blocks are code without fences")
    func indentedCode() {
        let text = "para\n\n    let x = **1**\n\nafter"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.codeBlocks.count == 1)
        #expect(spans.codeBlocks[0].fenceLines.isEmpty)
        #expect(spans.codeBlocks[0].range == range(of: "    let x = **1**", in: text))
        #expect(spans.bold.isEmpty)
    }

    @Test("Fenced code blocks report their language")
    func codeLanguage() {
        let spans = MarkdownHighlighter.scan("```rust title\nfn x() {}\n```")
        #expect(spans.codeBlocks.first?.language == "rust")
    }

    @Test("HTML blocks and inline tags are dimmed, not parsed")
    func html() {
        let text = "<div>\n**raw**\n</div>\n\na <kbd>K</kbd> b"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.html.contains(range(of: "<div>\n**raw**\n</div>", in: text)))
        #expect(spans.html.contains(range(of: "<kbd>", in: text)))
        #expect(spans.bold.isEmpty)
    }

    @Test("Nested emphasis hides every delimiter")
    func nestedEmphasis() {
        let text = "***both*** and **bold *inner* bold**"
        let spans = MarkdownHighlighter.scan(text)
        let ns = text as NSString
        #expect(spans.bold.contains(range(of: "both", in: text)))
        #expect(spans.italic.contains(range(of: "inner", in: text)))
        #expect(spans.italic.count == 2)
        let hidden = spans.markers.map { ns.substring(with: $0) }.joined()
        #expect(hidden == String(repeating: "*", count: 12))
    }

    @Test("Setext headings spanning two lines")
    func multilineSetext() {
        let text = "First\nsecond\n===\nbody"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.headings.count == 1)
        #expect(spans.headings[0].level == 1)
        #expect(spans.headings[0].line == range(of: "First\nsecond", in: text))
        #expect(spans.markers == [range(of: "===", in: text)])
    }

    @Test("Tables that interrupt a paragraph, and escaped pipes in cells")
    func tableQuirks() {
        let text = "intro **x**\n| **a** | b |\n|---|---|\n| `\\|\\|` and *c* | 2 |"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.tables.first?.headerLine == range(of: "| **a** | b |", in: text))
        #expect(spans.bold.contains(range(of: "a", in: text)))
        #expect(spans.inlineCode == [range(of: "\\|\\|", in: text)])
        #expect(spans.italic == [range(of: "c", in: text)])
    }

    @Test("Empty documents and CRLF line endings")
    func lineEndings() {
        #expect(MarkdownHighlighter.scan("").headings.isEmpty)
        let text = "# A\r\n\r\n**b**\r\n"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.headings.first?.content == range(of: "A", in: text))
        #expect(spans.bold == [range(of: "b", in: text)])
    }
}

@Suite("Markdown source map")
struct MarkdownSourceMapTests {
    @Test("UTF-8 byte columns map to UTF-16 offsets")
    func columns() {
        let map = MarkdownSourceMap("a😀b\né\n")
        #expect(map.lineCount == 3)
        #expect(map.offset(line: 1, column: 2) == 1) // 😀
        #expect(map.offset(line: 1, column: 6) == 3) // b, after a 4-byte / 2-unit emoji
        #expect(map.offset(line: 2, column: 3) == 6) // end of "é"
        #expect(map.offset(line: 2, column: 99) == 6) // clamped to the line
        #expect(map.offset(line: 9, column: 1) == 7) // past the end
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

// MARK: - Table formatting

@Suite("Table formatter")
struct MarkdownTableFormatterTests {
    @Test("Columns are padded and aligned")
    func aligns() {
        let source = "| Name | Value |\n|:--|--:|\n| alpha | 1 |\n| b | 22 |"
        let expected = """
        | Name  | Value |
        | :---- | ----: |
        | alpha |     1 |
        | b     |    22 |
        """
        #expect(MarkdownTableFormatter.format(source) == expected)
    }

    @Test("Formatting is idempotent and keeps indentation")
    func idempotent() {
        let once = MarkdownTableFormatter.format("  | a | b |\n  |---|---|\n  | 1 | 2 |")
        #expect(once.hasPrefix("  | a"))
        #expect(MarkdownTableFormatter.format(once) == once)
    }

    @Test("Escaped pipes and pipes in code don't split cells")
    func protectedPipes() {
        #expect(MarkdownTableFormatter.cells(in: "| `a|b` | c \\| d |") == ["`a|b`", "c \\| d"])
        #expect(MarkdownTableFormatter.cells(in: "no | outer | pipes") == ["no", "outer", "pipes"])
    }

    @Test("Missing cells are filled and centre alignment is preserved")
    func missingCells() {
        let formatted = MarkdownTableFormatter.format("| a | b | c |\n|:-:|---|---|\n| 1 |")
        #expect(formatted == "|  a  | b   | c   |\n| :-: | --- | --- |\n|  1  |     |     |")
    }
}

@Suite("Table spans")
struct TableSpanTests {
    @Test("Tables report their lines and pipes")
    func tableSpans() {
        let text = "intro\n| a | b |\n|---|---|\n| `x|y` | 2 |\n\nafter"
        let spans = MarkdownHighlighter.scan(text)
        #expect(spans.tables.count == 1)
        let table = spans.tables[0]
        #expect(table.lines.count == 3)
        #expect(table.pipes.count == 9)
        #expect((text as NSString).substring(with: table.range).hasSuffix("| 2 |"))
    }
}

// MARK: - Table column sizing

@Suite("Table column sizer")
struct TableColumnSizerTests {
    @Test("Tables that fit keep their natural widths")
    func fits() {
        #expect(TableColumnSizer.widths(natural: [50, 100], minimum: [50, 40], available: 400) == [50, 100])
    }

    @Test("Narrow columns stay whole; wide ones share the rest by natural width")
    func shares() {
        let widths = TableColumnSizer.widths(natural: [60, 900, 400], minimum: [60, 80, 80], available: 660)
        #expect(widths[0] == 60)
        #expect(abs(widths.reduce(0, +) - 660) < 0.001)
        #expect(abs(widths[1] / widths[2] - 2.25) < 0.001)
    }

    @Test("A column never goes below its longest word while others can give way")
    func minimums() {
        let widths = TableColumnSizer.widths(natural: [400, 1000], minimum: [300, 60], available: 500)
        #expect(widths[0] == 300)
        #expect(widths[1] == 200)
    }

    @Test("Unbreakable runs split at whitespace and after hyphens and slashes")
    func unbreakableRuns() {
        let text = "grammar-script-notes.md (var/const) plain"
        let runs = TableColumnSizer.unbreakableRuns(in: text).map { (text as NSString).substring(with: $0) }
        #expect(runs == ["grammar-", "script-", "notes.md", "(var/", "const)", "plain"])
    }

    @Test("If even the minimums overflow, they scale down to fit but not below the floor")
    func overflow() {
        let widths = TableColumnSizer.widths(natural: [300, 300], minimum: [200, 200], available: 200)
        #expect(widths == [100, 100])
        #expect(TableColumnSizer.widths(natural: [300, 300], minimum: [200, 200], available: 20) == [40, 40])
    }
}

// MARK: - Book summary

@Suite("Book summary")
struct BookSummaryTests {
    let summaryURL = URL(fileURLWithPath: "/book/src/SUMMARY.md")

    @Test("Prefix, numbered, nested, draft, separator, part and suffix chapters")
    func parse() {
        let source = """
        # Summary

        [Introduction](README.md)

        - [Getting started](start/index.md)
            - [Install](start/install.md)
        - [Coming soon]()

        ---

        # Reference

        1. [Syntax](ref/syntax.md)

        [Appendix](appendix.md)
        """
        let summary = BookSummary.parse(source, relativeTo: summaryURL)
        #expect(summary.parts.map(\.title) == [nil, "Reference"]) // the separator before a part title adds no empty part
        #expect(summary.parts[0].entries.map(\.title) == ["Introduction", "Getting started", "Coming soon"])
        #expect(summary.parts[0].entries[1].children.map(\.title) == ["Install"])
        #expect(summary.parts[0].entries[2].url == nil)
        #expect(summary.readingOrder.map(\.path) == [
            "/book/src/README.md", "/book/src/start/index.md", "/book/src/start/install.md",
            "/book/src/ref/syntax.md", "/book/src/appendix.md",
        ])
        #expect(summary.title(for: URL(fileURLWithPath: "/book/src/start/install.md")) == "Install")
    }

    @Test("book.toml's src folder")
    func sourceFolder() {
        #expect(BookSummary.sourceFolder(inBookTOML: "[book]\ntitle = \"x\"\nsrc = \"chapters\"\n") == "chapters")
        #expect(BookSummary.sourceFolder(inBookTOML: "[build]\nsrc = \"no\"\n") == nil)
    }

    @Test("The summary is found in the source folder")
    func locate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let chapters = root.appendingPathComponent("chapters")
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        #expect(BookSummary.locate(in: root) == nil)
        try "[book]\nsrc = \"chapters\"\n".write(to: root.appendingPathComponent("book.toml"), atomically: true, encoding: .utf8)
        try "# Summary\n".write(to: chapters.appendingPathComponent("SUMMARY.md"), atomically: true, encoding: .utf8)
        #expect(BookSummary.locate(in: root)?.lastPathComponent == "SUMMARY.md")
        #expect(BookSummary.locate(in: root)?.deletingLastPathComponent().lastPathComponent == "chapters")
    }
}

// MARK: - Code highlighting

@Suite("Code highlighter")
struct CodeHighlighterTests {
    private func kinds(_ code: String, language: String?) -> [(CodeToken.Kind, String)] {
        let ns = code as NSString
        return CodeHighlighter.tokens(in: code, language: language).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    @Test("Swift keywords, strings, comments, numbers, types and attributes")
    func swift() {
        let code = "// note\n@MainActor func go(_ n: Int) -> String { return \"hi \\\"there\\\"\" + String(42) }"
        let tokens = kinds(code, language: "swift")
        #expect(tokens.contains { $0 == (.comment, "// note") })
        #expect(tokens.contains { $0 == (.attribute, "@MainActor") })
        #expect(tokens.contains { $0 == (.keyword, "func") })
        #expect(tokens.contains { $0 == (.type, "Int") })
        #expect(tokens.contains { $0 == (.string, "\"hi \\\"there\\\"\"") })
        #expect(tokens.contains { $0 == (.number, "42") })
    }

    @Test("Block comments and template strings span lines")
    func multiline() {
        let tokens = kinds("/* a\nb */ const s = `x\ny`;", language: "js")
        #expect(tokens.first?.0 == .comment)
        #expect(tokens.first?.1 == "/* a\nb */")
        #expect(tokens.contains { $0 == (.string, "`x\ny`") })
    }

    @Test("Python uses hash comments and highlights decorators")
    func python() {
        let tokens = kinds("@dataclass\nclass Foo:  # comment\n    x = 1.5", language: "python")
        #expect(tokens.contains { $0 == (.attribute, "@dataclass") })
        #expect(tokens.contains { $0 == (.keyword, "class") })
        #expect(tokens.contains { $0 == (.comment, "# comment") })
        #expect(tokens.contains { $0 == (.number, "1.5") })
    }

    @Test("YAML and JSON keys are properties")
    func keys() {
        #expect(kinds("name: mdbook\nversion: 2", language: "yaml").contains { $0 == (.property, "name") })
        #expect(kinds("{\"key\": \"value\"}", language: "json").contains { $0 == (.property, "\"key\"") })
        #expect(kinds("{\"key\": \"value\"}", language: "json").contains { $0 == (.string, "\"value\"") })
    }

    @Test("Markup highlights tags, attributes and values")
    func html() {
        let tokens = kinds("<a href=\"x\">hi</a><!-- c -->", language: "html")
        #expect(tokens.contains { $0 == (.tag, "<a") })
        #expect(tokens.contains { $0 == (.attribute, "href") })
        #expect(tokens.contains { $0 == (.string, "\"x\"") })
        #expect(tokens.contains { $0 == (.tag, "</a") })
        #expect(tokens.contains { $0 == (.comment, "<!-- c -->") })
    }

    @Test("Unknown languages get generic highlighting")
    func generic() {
        let tokens = kinds("fn main { println(\"hello\") }", language: nil)
        #expect(tokens.contains { $0 == (.keyword, "fn") })
        #expect(tokens.contains { $0 == (.string, "\"hello\"") })
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
