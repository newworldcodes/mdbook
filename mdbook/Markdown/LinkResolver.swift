//
//  LinkResolver.swift
//  mdbook
//

import Foundation

/// Turns a markdown link destination into something the app can act on.
nonisolated enum LinkResolver {
    enum Resolution: Equatable, Sendable {
        /// A web / mail / other scheme link that should open outside the app.
        case external(URL)
        /// A file on disk, resolved relative to the current document, plus any `#anchor`.
        case file(URL, fragment: String?)
        /// An in-document anchor such as `#installation`.
        case anchor(String)
        case invalid
    }

    static func resolve(_ destination: String, relativeTo documentURL: URL?) -> Resolution {
        var dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if dest.hasPrefix("<"), dest.hasSuffix(">"), dest.count >= 2 {
            dest = String(dest.dropFirst().dropLast())
        }
        guard !dest.isEmpty else { return .invalid }

        if dest.hasPrefix("#") {
            return .anchor(String(dest.dropFirst()))
        }

        if let url = URL(string: dest), let scheme = url.scheme?.lowercased() {
            if scheme == "file" {
                return .file(url.standardizedFileURL, fragment: url.fragment)
            }
            // Windows-style drive letters would show up as single-letter schemes;
            // treat anything longer than one character as a real scheme.
            if scheme.count > 1 {
                return .external(url)
            }
        }

        // Split off the fragment and query, then percent-decode the remaining path.
        var path = dest
        var fragment: String?
        if let hash = path.firstIndex(of: "#") {
            fragment = String(path[path.index(after: hash)...])
            path = String(path[..<hash])
        }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty else { return .invalid }

        let base = documentURL?.deletingLastPathComponent()
        let url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        return .file(url, fragment: fragment?.isEmpty == false ? fragment : nil)
    }

    /// Markdown parsers ignore link destinations that contain raw spaces.
    /// Percent-encode them so `[text](my file.md)` still becomes a link.
    static func encodingSpacesInLinkDestinations(_ markdown: String) -> String {
        guard markdown.contains("](") else { return markdown }
        let pattern = #"\]\(([^)\n]*?[^\s)][^)\n]*?)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }
        let ns = markdown as NSString
        var result = markdown
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let destRange = match.range(at: 1)
            let dest = ns.substring(with: destRange)
            // Leave destinations with a quoted title or angle brackets alone.
            guard dest.contains(" "), !dest.contains("\""), !dest.hasPrefix("<") else { continue }
            let encoded = dest.replacingOccurrences(of: " ", with: "%20")
            let nsResult = result as NSString
            result = nsResult.replacingCharacters(in: destRange, with: encoded)
        }
        return result
    }
}
