//
//  IncrementalStylingTests.swift
//  mdbookTests
//
//  Restyling after an edit must give exactly what a full restyle gives, whether it runs
//  synchronously (medium documents) or via a background rescan (large ones).
//

import AppKit
import SwiftUI
import Testing
@testable import mdbook

@MainActor
@Suite("Incremental styling", .serialized)
struct IncrementalStylingTests {
    /// A chapter exercising every construct the styler handles.
    static let chapter = """
    # Chapter

    Intro with **bold**, *em*, `code`, [a link](x.md), $a_1 b_2$ and a note[^n].

    ## Section

    - item one
    - [ ] task
      1. nested

    > quoted *text*

    ```swift
    let x = 1
    ```

    | A | B |
    |---|---|
    | 1 | **2** |

    ---

    [^n]: The note.


    """

    private func find(_ view: NSView) -> MarkdownTextView? {
        (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first
    }

    /// The styler's attributes as comparable strings (hidden glyphs' colour isn't drawn).
    private func signature(_ storage: NSTextStorage) -> [String] {
        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .markdownHidden, .markdownMarker, .link, .markdownCodeBlock, .markdownBlockRendering, .strikethroughStyle, .baselineOffset]
        var runs: [String] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let hidden = attributes[.markdownHidden] != nil
            let parts = keys.map { key -> String in
                if hidden, key == .foregroundColor { return "hidden" }
                guard let value = attributes[key] else { return "-" }
                if let font = value as? NSFont { return "\(font.fontName)/\(font.pointSize)" }
                if value is MarkdownBlockRendering { return "R" }
                return "\(value)"
            }
            let style = (attributes[.paragraphStyle] as? NSParagraphStyle).map { "\($0.headIndent)/\($0.paragraphSpacing)" } ?? "-"
            runs.append("\(range.location)+\(range.length) \(parts.joined(separator: "|")) \(style)")
        }
        return runs
    }

    private func checkEdits(copies: Int, settle: Duration) async throws {
        let text = String(repeating: Self.chapter, count: copies)
        let host = NSHostingView(rootView: MarkdownEditorView(text: .constant(text), mode: .wysiwyg, onOpenLink: { _ in }).frame(width: 700, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        let textView = try #require(find(host))
        let storage = try #require(textView.textStorage)
        let coordinator = try #require(textView.delegate as? MarkdownEditorView.Coordinator)
        // Edit the middle copy, so there's styled text on both sides.
        let middle = (text as NSString).length / 2
        func at(_ needle: String) -> Int {
            let ns = textView.string as NSString
            return ns.range(of: needle, range: NSRange(location: middle, length: ns.length - middle)).location
        }
        func type(_ string: String, at location: Int, replacing length: Int = 0) {
            textView.setSelectedRange(NSRange(location: location, length: length))
            textView.insertText(string, replacementRange: textView.selectedRange())
        }
        let edits: [(String, () -> Void)] = [
            ("type in a paragraph", { type("xyz", at: at("Intro") + 2) }),
            ("open bold", { type("**", at: at("with")) }),
            ("open a fence", { type("```\n", at: at("## Section")) }),
            ("close it again", { type("", at: at("```\n## Section"), replacing: 4) }),
            ("edit a table cell", { type("!", at: at("| 1 |") + 2) }),
            ("remove a heading marker", { type("", at: at("## Section"), replacing: 3) }),
            ("add math", { type("$x^2$ ", at: at("Intro")) }),
        ]
        for (name, edit) in edits {
            edit()
            try await Task.sleep(for: settle)
            let incremental = signature(storage)
            coordinator.restyleEverything()
            let full = signature(storage)
            #expect(zip(incremental, full).first { $0 != $1 } == nil, "\(name)")
            #expect(incremental.count == full.count, "\(name)")
        }
    }

    @Test("Medium documents restyle only what changed, synchronously")
    func synchronous() async throws {
        try await checkEdits(copies: 150, settle: .milliseconds(50)) // ~40K characters
    }

    @Test("Large documents restyle the edit at once and the rest after a background scan")
    func background() async throws {
        try await checkEdits(copies: 800, settle: .seconds(1)) // ~220K characters
    }
}
