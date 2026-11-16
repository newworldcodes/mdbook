//
//  MarkdownPreviewView.swift
//  mdbook
//
//  Renders parsed markdown blocks as native SwiftUI views.
//

import AppKit
import SwiftUI

struct MarkdownPreviewView: View {
    let text: String
    let documentURL: URL?
    var onOpenLink: (String) -> Void
    /// Scroll to the heading matching this anchor whenever a new request arrives.
    var anchorRequest: AnchorRequest? = nil
    /// When set, follows the editor's scroll position (0...1) in the split layout.
    var scrollFraction: Double? = nil

    @State private var blocks: [MarkdownBlock] = []
    @State private var headingIDs: [Int: String] = [:]
    @State private var hasRenderedOnce = false
    @State private var handledAnchorID: UUID?
    @State private var position = ScrollPosition()
    @State private var scrollableHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        MarkdownBlockView(block: block, documentURL: documentURL)
                            .id(headingIDs[index])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
                .textSelection(.enabled)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height - geometry.containerSize.height
            } action: { _, height in
                scrollableHeight = max(0, height)
            }
            .onChange(of: scrollFraction) { _, fraction in
                guard let fraction else { return }
                position.scrollTo(y: fraction * scrollableHeight)
            }
            .onChange(of: anchorRequest) { _, request in
                revealAnchor(request, proxy: proxy)
            }
            .onChange(of: headingIDs) { _, _ in
                revealAnchor(anchorRequest, proxy: proxy)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in
            onOpenLink(url.absoluteString)
            return .handled
        })
        .task(id: text) {
            // Debounce while typing, but render immediately on first appearance.
            if hasRenderedOnce {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            let source = text
            let parsed = await Task.detached(priority: .userInitiated) {
                MarkdownBlockParser.parse(source)
            }.value
            blocks = parsed
            headingIDs = Self.headingIDs(for: parsed)
            hasRenderedOnce = true
        }
    }

    private func revealAnchor(_ request: AnchorRequest?, proxy: ScrollViewProxy) {
        guard let request, handledAnchorID != request.id, !headingIDs.isEmpty else { return }
        handledAnchorID = request.id
        guard let target = headingIDs.values.first(where: { HeadingSlug.matches(anchor: request.anchor, headingText: $0) }) else { return }
        withAnimation {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    /// GitHub-style ids for top-level headings, de-duplicated with numeric suffixes.
    private static func headingIDs(for blocks: [MarkdownBlock]) -> [Int: String] {
        var ids: [Int: String] = [:]
        var seen: [String: Int] = [:]
        for (index, block) in blocks.enumerated() {
            guard case .heading(_, let content) = block else { continue }
            let base = HeadingSlug.slug(for: String(content.characters))
            let count = seen[base, default: 0]
            seen[base] = count + 1
            ids[index] = count == 0 ? base : "\(base)-\(count)"
        }
        return ids
    }
}

// MARK: - Blocks

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let documentURL: URL?

    var body: some View {
        switch block {
        case .heading(let level, let content):
            MarkdownHeadingView(level: level, content: content)
        case .paragraph(let segments):
            MarkdownParagraphView(segments: segments, documentURL: documentURL)
        case .codeBlock(let language, let code):
            MarkdownCodeBlockView(language: language, code: code)
        case .blockQuote(let children):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                MarkdownBlockListView(blocks: children, documentURL: documentURL)
                    .foregroundStyle(.secondary)
            }
        case .list(let ordered, let items):
            MarkdownListView(ordered: ordered, items: items, documentURL: documentURL)
        case .table(let table):
            MarkdownTableView(table: table)
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        }
    }
}

struct MarkdownBlockListView: View {
    let blocks: [MarkdownBlock]
    let documentURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, documentURL: documentURL)
            }
        }
    }
}

struct MarkdownHeadingView: View {
    let level: Int
    let content: AttributedString

