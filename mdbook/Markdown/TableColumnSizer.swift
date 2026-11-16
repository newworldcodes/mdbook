//
//  TableColumnSizer.swift
//  mdbook
//
//  Chooses column widths for a table that has to fit a given width, the way browsers
//  do for `table-layout: auto`. Shared by the editor's rendered tables and the preview.
//

import CoreGraphics
import Foundation

nonisolated enum TableColumnSizer {
    // swiftlint:disable:next force_try
    private static let unbreakable = try! NSRegularExpression(pattern: #"[^\s\-/]*[\-/]+|[^\s\-/]+"#)

    /// The pieces of `string` a text engine won't break inside: runs between whitespace,
    /// split again after `-` and `/` (where AppKit and SwiftUI both allow a line break).
    /// A column's minimum width is the widest of these.
    static func unbreakableRuns(in string: String) -> [NSRange] {
        unbreakable.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)).map(\.range)
    }

    /// - Parameters:
    ///   - natural: Each column's width with no wrapping (its widest cell on one line).
    ///   - minimum: The narrowest each column can go without breaking a word.
    ///   - available: The width the table must fit in.
    /// - Returns: One width per column. If even the minimums don't fit, the largest
    ///   minimums are capped (their longest runs, usually code, then break) so columns of
    ///   ordinary words keep theirs; no column goes below `floor`.
    static func widths(natural: [CGFloat], minimum: [CGFloat], available: CGFloat, floor: CGFloat = 40) -> [CGFloat] {
        let count = natural.count
        guard count > 0 else { return [] }
        let minimum = (0..<count).map { min(minimum.indices.contains($0) ? minimum[$0] : 0, natural[$0]) }
        if natural.reduce(0, +) <= available { return natural }

        if minimum.reduce(0, +) >= available {
            // The cap where sum(min(minimum, cap)) == available.
            let sorted = minimum.sorted()
            var cap = available / CGFloat(count)
            var settled: CGFloat = 0
            for (index, value) in sorted.enumerated() {
                let rest = CGFloat(count - index)
                if settled + value * rest >= available {
                    cap = (available - settled) / rest
                    break
                }
                settled += value
            }
            return minimum.map { max(floor, min($0, cap)) }
        }

        // Columns narrower than an equal share keep their natural width. What's left is
        // shared among the wide columns in proportion to their natural width, except that a
        // column whose minimum is more than its share keeps its minimum. Repeat until stable.
        var result = natural
        var open = Set(0..<count)
        var remaining = available
        while !open.isEmpty {
            let equalShare = remaining / CGFloat(open.count)
            let fitting = open.filter { natural[$0] <= equalShare }
            if !fitting.isEmpty {
                for column in fitting {
                    remaining -= natural[column]
                    open.remove(column)
                }
                continue
            }

            let openNatural = open.reduce(CGFloat(0)) { $0 + natural[$1] }
            let share = { (column: Int) in remaining * natural[column] / openNatural }
            let squeezed = open.filter { minimum[$0] >= share($0) }
            if !squeezed.isEmpty {
                for column in squeezed {
                    result[column] = minimum[column]
                    remaining -= minimum[column]
                    open.remove(column)
                }
                continue
            }

            for column in open { result[column] = share(column) }
            break
        }
        return result
    }
}
