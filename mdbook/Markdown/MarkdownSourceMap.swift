//
//  MarkdownSourceMap.swift
//  mdbook
//
//  Converts swift-markdown source locations (1-based line, 1-based UTF-8 byte column)
//  into UTF-16 offsets so they can be used as `NSRange`s on an `NSTextStorage`.
//

import Foundation
import Markdown

nonisolated struct MarkdownSourceMap {
    let ns: NSString
    /// UTF-16 offset of the first character of each line (index 0 is line 1).
    private var lineStarts: [Int] = []
    /// UTF-16 offset just past the last character of each line, excluding its terminator.
    private var lineEnds: [Int] = []
    /// Lines whose UTF-8 and UTF-16 lengths match, so a byte column maps directly.
    private var asciiLines: [Bool] = []
    /// UTF-8 offset of the first byte of each line.
    private var lineStartBytes: [Int] = []

    init(_ text: String) {
        ns = text as NSString
        // cmark treats \n, \r and \r\n as line endings.
        var start = 0
        var startByte = 0
        var bytes = 0
        var isASCII = true
        let length = ns.length
        var index = 0
        while index < length {
            let unit = ns.character(at: index)
            if unit == 0x0A || unit == 0x0D {
                appendLine(start: start, end: index, startByte: startByte, isASCII: isASCII)
                bytes += 1
                if unit == 0x0D, index + 1 < length, ns.character(at: index + 1) == 0x0A {
                    index += 1
                    bytes += 1
                }
                start = index + 1
                startByte = bytes
                isASCII = true
            } else {
                bytes += Self.utf8Length(of: unit)
                if unit >= 0x80 { isASCII = false }
            }
            index += 1
        }
        appendLine(start: start, end: length, startByte: startByte, isASCII: isASCII)
    }

    private mutating func appendLine(start: Int, end: Int, startByte: Int, isASCII: Bool) {
        lineStarts.append(start)
        lineEnds.append(end)
        lineStartBytes.append(startByte)
        asciiLines.append(isASCII)
    }

    /// UTF-8 bytes for one UTF-16 code unit; a surrogate pair counts as 4 on its high half.
    private static func utf8Length(of unit: unichar) -> Int {
        switch unit {
        case 0..<0x80: 1
        case 0x80..<0x800: 2
        case 0xD800..<0xDC00: 4
        case 0xDC00..<0xE000: 0
        default: 3
        }
    }

    var lineCount: Int { lineStarts.count }

    /// The range of a 1-based line, excluding its terminator. Out-of-range lines clamp.
    func lineRange(_ line: Int) -> NSRange {
        guard line >= 1 else { return NSRange(location: 0, length: 0) }
        guard line <= lineCount else { return NSRange(location: ns.length, length: 0) }
        return NSRange(location: lineStarts[line - 1], length: lineEnds[line - 1] - lineStarts[line - 1])
    }

    /// UTF-16 offset of a 1-based line and 1-based UTF-8 column, clamped to the line.
    /// A column one past the end of the line maps to the line's end.
    func offset(line: Int, column: Int) -> Int {
        guard line >= 1 else { return 0 }
        guard line <= lineCount else { return ns.length }
        let start = lineStarts[line - 1]
        let end = lineEnds[line - 1]
        let bytes = max(0, column - 1)
        if asciiLines[line - 1] { return min(start + bytes, end) }

        var consumed = 0
        var index = start
        while index < end, consumed < bytes {
            let unit = ns.character(at: index)
            consumed += Self.utf8Length(of: unit)
            // Never stop between the halves of a surrogate pair.
            index += (0xD800..<0xDC00).contains(unit) ? 2 : 1
        }
        return min(index, end)
    }

    /// Re-reads a location whose column cmark counted from the start of `line` as if the
    /// following lines were joined onto it (positions inside a table header that interrupted
    /// a paragraph), returning the UTF-16 offset of the byte it really points at.
    func offset(flowingFrom location: SourceLocation) -> Int {
        guard location.line >= 1, location.line <= lineCount else { return offset(location) }
        let target = lineStartBytes[location.line - 1] + max(0, location.column - 1)
        var line = location.line
        while line < lineCount, lineStartBytes[line] <= target { line += 1 }
        return offset(line: line, column: target - lineStartBytes[line - 1] + 1)
    }

    func offset(_ location: SourceLocation) -> Int {
        offset(line: location.line, column: location.column)
    }

    /// The whole lines a block node covers, from the start of its first line to the end
    /// of its last, without the final terminator. cmark sometimes ends a block at column 1
    /// of the following line; that line is not included.
    func lines(of range: SourceRange) -> ClosedRange<Int> {
        let first = range.lowerBound.line
        var last = range.upperBound.line
        if range.upperBound.column <= 1, last > first { last -= 1 }
        return first...max(first, last)
    }

    /// The span of `lines` as one `NSRange` from the start of the first to the end of the last.
    func range(ofLines lines: ClosedRange<Int>) -> NSRange {
        let first = lineRange(lines.lowerBound)
        let last = lineRange(lines.upperBound)
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
}
