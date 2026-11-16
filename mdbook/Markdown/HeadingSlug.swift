//
//  HeadingSlug.swift
//  mdbook
//

import Foundation

/// GitHub-style heading anchors: `## Hello, World!` becomes `hello-world`.
nonisolated enum HeadingSlug {
    static func slug(for heading: String) -> String {
        var result = ""
        for scalar in heading.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                result.unicodeScalars.append(scalar)
            } else if scalar == " " {
                result.append("-")
            }
            // Other punctuation is dropped, as GitHub does.
        }
        return result
    }

    /// Strips inline markdown syntax so a heading's slug matches its rendered text.
    static func plainText(ofHeadingSource source: String) -> String {
        var text = source.trimmingCharacters(in: .whitespaces)
        // Drop a trailing closing sequence of hashes.
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        let patterns: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"(\*\*|__|\*|_|~~|`)"#, ""),
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
        }
        return text
    }

    /// Compares an anchor from a link against a heading's text, tolerating a leading `#`
    /// and percent-encoding.
    static func matches(anchor: String, headingText: String) -> Bool {
        var wanted = anchor
        if wanted.hasPrefix("#") { wanted.removeFirst() }
        wanted = wanted.removingPercentEncoding ?? wanted
        return slug(for: wanted) == slug(for: headingText) || wanted.lowercased() == slug(for: headingText)
    }
}
