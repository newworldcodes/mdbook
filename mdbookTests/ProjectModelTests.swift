//
//  ProjectModelTests.swift
//  mdbookTests
//
//  The project model against a real folder: autosave, changes made by other apps,
//  history, new/rename/delete and encodings. Plus the editor coordinator's own behaviour.
//

import AppKit
import SwiftUI
import Testing
@testable import mdbook

/// A temporary book. Opening a project writes to user defaults, which the test host shares
/// with the real app, so those keys are saved here and restored by `close()`.
@MainActor
final class TemporaryBook {
    let root: URL
    let model = ProjectModel()
    private let savedDefaults: [String: Any?]
    private static let defaultsKeys = ["lastProjectBookmark", "editorLayout", "recentProjects"]

    init(files: [String: String]) throws {
        savedDefaults = Dictionary(uniqueKeysWithValues: Self.defaultsKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        model.openProject(at: root)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path).standardizedFileURL }

    func disk(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }

    func close() {
        try? FileManager.default.removeItem(at: root)
        for (key, value) in savedDefaults {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

@MainActor
@Suite("Project model", .serialized)
struct ProjectModelTests {
    @Test("Opening a project selects its README, and history goes back and forward")
    func history() throws {
        let book = try TemporaryBook(files: ["README.md": "# Readme", "a.md": "# A", "b.md": "# B"])
        defer { book.close() }
        let model = book.model
        #expect(model.selection == book.url("README.md"))
        model.navigate(to: book.url("a.md"))
        model.navigate(to: book.url("b.md"))
        #expect(model.text == "# B")
        model.goBack()
        #expect(model.selection == book.url("a.md"))
        model.goBack()
        #expect(model.selection == book.url("README.md"))
        #expect(!model.canGoBack)
        model.goForward()
        #expect(model.selection == book.url("a.md"))
        // Navigating somewhere new drops the forward history.
        model.navigate(to: book.url("b.md"))
        #expect(!model.canGoForward)
    }

    @Test("Edits autosave after a pause")
    func autosave() async throws {
        let book = try TemporaryBook(files: ["README.md": "# Readme"])
        defer { book.close() }
        book.model.updateText("# Readme\n\nNew line.")
        #expect(book.model.isDirty)
        #expect(book.disk("README.md") == "# Readme")
        try await Task.sleep(for: .milliseconds(1400))
        #expect(!book.model.isDirty)
        #expect(book.disk("README.md") == "# Readme\n\nNew line.")
    }

    @Test("A change made by another app is never overwritten without asking")
    func externalChange() throws {
        let book = try TemporaryBook(files: ["README.md": "original"])
        defer { book.close() }
        let model = book.model
        model.updateText("mine")
        try "theirs".write(to: book.url("README.md"), atomically: true, encoding: .utf8)
        model.saveNow()
        #expect(model.externalChange == book.url("README.md"))
        #expect(book.disk("README.md") == "theirs")

        model.resolveExternalChange(keepMine: true)
        #expect(model.externalChange == nil)
        #expect(book.disk("README.md") == "mine")

        model.updateText("mine again")
        try "theirs again".write(to: book.url("README.md"), atomically: true, encoding: .utf8)
        model.saveNow()
        model.resolveExternalChange(keepMine: false)
        #expect(model.text == "theirs again")
        #expect(!model.isDirty)
    }

    @Test("Switching files saves pending edits to the file they belong to")
    func switchSavesToRightFile() throws {
        let book = try TemporaryBook(files: ["README.md": "# Readme", "other.md": "# Other"])
        defer { book.close() }
        book.model.updateText("# Readme, edited")
        book.model.navigate(to: book.url("other.md"))
        #expect(book.disk("README.md") == "# Readme, edited")
        #expect(book.disk("other.md") == "# Other")
        #expect(book.model.text == "# Other")
    }

    @Test("Switching files mid-conflict keeps the edits in a conflicted copy")
    func conflictedCopy() throws {
        let book = try TemporaryBook(files: ["README.md": "original", "other.md": "# Other"])
        defer { book.close() }
        let model = book.model
        model.updateText("my edits")
        try "their edits".write(to: book.url("README.md"), atomically: true, encoding: .utf8)
        model.navigate(to: book.url("other.md"))
        #expect(book.disk("README.md") == "their edits")
        #expect(book.disk("README (conflicted copy).md") == "my edits")
        #expect(model.errorMessage?.contains("conflicted copy") == true)
    }

    @Test("Renaming the open file keeps it selected and keeps history pointing at it")
    func renameFile() throws {
        let book = try TemporaryBook(files: ["README.md": "# Readme", "draft.md": "# Draft"])
        defer { book.close() }
        let model = book.model
        model.navigate(to: book.url("draft.md"))
        let node = try #require(FileNode.find(book.url("draft.md"), in: model.tree))
        model.requestRename(node)
        #expect(model.renameName == "draft")
        model.renameName = "Final"
        model.renamePendingNode()
        #expect(book.disk("draft.md") == nil)
        #expect(book.disk("Final.md") == "# Draft")
        #expect(model.selection == book.url("Final.md"))
        model.goBack()
        model.goForward()
        #expect(model.selection == book.url("Final.md"))
    }

    @Test("Renaming a folder moves the open file's selection with it")
    func renameFolder() throws {
        let book = try TemporaryBook(files: ["README.md": "# Readme", "part/one.md": "# One"])
        defer { book.close() }
        let model = book.model
        model.navigate(to: book.url("part/one.md"))
        let folder = try #require(FileNode.find(book.url("part"), in: model.tree))
        model.requestRename(folder)
        model.renameName = "Part 1"
        model.renamePendingNode()
        #expect(model.selection == book.url("Part 1/one.md"))
        #expect(model.text == "# One")
    }

    @Test("New files get a title heading and open; deleting the open file clears the selection")
    func newAndDelete() throws {
        let book = try TemporaryBook(files: ["README.md": "# Readme"])
        defer { book.close() }
        let model = book.model
        model.requestNewFile(in: book.root)
        model.newFileName = "Fresh Chapter"
        model.createRequestedFile()
        #expect(book.disk("Fresh Chapter.md") == "# Fresh Chapter\n\n")
        #expect(model.selection == book.url("Fresh Chapter.md"))

        model.nodePendingDeletion = FileNode.find(book.url("Fresh Chapter.md"), in: model.tree)
        model.deletePendingNode()
        #expect(book.disk("Fresh Chapter.md") == nil)
        #expect(model.selection == nil)
        #expect(FileNode.find(book.url("Fresh Chapter.md"), in: model.tree) == nil)
    }

    @Test("A Windows-1252 file is edited and saved in its own encoding")
    func legacyEncoding() throws {
        let book = try TemporaryBook(files: ["README.md": "# Readme"])
        defer { book.close() }
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: book.url("old.md"))
        book.model.refreshTree()
        book.model.navigate(to: book.url("old.md"))
        #expect(book.model.text == "café")
        book.model.updateText("café crème")
        book.model.saveNow()
        let bytes = try Data(contentsOf: book.url("old.md"))
        #expect(bytes == Data("café crème".data(using: .windowsCP1252)!))
    }

    @Test("SUMMARY.md sets the reading order and chapter navigation")
    func chapters() throws {
        let book = try TemporaryBook(files: [
            "SUMMARY.md": "# Summary\n\n- [Two](two.md)\n- [One](one.md)\n",
            "one.md": "# One", "two.md": "# Two",
        ])
        defer { book.close() }
        let model = book.model
        #expect(model.readingOrder == [book.url("two.md"), book.url("one.md")])
        #expect(model.selection == book.url("two.md"))
        #expect(model.nextChapter?.title == "One")
        model.goToNextChapter()
        #expect(model.selection == book.url("one.md"))
        #expect(model.nextChapter == nil)
    }
}

@MainActor
@Suite("Editor coordinator", .serialized)
struct EditorCoordinatorTests {
    private func find(_ view: NSView) -> MarkdownTextView? {
        (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first
    }

    /// Hosts an editor in a window and returns its text view and coordinator.
    private func editor(_ text: String) async throws -> (NSWindow, MarkdownTextView, MarkdownEditorView.Coordinator) {
        let host = NSHostingView(rootView: MarkdownEditorView(text: .constant(text), mode: .wysiwyg, onOpenLink: { _ in }).frame(width: 600, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))
        let textView = try #require(find(host))
        let coordinator = try #require(textView.delegate as? MarkdownEditorView.Coordinator)
        return (window, textView, coordinator)
    }

    @Test("Return continues bullets and numbers, and ends the list on an empty item")
    func listContinuation() {
        let (_, textView) = MarkdownTextView.makeScrollable()
        textView.string = "- one"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "- one\n- ")
        textView.insertNewline(nil)
        #expect(textView.string == "- one\n")

        textView.string = "9. nine\n- [x] done"
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string.hasPrefix("9. nine\n10. "))
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string.hasSuffix("- [x] done\n- [ ] "))
    }