    private var font: Font {
        switch level {
        case 1: return .system(size: 30, weight: .bold)
        case 2: return .system(size: 24, weight: .bold)
        case 3: return .system(size: 20, weight: .semibold)
        case 4: return .system(size: 18, weight: .semibold)
        default: return .system(size: 16, weight: .semibold)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MarkdownInlineStyle.styled(content, baseSize: level == 1 ? 30 : 20))
                .font(font)
                .padding(.top, level <= 2 ? 8 : 4)
            if level <= 2 { Divider() }
        }
    }
}

struct MarkdownParagraphView: View {
    let segments: [MarkdownInlineSegment]
    let documentURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    if !text.characters.isEmpty {
                        Text(MarkdownInlineStyle.styled(text, baseSize: 16))
                            .font(.system(size: 16))
                            .lineSpacing(4)
                    }
                case .image(let source, let alt):
                    MarkdownImageView(source: source, alt: alt, documentURL: documentURL)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            ScrollView(.horizontal) {
                Text(highlighted)
                    .font(.system(size: 13.5, design: .monospaced))
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The code with syntax colours applied as attributes.
    private var highlighted: AttributedString {
        var result = AttributedString(code)
        let ns = code as NSString
        for token in CodeHighlighter.tokens(in: code, language: language) {
            guard NSMaxRange(token.range) <= ns.length,
                  let start = AttributedString.Index(String.Index(utf16Offset: token.range.location, in: code), within: result),
                  let end = AttributedString.Index(String.Index(utf16Offset: NSMaxRange(token.range), in: code), within: result),
                  start < end else { continue }
            result[start..<end].foregroundColor = Color(nsColor: EditorTheme.color(for: token.kind))
        }
        return result
    }
}

struct MarkdownListView: View {
    let ordered: Bool
    let items: [MarkdownListItem]
    let documentURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(for: item)
                        .frame(minWidth: 20, alignment: .trailing)
                    MarkdownBlockListView(blocks: item.blocks, documentURL: documentURL)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem) -> some View {
        if let task = item.task {
            Image(systemName: task == .checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(task == .checked ? Color.accentColor : Color.secondary)
                .accessibilityLabel(task == .checked ? "Completed" : "Not completed")
        } else if ordered {
            Text("\(item.ordinal).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("•")
                .foregroundStyle(.secondary)
        }
    }
}

struct MarkdownTableView: View {
    let table: MarkdownTable

    private static let fontSize: CGFloat = 15
    private static let horizontalPadding: CGFloat = 10

    var body: some View {
        let columns = max(table.header.count, 1)
        let rows = [table.header] + table.rows
        TableGridLayout(columns: columns, horizontalPadding: Self.horizontalPadding) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                ForEach(0..<columns, id: \.self) { column in
                    cellView(column < row.count ? row[column] : AttributedString(), column: column, isHeader: rowIndex == 0)
                        .overlay(alignment: .bottom) {
                            if rowIndex < rows.count - 1 { separator.frame(height: 1) }
                        }
                        .overlay(alignment: .trailing) {
                            if column < columns - 1 { separator.frame(width: 1) }
                        }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    private var separator: some View {
        Rectangle().fill(Color(nsColor: .separatorColor))
    }

    private func cellView(_ cell: AttributedString, column: Int, isHeader: Bool) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .left
        return Text(MarkdownInlineStyle.styled(cell, baseSize: Self.fontSize))
            .font(.system(size: Self.fontSize))
            .fontWeight(isHeader ? .semibold : nil)
            .multilineTextAlignment(alignment.textAlignment)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.topFrameAlignment)
            .background(isHeader ? Color(nsColor: .quaternarySystemFill) : .clear)
            .layoutValue(key: TableCellMinimumWidth.self, value: MarkdownInlineStyle.longestWordWidth(cell, baseSize: Self.fontSize, bold: isHeader))
    }
}

/// The width of a cell's longest word, so columns never break words when they can avoid it.
private struct TableCellMinimumWidth: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Lays out table cells (row-major) in columns sized by `TableColumnSizer`, so a table
/// wraps its cells to fit the available width instead of overflowing it.
struct TableGridLayout: Layout {
    let columns: Int
    let horizontalPadding: CGFloat

    struct Cache {
        var natural: [CGFloat]
        var minimum: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Cache {
        var natural = Array(repeating: CGFloat(0), count: columns)
        var minimum = Array(repeating: CGFloat(0), count: columns)
        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            natural[column] = max(natural[column], subview.sizeThatFits(.unspecified).width.rounded(.up))
            minimum[column] = max(minimum[column], subview[TableCellMinimumWidth.self] + horizontalPadding * 2)
        }
        return Cache(natural: natural, minimum: minimum)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    private func columnWidths(for proposedWidth: CGFloat?, cache: Cache) -> [CGFloat] {
        let available = proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? cache.natural.reduce(0, +)
        return TableColumnSizer.widths(natural: cache.natural, minimum: cache.minimum, available: available)
    }

    private func rowHeights(widths: [CGFloat], subviews: Subviews) -> [CGFloat] {
        var heights: [CGFloat] = []
        for (index, subview) in subviews.enumerated() {
            let row = index / columns
            let height = subview.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil)).height
            if row >= heights.count { heights.append(height) } else { heights[row] = max(heights[row], height) }
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let widths = columnWidths(for: proposal.width, cache: cache)
        let heights = rowHeights(widths: widths, subviews: subviews)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let widths = columnWidths(for: bounds.width, cache: cache)
        let heights = rowHeights(widths: widths, subviews: subviews)
        var y = bounds.minY
        for row in heights.indices {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: widths[column], height: heights[row])
                )
                x += widths[column]
            }
            y += heights[row]
        }
    }
}

