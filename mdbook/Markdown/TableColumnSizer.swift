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
    /// - Returns: One width per column. If even the minimums don't fit, they are scaled
    ///   down to `available` (words then break mid-word) but never below `floor`.
    static func widths(natural: [CGFloat], minimum: [CGFloat], available: CGFloat, floor: CGFloat = 40) -> [CGFloat] {
        let count = natural.count
        guard count > 0 else { return [] }
        let minimum = (0..<count).map { min(minimum.indices.contains($0) ? minimum[$0] : 0, natural[$0]) }
        if natural.reduce(0, +) <= available { return natural }

        let minimumTotal = minimum.reduce(0, +)
        if minimumTotal >= available {
            let scale = minimumTotal > 0 ? available / minimumTotal : 0
            return minimum.map { max(floor, $0 * scale) }
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
