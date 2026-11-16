//
//  MarkdownExtensions.swift
//  mdbook
//
//  Syntax swift-markdown doesn't parse: footnotes, math and emoji shortcodes.
//
//  For rendering (preview and exports), `prepare` rewrites the source before parsing:
//  footnote definitions are pulled out and references replaced by a numbered token, inline
//  `$math$` is replaced by a token holding its TeX (hex-encoded, so the markdown parser
//  can't touch it), and `$$display$$` math becomes a ```math block. Consumers turn tokens
//  in text back into their own output with `segments(in:)`. The tokens use private-use
//  characters, which never occur in real text.
//
//  The editor keeps the source untouched; `MarkdownHighlighter` styles these constructs
//  using the same detectors.
//

import Foundation

nonisolated enum MarkdownExtensions {
    struct Footnote: Equatable, Sendable {
        var id: String
        var number: Int
        var markdown: String
    }

    struct Prepared: Equatable, Sendable {
        var markdown: String
        /// In order of first reference; unreferenced definitions follow in source order.
        var footnotes: [Footnote]
    }

    /// A piece of text after tokens are resolved.
    enum Segment: Equatable, Sendable {
        case text(String)
        case footnoteReference(number: Int)
        case math(tex: String)
    }

    private static let footnoteOpen: Character = "\u{E000}"
    private static let footnoteClose: Character = "\u{E001}"
    private static let mathOpen: Character = "\u{E002}"
    private static let mathClose: Character = "\u{E003}"

    // MARK: Preparing source for rendering

    static func prepare(_ markdown: String) -> Prepared {
        var lines = markdown.components(separatedBy: "\n")
        var definitions: [(id: String, text: String)] = []
        var output: [String] = []
        var fence: String?
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Leave fenced code alone.
            if let open = fence {
                output.append(line)
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) { fence = nil }
                index += 1
                continue
            }
            if let marker = fenceMarker(trimmed) {
                fence = marker
                output.append(line)
                index += 1
                continue
            }

            // $$ display math $$ (on its own lines, or on one line) → ```math
            if trimmed.hasPrefix("$$") {
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                let afterOpen = String(trimmed.dropFirst(2))
                if afterOpen.hasSuffix("$$"), afterOpen.count >= 2 {
                    output += [indent + "```math", indent + String(afterOpen.dropLast(2)).trimmingCharacters(in: .whitespaces), indent + "```"]
                    index += 1
                    continue
                }
                if let close = lines[(index + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix("$$") }) {
                    var body = afterOpen.isEmpty ? [] : [afterOpen]
                    body += lines[(index + 1)..<close]
                    let last = String(lines[close].trimmingCharacters(in: .whitespaces).dropLast(2))
                    if !last.isEmpty { body.append(last) }
                    output.append(indent + "```math")
                    output += body
                    output.append(indent + "```")
                    index = close + 1
                    continue
                }
            }

            // [^id]: text, continued by indented lines.
            if let definition = footnoteDefinition(line) {
                var text = definition.text
                var next = index + 1
                while next < lines.count, lines[next].hasPrefix("    ") || lines[next].hasPrefix("\t") {
                    text += "\n" + lines[next].trimmingCharacters(in: .whitespaces)
                    next += 1
                }
                definitions.append((definition.id, text))
                index = next
                continue
            }

            output.append(line)
            index += 1
        }

        // Number references in order of appearance, then protect inline math.
        var numbers: [String: Int] = [:]
        let known = Set(definitions.map(\.id))
        var body = output.joined(separator: "\n")
        body = replacingOutsideCode(in: body) { segment in
            var text = replaceFootnoteReferences(in: segment) { id in
                guard known.contains(id) else { return nil }
                if numbers[id] == nil { numbers[id] = numbers.count + 1 }
                return "\(footnoteOpen)\(numbers[id]!)\(footnoteClose)"
            }
            text = replaceInlineMath(in: text) { tex in "\(mathOpen)\(hex(tex))\(mathClose)" }
            return text
        }

        var footnotes = definitions.compactMap { definition -> Footnote? in
            numbers[definition.id].map { Footnote(id: definition.id, number: $0, markdown: definition.text) }
        }.sorted { $0.number < $1.number }
        for definition in definitions where numbers[definition.id] == nil {
            numbers[definition.id] = numbers.count + 1
            footnotes.append(Footnote(id: definition.id, number: numbers[definition.id]!, markdown: definition.text))
        }
        return Prepared(markdown: body, footnotes: footnotes)
    }

    /// Splits text from a prepared document into plain text, footnote references and math.
    static func segments(in text: String) -> [Segment] {
        guard text.contains(where: { $0 == footnoteOpen || $0 == mathOpen }) else { return [.text(text)] }
        var segments: [Segment] = []
        var current = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if character == footnoteOpen || character == mathOpen {
                let close = character == footnoteOpen ? footnoteClose : mathClose
                var payload = ""
                while let next = iterator.next(), next != close { payload.append(next) }
                if !current.isEmpty { segments.append(.text(current)) }
                current = ""
                if character == footnoteOpen, let number = Int(payload) {
                    segments.append(.footnoteReference(number: number))
                } else if character == mathOpen {
                    segments.append(.math(tex: unhex(payload)))
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { segments.append(.text(current)) }
        return segments
    }

    // MARK: Detectors (shared with the editor)

    // swiftlint:disable force_try
    private static let footnoteReference = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\](?!:)"#)
    private static let footnoteDefinitionPattern = try! NSRegularExpression(pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$"#)
    // $tex$: no space just inside the dollars, the closing one not followed by a digit
    // (so "$5 and $10" is money, not math), and no escaped dollars.
    private static let inlineMath = try! NSRegularExpression(pattern: #"(?<![\\$])\$(?![\s$])((?:\\.|[^$\\\n])+?)(?<!\s)\$(?![$\d])"#)
    private static let shortcode = try! NSRegularExpression(pattern: #":([a-z0-9_+\-]+):"#)
    // swiftlint:enable force_try

    /// `[^id]` references in `range` of `text`: the whole reference and its id.
    static func footnoteReferences(in text: String, range: NSRange? = nil) -> [(range: NSRange, id: NSRange)] {
        let range = range ?? NSRange(location: 0, length: (text as NSString).length)
        return footnoteReference.matches(in: text, range: range).map { ($0.range, $0.range(at: 1)) }
    }

    /// A `[^id]: text` definition line.
    static func footnoteDefinition(_ line: String) -> (id: String, text: String)? {
        let ns = line as NSString
        guard let match = footnoteDefinitionPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
    }

    /// `$tex$` spans in `range` of `text`: the whole span and the TeX inside.
    static func inlineMathRanges(in text: String, range: NSRange? = nil) -> [(range: NSRange, tex: NSRange)] {
        let range = range ?? NSRange(location: 0, length: (text as NSString).length)
        return inlineMath.matches(in: text, range: range).map { ($0.range, $0.range(at: 1)) }
    }

    /// Replaces `:shortcode:` emoji, leaving unknown codes as typed.
    static func replacingEmojiShortcodes(in text: String) -> String {
        guard text.contains(":") else { return text }
        let ns = text as NSString
        var result = ""
        var location = 0
        for match in shortcode.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let emoji = Emoji.character(forShortcode: ns.substring(with: match.range(at: 1))) else { continue }
            result += ns.substring(with: NSRange(location: location, length: match.range.location - location)) + emoji
            location = NSMaxRange(match.range)
        }
        return result + ns.substring(from: location)
    }

    // MARK: Helpers

    private static func fenceMarker(_ trimmedLine: String) -> String? {
        for marker in ["```", "~~~"] where trimmedLine.hasPrefix(marker) {
            let run = trimmedLine.prefix { $0 == marker.first }
            return String(run)
        }
        return nil
    }

    /// Applies `transform` to the parts of `text` outside inline code spans.
    private static func replacingOutsideCode(in text: String, _ transform: (String) -> String) -> String {
        var result = ""
        var plain = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "`" else {
                plain.append(text[index])
                index = text.index(after: index)
                continue
            }
            // A code span: a run of N backticks up to the next run of exactly N.
            let run = text[index...].prefix { $0 == "`" }
            let afterOpen = text.index(index, offsetBy: run.count)
            if let close = text.range(of: String(run), range: afterOpen..<text.endIndex) {
                result += transform(plain) + text[index..<close.upperBound]
                plain = ""
                index = close.upperBound
            } else {
                plain += run
                index = afterOpen
            }
        }
        return result + transform(plain)
    }

    private static func replaceFootnoteReferences(in text: String, _ replacement: (String) -> String?) -> String {
        let ns = text as NSString
        var result = ""
        var location = 0
        for (range, id) in footnoteReferences(in: text) {
            guard let token = replacement(ns.substring(with: id)) else { continue }
            result += ns.substring(with: NSRange(location: location, length: range.location - location)) + token
            location = NSMaxRange(range)
        }
        return result + ns.substring(from: location)
    }

    private static func replaceInlineMath(in text: String, _ replacement: (String) -> String) -> String {
        let ns = text as NSString
        var result = ""
        var location = 0
        for (range, tex) in inlineMathRanges(in: text) {
            result += ns.substring(with: NSRange(location: location, length: range.location - location)) + replacement(ns.substring(with: tex))
            location = NSMaxRange(range)
        }
        return result + ns.substring(from: location)
    }

    private static func hex(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func unhex(_ string: String) -> String {
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex, let next = string.index(index, offsetBy: 2, limitedBy: string.endIndex),
              let byte = UInt8(string[index..<next], radix: 16) {
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