struct MarkdownImageView: View {
    let source: String
    let alt: String
    let documentURL: URL?

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            switch LinkResolver.resolve(source, relativeTo: documentURL) {
            case .external(let url):
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else if phase.error != nil {
                        missingImage
                    } else {
                        ProgressView()
                    }
                }
            case .file(let url, _):
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: image.size.width)
                } else if failed {
                    missingImage
                } else {
                    Color.clear
                        .frame(height: 1)
                        .task(id: url) {
                            let loaded = await Task.detached { NSImage(contentsOf: url) }.value
                            if let loaded { image = loaded } else { failed = true }
                        }
                }
            case .anchor, .invalid:
                missingImage
            }
        }
        .accessibilityLabel(alt)
    }

    private var missingImage: some View {
        Label(alt.isEmpty ? "Missing image: \(source)" : "\(alt) (missing: \(source))", systemImage: "photo.badge.exclamationmark")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(8)
            .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Inline styling

enum MarkdownInlineStyle {
    /// Adds explicit fonts for inline code so `Text` renders it in monospace.
    /// Bold, italic, strikethrough and links are already understood by `Text`.
    static func styled(_ source: AttributedString, baseSize: CGFloat) -> AttributedString {
        var result = source
        let codeRanges = result.runs.compactMap { run -> Range<AttributedString.Index>? in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            result[range].font = .system(size: baseSize * 0.88, design: .monospaced)
            result[range].backgroundColor = Color(nsColor: .quaternarySystemFill)
        }
        return result
    }

    /// The rendered width of the widest piece that can't wrap (see
    /// `TableColumnSizer.unbreakableRuns`), approximating the fonts the cell views use.
    static func longestWordWidth(_ source: AttributedString, baseSize: CGFloat, bold: Bool) -> CGFloat {
        let measured = NSMutableAttributedString()
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            let weight: NSFont.Weight = bold || intent.contains(.stronglyEmphasized) ? .semibold : .regular
            let font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: baseSize * 0.88, weight: weight)
                : NSFont.systemFont(ofSize: baseSize, weight: weight)
            measured.append(NSAttributedString(string: String(source[run.range].characters), attributes: [.font: font]))
        }
        var widest: CGFloat = 0
        for run in TableColumnSizer.unbreakableRuns(in: measured.string) {
            widest = max(widest, measured.attributedSubstring(from: run).size().width)
        }
        return widest.rounded(.up) + 1
    }
}

private extension MarkdownTextAlignment {
    var topFrameAlignment: Alignment {
        switch self {
        case .left: return .topLeading
        case .center: return .top
        case .right: return .topTrailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}