    @Test("Return continues block quotes, lists inside them, and ends on an empty line")
    func quoteContinuation() {
        let (_, textView) = MarkdownTextView.makeScrollable()
        func returnAtEnd(_ text: String) -> String {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.insertNewline(nil)
            return textView.string
        }
        #expect(returnAtEnd("> quoted") == "> quoted\n> ")
        #expect(returnAtEnd("> > deeper") == "> > deeper\n> > ")
        #expect(returnAtEnd("> - item") == "> - item\n> - ")
        #expect(returnAtEnd("> 1. one") == "> 1. one\n> 2. ")
        #expect(returnAtEnd("> quoted\n> ") == "> quoted\n")
    }

    @Test("Format ▸ Quote quotes the selected lines, and unquotes them when all are quoted")
    func toggleQuote() {
        let (_, textView) = MarkdownTextView.makeScrollable()
        textView.string = "one\n\ntwo\nafter"
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        textView.toggleQuoteMarkdown(nil)
        #expect(textView.string == "> one\n>\n> two\nafter")
        textView.toggleQuoteMarkdown(nil)
        #expect(textView.string == "one\n\ntwo\nafter")
    }

    @Test("Align Table Columns pads the table at the caret")
    func formatTable() async throws {
        let text = "Intro\n\n| a | bb |\n|-|-|\n| ccc | d |\n"
        let (window, textView, coordinator) = try await editor(text)
        defer { window.close() }
        textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "ccc").location, length: 0))
        coordinator.formatTableAtCaret()
        #expect(textView.string == "Intro\n\n" + MarkdownTableFormatter.format("| a | bb |\n|-|-|\n| ccc | d |") + "\n")
    }

    @Test("Following an anchor puts the caret on the heading")
    func anchors() async throws {
        let text = "# Top\n\nBody\n\n## Second Part\n\nMore"
        let (window, textView, coordinator) = try await editor(text)
        defer { window.close() }
        coordinator.reveal(anchor: AnchorRequest(anchor: "second-part"))
        #expect(textView.selectedRange().location == (text as NSString).range(of: "## Second Part").location)
    }

    @Test("Markers hide away from the caret and show on its paragraph")
    func markers() async throws {
        let text = "First **bold** line\n\nSecond line"
        let (window, textView, _) = try await editor(text)
        defer { window.close() }
        let storage = try #require(textView.textStorage)
        let marker = (text as NSString).range(of: "**").location
        textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "Second").location, length: 0))
        #expect(storage.attribute(.markdownHidden, at: marker, effectiveRange: nil) != nil)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(storage.attribute(.markdownHidden, at: marker, effectiveRange: nil) == nil)
    }
}
