//
//  ProjectSearch.swift
//  mdbook
//
//  Plain-text search across a book's files (case- and diacritic-insensitive), returning
//  line snippets for the sidebar and source ranges for revealing a match in the editor.
//

import Foundation

nonisolated enum ProjectSearch {
    struct Match: Identifiable, Equatable, Sendable {
        var id: Int
        /// 1-based line number.
        var line: Int
        /// The line (shortened around the match when long), for display.
        var snippet: String
        /// The match inside `snippet` (UTF-16).
        var highlight: NSRange
        /// The match in the file's text (UTF-16), for selecting it in the editor.
        var range: NSRange
    }

    struct FileResult: Identifiable, Equatable, Sendable {
        var url: URL
        var matches: [Match]
        var id: URL { url }
    }

    static let maximumMatchesPerFile = 200
    static let maximumMatches = 2000
    private static let snippetContext = 40
    private static let snippetLength = 160

    /// Searches `files` in order. A file's `text` is used when given (unsaved edits),
    /// otherwise it's read from disk; unreadable files are skipped.
    static func search(_ query: String, in files: [(url: URL, text: String?)]) -> [FileResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var results: [FileResult] = []
        var total = 0
        var nextID = 0
        for file in files {
            guard total < maximumMatches, !Task.isCancelled else { break }
            guard let text = file.text ?? (try? String(contentsOf: file.url, encoding: .utf8)) else { continue }
            let matches = search(needle, in: text, limit: min(maximumMatchesPerFile, maximumMatches - total), firstID: nextID)
            guard !matches.isEmpty else { continue }
            results.append(FileResult(url: file.url, matches: matches))
            total += matches.count
            nextID += matches.count
        }
        return results
    }

    static func search(_ needle: String, in text: String, limit: Int = maximumMatchesPerFile, firstID: Int = 0) -> [Match] {
        let ns = text as NSString
        var matches: [Match] = []
        var lineNumber = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, stop in
            lineNumber += 1
            var searchRange = lineRange
            while searchRange.length > 0 {
                let found = ns.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                let (snippet, highlight) = snippetFor(found, in: lineRange, of: ns)
                matches.append(Match(id: firstID + matches.count, line: lineNumber, snippet: snippet, highlight: highlight, range: found))
                if matches.count >= limit {
                    stop.pointee = true
                    return
                }
                searchRange = NSRange(location: NSMaxRange(found), length: NSMaxRange(lineRange) - NSMaxRange(found))
            }
        }
        return matches
    }

    /// The line around a match, trimmed of leading whitespace and cut down when long.
    private static func snippetFor(_ match: NSRange, in line: NSRange, of ns: NSString) -> (String, NSRange) {
        var start = line.location
        while start < match.location, [0x20, 0x09].contains(ns.character(at: start)) { start += 1 }
        var prefix = ""
        if match.location - start > snippetContext {
            start = match.location - snippetContext
            // Don't split a surrogate pair.
            if start > line.location, (0xDC00..<0xE000).contains(ns.character(at: start)) { start -= 1 }
            prefix = "…"
        }
        var end = NSMaxRange(line)
        var suffix = ""
        if end - start > snippetLength, NSMaxRange(match) < start + snippetLength {
            end = start + snippetLength
            if end < NSMaxRange(line), (0xDC00..<0xE000).contains(ns.character(at: end)) { end += 1 }
            suffix = "…"
        }
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        let highlight = NSRange(location: (prefix as NSString).length + match.location - start, length: match.length)
        return (prefix + body + suffix, highlight)
    }
}
