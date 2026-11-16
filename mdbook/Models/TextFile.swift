//
//  TextFile.swift
//  mdbook
//
//  Reads text files in whatever encoding they use and writes them back the same way.
//

import Foundation

nonisolated enum TextFile {
    /// Reads `url`, detecting its encoding: a BOM or UTF-8 first, then the legacy
    /// encodings old notes tend to be in. Latin-1 accepts any bytes, so only I/O fails.
    static func read(_ url: URL) throws -> (text: String, encoding: String.Encoding) {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            // Drop a UTF-8 BOM, which `String(data:encoding:)` keeps.
            return (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text, .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) {
            return (text, .utf16)
        }
        for encoding in [String.Encoding.windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return (text, encoding) }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    /// Writes `text` in `encoding`, or in UTF-8 if `encoding` can't represent it.
    /// Returns the encoding actually used.
    @discardableResult
    static func write(_ text: String, to url: URL, encoding: String.Encoding) throws -> String.Encoding {
        let used = text.canBeConverted(to: encoding) ? encoding : .utf8
        try text.write(to: url, atomically: true, encoding: used)
        return used
    }
}
