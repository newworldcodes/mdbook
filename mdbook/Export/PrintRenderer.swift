//
//  PrintRenderer.swift
//  mdbook
//
//  PDF export and printing without WebKit's out-of-process web view (which the sandbox
//  stops without a network entitlement): HTML from `HTMLRenderer` becomes an attributed
//  string (tables as text tables, images as attachments), laid out in a page-wide text
//  view and paginated by `NSPrintOperation`.
//

import AppKit

enum PrintRenderer {
    static func attributedString(html: String) -> NSAttributedString? {
        try? NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
    }

    /// Writes a paginated PDF of `html`. Returns false if it couldn't.
    static func exportPDF(html: String, to url: URL) -> Bool {
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return false }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        guard let operation = operation(html: html, printInfo: info) else { return false }
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }

    /// Shows the print panel for `html`, as a sheet on `window` when there is one.
    static func print(html: String, title: String, window: NSWindow?) {
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo,
              let operation = operation(html: html, printInfo: info) else {
            NSSound.beep()
            return
        }
        operation.jobTitle = title
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    private static func operation(html: String, printInfo info: NSPrintInfo) -> NSPrintOperation? {
        guard let attributed = attributedString(html: html) else { return nil }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin

        let content = NSMutableAttributedString(attributedString: attributed)
        fitImages(in: content, toWidth: width)
        fitTables(in: content, toWidth: width)
        // TextKit 1: TextKit 2 neither lays out text tables nor leaves list markers alone.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.backgroundColor = .white
        textView.textStorage?.setAttributedString(content)
        textView.sizeToFit()
        return NSPrintOperation(view: textView, printInfo: info)
    }

    /// Sizes table columns like the editor and preview do (`TableColumnSizer`): the HTML
    /// importer's automatic layout squeezes wide tables until words break mid-word.
    private static func fitTables(in content: NSMutableAttributedString, toWidth width: CGFloat) {
        // Each cell is a table block covering one or more paragraphs.
        var cells: [ObjectIdentifier: (block: NSTextTableBlock, range: NSRange)] = [:]
        var tables: [ObjectIdentifier: NSTextTable] = [:]
        content.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard let block = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock else { return }
            let key = ObjectIdentifier(block)
            cells[key] = cells[key].map { ($0.block, NSUnionRange($0.range, range)) } ?? (block, range)
            tables[ObjectIdentifier(block.table)] = block.table
        }
        for (tableKey, table) in tables {
            let tableCells = cells.values.filter { ObjectIdentifier($0.block.table) == tableKey && $0.block.columnSpan == 1 }
            let columns = table.numberOfColumns
            guard columns > 0 else { continue }
            var natural = Array(repeating: CGFloat(0), count: columns)
            var minimum = Array(repeating: CGFloat(0), count: columns)
            var chrome = Array(repeating: CGFloat(0), count: columns)
            for cell in tableCells where cell.block.startingColumn < columns {
                let column = cell.block.startingColumn
                // Measure without the cell's block, or the text arrives pre-wrapped.
                let text = NSMutableAttributedString(attributedString: content.attributedSubstring(from: cell.range))
                text.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: text.length))
                let extra = [NSTextBlock.Layer.padding, .border, .margin].reduce(CGFloat(0)) { total, layer in
                    total + cell.block.width(for: layer, edge: .minX) + cell.block.width(for: layer, edge: .maxX)
                }
                chrome[column] = max(chrome[column], extra)
                natural[column] = max(natural[column], ceil(text.size().width) + 1)
                let longest = TableColumnSizer.unbreakableRuns(in: text.string)
                    .map { ceil(text.attributedSubstring(from: $0).size().width) + 1 }.max() ?? 0
                minimum[column] = max(minimum[column], longest)
            }
            let widths = TableColumnSizer.widths(
                natural: zip(natural, chrome).map(+),
                minimum: zip(minimum, chrome).map(+),
                available: width - 2 // the outer border
            )
            // Automatic layout treats cell widths as hints; fixed layout uses them.
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            for cell in tableCells where cell.block.startingColumn < columns {
                let column = cell.block.startingColumn
                cell.block.setValue(max(1, widths[column] - chrome[column]), type: .absoluteValueType, for: .width)
            }
        }
    }

    /// Scales image attachments down to the page width. TextKit 1's attachment cell sizes
    /// its box from `bounds` but draws the image at full size, so swap in a scaled copy.
    private static func fitImages(in content: NSMutableAttributedString, toWidth width: CGFloat) {
        var replacements: [(NSRange, NSTextAttachment)] = []
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)),
                  image.size.width > width, image.size.width > 0 else { return }
            let size = NSSize(width: width, height: (image.size.height * width / image.size.width).rounded())
            let scaled = NSImage(size: size, flipped: false) { rect in
                image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
                return true
            }
            let fitted = NSTextAttachment()
            fitted.image = scaled
            fitted.bounds = CGRect(origin: .zero, size: size)
            replacements.append((range, fitted))
        }
        for (range, attachment) in replacements {
            content.addAttribute(.attachment, value: attachment, range: range)
        }
    }
}
