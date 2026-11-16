//
//  BookSummary.swift
//  mdbook
//
//  The table of contents of an mdBook-style book: a SUMMARY.md listing chapters as links,
//  optionally grouped into parts. It decides the sidebar's Contents and the reading order
//  used for previous/next chapter navigation.
//
//  Format (https://rust-lang.github.io/mdBook/format/summary.html):
//
//      # Summary
//      [Introduction](README.md)          prefix chapter
//      - [Chapter](chapter.md)            numbered chapter
//        - [Section](chapter/section.md)  nested
//      - [Draft]()                        draft chapter (no file yet)
//      ---                                separator
//      # Part Title                       starts a part
//      [Appendix](appendix.md)            suffix chapter
//

import Foundation
import Markdown

nonisolated struct BookSummary: Equatable, Sendable {
    struct Entry: Equatable, Sendable, Identifiable {
        var id: Int
        var title: String
        /// nil for a draft chapter.
        var url: URL?
        var children: [Entry] = []
    }

    struct Part: Equatable, Sendable, Identifiable {
        var id: Int
        /// nil for the chapters before the first part title.
        var title: String?
        var entries: [Entry]
    }

    var parts: [Part]

    /// Every chapter file in reading order (depth-first), without duplicates.
    var readingOrder: [URL] {
        var seen = Set<URL>()
        var order: [URL] = []
        func visit(_ entries: [Entry]) {
            for entry in entries {
                if let url = entry.url, seen.insert(url).inserted { order.append(url) }
                visit(entry.children)
            }
        }
        for part in parts { visit(part.entries) }
        return order
    }

    /// The title the summary gives a chapter file, if it lists it.
    func title(for url: URL) -> String? {
        func search(_ entries: [Entry]) -> String? {
            for entry in entries {
                if entry.url == url { return entry.title }
                if let found = search(entry.children) { return found }
            }
            return nil
        }
        for part in parts {
            if let found = search(part.entries) { return found }
        }
        return nil
    }

    // MARK: Locating

    /// The book's SUMMARY.md: at the root, in the source folder named by `book.toml`
    /// (`src = "..."` under `[book]`, default `src`), or in `src/`.
    static func locate(in root: URL) -> URL? {
        let fileManager = FileManager.default
        var folders = [root]
        if let toml = try? String(contentsOf: root.appendingPathComponent("book.toml"), encoding: .utf8),
           let source = sourceFolder(inBookTOML: toml) {
            folders.append(root.appendingPathComponent(source))
        }
        folders.append(root.appendingPathComponent("src"))
        for folder in folders {
            for name in ["SUMMARY.md", "summary.md"] {
                let url = folder.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path) { return url.standardizedFileURL }
            }
        }
        return nil
    }

    /// The `src` value of a `book.toml`'s `[book]` table, if set.
    static func sourceFolder(inBookTOML toml: String) -> String? {
        var inBook = false
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inBook = line == "[book]"
                continue
            }
            guard inBook, line.hasPrefix("src") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "src" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: Parsing

    static func parse(_ markdown: String, relativeTo summaryURL: URL) -> BookSummary {
        var parser = Parser(summaryURL: summaryURL)
        let document = Document(parsing: LinkResolver.encodingSpacesInLinkDestinations(markdown), options: [.disableSmartOpts])
        for (index, block) in document.children.enumerated() {
            switch block {
            case let heading as Heading:
                // The first heading is the book's title ("Summary"); later ones start parts.
                if index > 0 || !parser.parts.isEmpty || !parser.current.isEmpty {
                    parser.startPart(title: heading.plainText)
                }
            case let list as ListItemContainer:
                parser.current += list.listItems.compactMap { parser.entry(from: $0) }
            case let paragraph as Paragraph:
                // Prefix and suffix chapters are plain links.
                for child in paragraph.children {
                    if let link = child as? Link { parser.current.append(parser.entry(title: link.plainText, destination: link.destination)) }
                }
            case is ThematicBreak:
                parser.startPart(title: nil)
            default:
                break
            }
        }
        parser.finish()
        return BookSummary(parts: parser.parts)
    }

    private struct Parser {
        let summaryURL: URL
        var parts: [Part] = []
        var current: [Entry] = []
        var currentTitle: String?
        var nextID = 0

        mutating func startPart(title: String?) {
            finish()
            currentTitle = title
        }

        mutating func finish() {
            if !current.isEmpty || currentTitle != nil {
                parts.append(Part(id: parts.count, title: currentTitle, entries: current))
            }
            current = []
            currentTitle = nil
        }

        mutating func entry(title: String, destination: String?) -> Entry {
            defer { nextID += 1 }
            var url: URL?
            if let destination, !destination.isEmpty,
               case .file(let file, _) = LinkResolver.resolve(destination, relativeTo: summaryURL) {
                url = file.standardizedFileURL
            }
            return Entry(id: nextID, title: title, url: url)
        }

        /// A list item's chapter: its first link (or its text, for a draft) plus nested lists.
        mutating func entry(from item: ListItem) -> Entry? {
            guard let paragraph = item.children.first(where: { $0 is Paragraph }) as? Paragraph else { return nil }
            let link = paragraph.children.first { $0 is Link } as? Link
            var entry = entry(title: link?.plainText ?? paragraph.plainText, destination: link?.destination)
            for case let list as ListItemContainer in item.children {
                entry.children += list.listItems.compactMap { self.entry(from: $0) }
            }
            return entry
        }
    }
}
