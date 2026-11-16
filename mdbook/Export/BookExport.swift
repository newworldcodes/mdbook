//
//  BookExport.swift
//  mdbook
//
//  Turns chapters into standalone HTML (one chapter or the whole book in one file, with
//  images embedded) and EPUB 3. PDF and printing go through `PrintRenderer`.
//

import Foundation

nonisolated enum BookExport {
    struct Chapter: Sendable {
        var url: URL
        var title: String
        var markdown: String
    }

    // MARK: HTML

    static let stylesheet = """
    body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 16px; line-height: 1.55; color: #1d1d1f; max-width: 46em; margin: 2em auto; padding: 0 1.5em; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; }
    h1 { font-size: 2em; border-bottom: 1px solid #d2d2d7; padding-bottom: 0.2em; }
    h2 { font-size: 1.5em; border-bottom: 1px solid #e5e5ea; padding-bottom: 0.2em; }
    a { color: #0066cc; }
    code { font-family: "SF Mono", Menlo, monospace; font-size: 0.88em; background: #f2f2f7; padding: 0.1em 0.3em; border-radius: 4px; }
    pre { background: #f5f5f7; padding: 0.9em 1em; border-radius: 8px; overflow-x: auto; line-height: 1.4; }
    pre code { background: none; padding: 0; font-size: 0.85em; }
    blockquote { margin: 1em 0; padding: 0 1em; color: #555; border-left: 3px solid #0066cc; }
    table { border-collapse: collapse; margin: 1em 0; width: 100%; }
    th, td { border: 1px solid #d2d2d7; padding: 0.4em 0.7em; vertical-align: top; }
    th { background: #f5f5f7; }
    img { max-width: 100%; }
    hr { border: none; border-top: 1px solid #d2d2d7; margin: 2em 0; }
    ul.tasks { list-style: none; padding-left: 1.2em; }
    nav.toc ol { line-height: 1.8; }
    section.chapter { page-break-before: always; }
    """

    /// A complete HTML document around `body`.
    static func page(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>\(HTMLRenderer.escape(title))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// One chapter's HTML body, images embedded as data URIs so the file stands alone.
    static func chapterBody(_ chapter: Chapter) -> String {
        var renderer = HTMLRenderer()
        renderer.imageSource = { embeddedImage($0, relativeTo: chapter.url) }
        return renderer.render(chapter.markdown)
    }

    /// The whole book in one HTML body: a contents list, then each chapter in its own
    /// section. Heading ids get a per-chapter prefix and links between chapters become
    /// in-page links, so the file works on its own.
    static func bookBody(title: String, chapters: [Chapter]) -> String {
        let index = Dictionary(chapters.enumerated().map { ($1.url.standardizedFileURL, $0) }, uniquingKeysWith: { first, _ in first })
        var body = "<h1>\(HTMLRenderer.escape(title))</h1>\n<nav class=\"toc\"><ol>\n"
        for (number, chapter) in chapters.enumerated() {
            body += "<li><a href=\"#ch\(number + 1)\">\(HTMLRenderer.escape(chapter.title))</a></li>\n"
        }
        body += "</ol></nav>\n"
        for (number, chapter) in chapters.enumerated() {
            var renderer = HTMLRenderer()
            renderer.idPrefix = "ch\(number + 1)-"
            renderer.imageSource = { embeddedImage($0, relativeTo: chapter.url) }
            renderer.linkTarget = { destination in
                switch LinkResolver.resolve(destination, relativeTo: chapter.url) {
                case .anchor(let name):
                    return "#ch\(number + 1)-\(name)"
                case .file(let url, let fragment):
                    guard let target = index[url.standardizedFileURL] else { return destination }
                    return fragment.map { "#ch\(target + 1)-\($0)" } ?? "#ch\(target + 1)"
                default:
                    return destination
                }
            }
            body += "<section class=\"chapter\" id=\"ch\(number + 1)\">\n\(renderer.render(chapter.markdown))</section>\n"
        }
        return body
    }

    /// A data URI for a local image, or the destination unchanged (remote or missing).
    static func embeddedImage(_ destination: String, relativeTo document: URL) -> String {
        guard case .file(let url, _) = LinkResolver.resolve(destination, relativeTo: document),
              let data = try? Data(contentsOf: url) else { return destination }
        return "data:\(mimeType(for: url.pathExtension));base64,\(data.base64EncodedString())"
    }

    static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "css": "text/css"
        case "xhtml": "application/xhtml+xml"
        default: "application/octet-stream"
        }
    }

    // MARK: EPUB

    /// An EPUB 3 book: one XHTML file per chapter, a navigation document, the stylesheet and
    /// every local image the chapters use.
    static func epub(title: String, chapters: [Chapter], identifier: String = "urn:uuid:\(UUID().uuidString)") -> Data {
        var zip = StoredZip()
        // The mimetype entry must come first and be stored uncompressed.
        zip.add("mimetype", Data("application/epub+zip".utf8))
        zip.add("META-INF/container.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8))
        zip.add("OEBPS/style.css", Data(stylesheet.utf8))

        let index = Dictionary(chapters.enumerated().map { ($1.url.standardizedFileURL, $0) }, uniquingKeysWith: { first, _ in first })
        var images: [URL: String] = [:] // source file → path inside OEBPS
        var manifest = ""
        var spine = ""
        for (number, chapter) in chapters.enumerated() {
            var renderer = HTMLRenderer()
            renderer.imageSource = { destination in
                guard case .file(let url, _) = LinkResolver.resolve(destination, relativeTo: chapter.url),
                      FileManager.default.fileExists(atPath: url.path) else { return destination }
                if let existing = images[url] { return existing }
                let name = "images/image\(images.count + 1).\(url.pathExtension.lowercased())"
                images[url] = name
                return name
            }
            renderer.linkTarget = { destination in
                guard case .file(let url, let fragment) = LinkResolver.resolve(destination, relativeTo: chapter.url),
                      let target = index[url.standardizedFileURL] else { return destination }
                return "chapter\(target + 1).xhtml" + (fragment.map { "#\($0)" } ?? "")
            }
            let xhtml = xhtmlDocument(title: chapter.title, body: renderer.render(chapter.markdown))
            zip.add("OEBPS/chapter\(number + 1).xhtml", Data(xhtml.utf8))
            manifest += "<item id=\"ch\(number + 1)\" href=\"chapter\(number + 1).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"ch\(number + 1)\"/>\n"
        }
        for (source, path) in images.sorted(by: { $0.value < $1.value }) {
            guard let data = try? Data(contentsOf: source) else { continue }
            zip.add("OEBPS/\(path)", data)
            let id = (path as NSString).lastPathComponent.replacingOccurrences(of: ".", with: "-")
            manifest += "<item id=\"\(id)\" href=\"\(path)\" media-type=\"\(mimeType(for: source.pathExtension))\"/>\n"
        }

        var nav = "<nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1><ol>\n"
        for (number, chapter) in chapters.enumerated() {
            nav += "<li><a href=\"chapter\(number + 1).xhtml\">\(HTMLRenderer.escape(chapter.title))</a></li>\n"
        }
        nav += "</ol></nav>"
        zip.add("OEBPS/nav.xhtml", Data(xhtmlDocument(title: "Contents", body: nav).utf8))

        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        zip.add("OEBPS/content.opf", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">\(HTMLRenderer.escape(identifier))</dc:identifier>
            <dc:title>\(HTMLRenderer.escape(title))</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="style.css" media-type="text/css"/>
            \(manifest)
          </manifest>
          <spine>
            \(spine)
          </spine>
        </package>
        """.utf8))
        return zip.data
    }

    /// An XHTML document for EPUB. Raw HTML in the markdown may not be well-formed XML, so
    /// the body is checked and, if needed, tidied into XHTML.
    static func xhtmlDocument(title: String, body: String) -> String {
        var body = body
        if (try? XMLDocument(xmlString: "<div xmlns:epub=\"http://www.idpf.org/2007/ops\">\(body)</div>", options: [])) == nil,
           let tidied = try? XMLDocument(xmlString: "<div>\(body)</div>", options: [.documentTidyHTML]),
           let root = tidied.rootElement() {
            body = (root.children ?? []).map { $0.xmlString }.joined()
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
        <head><meta charset="utf-8"/><title>\(HTMLRenderer.escape(title))</title><link rel="stylesheet" href="style.css"/></head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}

/// A ZIP archive with uncompressed ("stored") entries, which is all EPUB needs.
nonisolated struct StoredZip {
    private var entries = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    mutating func add(_ path: String, _ contents: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(contents)
        let offset = UInt32(entries.count)
        // Local file header.
        entries.append(le32(0x0403_4B50))
        entries.append(le16(20)); entries.append(le16(0x0800)) // version, flags (UTF-8 names)
        entries.append(le16(0)); entries.append(le16(0)); entries.append(le16(0x21)) // stored, time, date (1980-01-01)
        entries.append(le32(crc)); entries.append(le32(UInt32(contents.count))); entries.append(le32(UInt32(contents.count)))
        entries.append(le16(UInt16(name.count))); entries.append(le16(0))
        entries.append(name)
        entries.append(contents)
        // Central directory record.
        directory.append(le32(0x0201_4B50))
        directory.append(le16(20)); directory.append(le16(20)); directory.append(le16(0x0800))
        directory.append(le16(0)); directory.append(le16(0)); directory.append(le16(0x21))
        directory.append(le32(crc)); directory.append(le32(UInt32(contents.count))); directory.append(le32(UInt32(contents.count)))
        directory.append(le16(UInt16(name.count))); directory.append(le16(0)); directory.append(le16(0))
        directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0))
        directory.append(le32(offset))
        directory.append(name)
        count += 1
    }

    var data: Data {
        var archive = entries
        archive.append(directory)
        archive.append(le32(0x0605_4B50))
        archive.append(le16(0)); archive.append(le16(0))
        archive.append(le16(count)); archive.append(le16(count))
        archive.append(le32(UInt32(directory.count))); archive.append(le32(UInt32(entries.count)))
        archive.append(le16(0))
        return archive
    }

    private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

nonisolated enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
