//
//  ProjectModel.swift
//  mdbook
//

import AppKit
import SwiftUI

/// How the document area is laid out.
enum EditorLayout: String, CaseIterable, Identifiable {
    /// A single pane that edits the markdown in place with live styling.
    case wysiwyg
    /// Markdown source on the left, rendered preview on the right.
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wysiwyg: return "Editor"
        case .split: return "Source and Preview"
        }
    }

    var systemImage: String {
        switch self {
        case .wysiwyg: return "doc.richtext"
        case .split: return "rectangle.split.2x1"
        }
    }
}

/// The open project (a folder of markdown files) and the document being edited.
@Observable
final class ProjectModel {
    private enum DefaultsKey {
        static let projectBookmark = "lastProjectBookmark"
        static let layout = "editorLayout"
        static let recentProjects = "recentProjects"
    }

    // MARK: Project state

    private(set) var rootURL: URL?
    private(set) var tree: [FileNode] = []
    /// The book's table of contents, when the project has a SUMMARY.md.
    private(set) var summary: BookSummary?
    private(set) var summaryURL: URL?
    var expandedFolders: Set<URL> = []

    /// Bound to the sidebar list. Changing it loads the file and records history
    /// (unless the change itself came from back/forward navigation).
    var selection: URL? {
        didSet {
            guard selection != oldValue else { return }
            if !isTraversingHistory, let previous = oldValue {
                backStack.append(previous)
                forwardStack.removeAll()
            }
            loadSelectedFile()
        }
    }

    // MARK: Document state

    private(set) var text: String = ""
    private(set) var isDirty = false
    /// The open file's contents as last read from or written to disk, to tell our own saves
    /// apart from changes made by other apps.
    @ObservationIgnored private var diskText: String?
    /// The open file's encoding, kept when saving.
    private(set) var fileEncoding: String.Encoding = .utf8
    /// Set when the open file changed on disk while there are unsaved edits; saving pauses
    /// until the user picks a version.
    private(set) var externalChange: URL?
    private(set) var lastSaveError: String?

    var layout: EditorLayout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: DefaultsKey.layout) }
    }

    var errorMessage: String?

    /// Set when the user asks for a new file; drives the name prompt.
    var newFileFolder: URL?
    var newFileName: String = ""

    /// Set when the user asks to delete a node; drives the confirmation dialog.
    var nodePendingDeletion: FileNode?

    /// Set when the user asks to rename a node; drives the rename prompt.
    var nodePendingRename: FileNode?
    var renameName: String = ""

    /// The heading the editor and preview should scroll to (from a `#anchor` link).
    private(set) var pendingAnchor: AnchorRequest?
    /// A range to select in the editor once the file is open (from a search result).
    private(set) var pendingReveal: RevealRequest?

    // MARK: Search

    var searchQuery = "" {
        didSet { if searchQuery != oldValue { scheduleSearch() } }
    }
    private(set) var searchResults: [ProjectSearch.FileResult] = []
    private(set) var isSearching = false
    /// Bumped by Find in Project; the window focuses its search field when it changes.
    private(set) var searchFocusRequest = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    private var watcher: FolderWatcher?

    // MARK: Navigation history

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var isTraversingHistory = false
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    private var saveTask: Task<Void, Never>?
    private var securityScopedRoot: URL?

    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        let stored = UserDefaults.standard.string(forKey: DefaultsKey.layout)
        layout = stored.flatMap(EditorLayout.init(rawValue:)) ?? .wysiwyg

        // Flush edits when the app quits or goes to the background, and pick up
        // files changed by other apps when it comes back.
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingSave() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingSave() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.folderDidChangeOnDisk() }
            },
        ]
    }

    var projectName: String? { rootURL?.lastPathComponent }
    var selectedFileName: String? { selection?.lastPathComponent }

    // MARK: - Opening projects

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a folder containing markdown files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        guard url.standardizedFileURL != rootURL || standaloneFile != nil else { return }
        beginProject(rootedAt: url, standaloneFile: nil)
        refreshTree()
        expandedFolders = Set(tree.filter(\.isDirectory).map(\.url))

        // Open the most obvious entry point so the reader is immediately useful.
        if let entry = preferredEntryFile() {
            selection = entry
        }
    }

    /// Opens a single markdown file (for example from Finder). The sandbox only grants
    /// access to that file, so the sidebar shows it on its own rather than its folder.
    func openFile(at url: URL) {
        let standardized = url.standardizedFileURL
        if standaloneFile == nil, let rootURL, standardized.path.hasPrefix(rootURL.path + "/"),
           FileNode.find(standardized, in: tree) != nil {
            navigate(to: standardized)
            return
        }
        beginProject(rootedAt: standardized.deletingLastPathComponent(), standaloneFile: standardized)
        refreshTree()
        selection = standardized
    }

    /// When set, the project is a single file opened on its own.
    private var standaloneFile: URL?

    private func beginProject(rootedAt url: URL, standaloneFile file: URL?) {
        flushPendingSave()
        securityScopedRoot?.stopAccessingSecurityScopedResource()
        let scopeTarget = file ?? url
        securityScopedRoot = scopeTarget.startAccessingSecurityScopedResource() ? scopeTarget : nil

        rootURL = url.standardizedFileURL
        standaloneFile = file
        selection = nil
        backStack = []
        forwardStack = []
        text = ""
        isDirty = false
        pendingAnchor = nil
        persistBookmark(for: scopeTarget)
        watcher = nil
        if file == nil {
            startWatching(url)
        }
    }

    /// Reopens the folder or file from the previous session, if the sandbox lets us.
    func restoreLastProject() {
        guard rootURL == nil,
              let data = UserDefaults.standard.data(forKey: DefaultsKey.projectBookmark) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.projectBookmark)
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            openProject(at: url)
        } else {
            openFile(at: url)
        }
    }

    private func persistBookmark(for url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.projectBookmark)
            rememberRecentProject(url, bookmark: data)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.projectBookmark)
        }
    }

    // MARK: - Recent projects

    struct RecentProject: Codable, Identifiable, Equatable {
        var name: String
        var path: String
        var bookmark: Data
        var id: String { path }
    }

    /// Folders and files opened before, newest first (File ▸ Open Recent).
    private(set) var recentProjects: [RecentProject] = {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.recentProjects) else { return [] }
        return (try? JSONDecoder().decode([RecentProject].self, from: data)) ?? []
    }()

    private func rememberRecentProject(_ url: URL, bookmark: Data) {
        let entry = RecentProject(name: url.lastPathComponent, path: url.path, bookmark: bookmark)
        recentProjects = Array(([entry] + recentProjects.filter { $0.path != entry.path }).prefix(10))
        saveRecentProjects()
    }

    private func saveRecentProjects() {
        if let data = try? JSONEncoder().encode(recentProjects) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.recentProjects)
        }
    }

    func openRecentProject(_ project: RecentProject) {
        var isStale = false
        var isDirectory: ObjCBool = false
        guard let url = try? URL(resolvingBookmarkData: project.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            recentProjects.removeAll { $0.path == project.path }
            saveRecentProjects()
            errorMessage = "\u{201C}\(project.name)\u{201D} can't be found. It may have been moved or deleted."
            return
        }
        if isDirectory.boolValue {
            openProject(at: url)
        } else {
            openFile(at: url)
        }
    }

    func clearRecentProjects() {
        recentProjects = []
        saveRecentProjects()
    }

    private func preferredEntryFile() -> URL? {
        if summary != nil, let first = readingOrder.first { return first }
        let preferredNames = ["readme.md", "summary.md", "index.md"]
        for name in preferredNames {
            if let node = tree.first(where: { !$0.isDirectory && $0.name.lowercased() == name }) {
                return node.url
            }
        }
        return tree.first(where: { !$0.isDirectory })?.url
    }

    func refreshTree() {
        guard let rootURL else { tree = []; return }
        if let standaloneFile {
            tree = FileManager.default.fileExists(atPath: standaloneFile.path)
                ? [FileNode(url: standaloneFile, name: standaloneFile.lastPathComponent, isDirectory: false, children: nil)]
                : []
        } else {
            tree = FileNode.buildTree(at: rootURL)
        }
        reloadSummary()
        if let selection, FileNode.find(selection, in: tree) == nil {
            // The selected file disappeared from disk.
            self.selection = nil
        }
    }

    private func reloadSummary() {
        guard let rootURL, standaloneFile == nil, let url = BookSummary.locate(in: rootURL),
              let source = try? TextFile.read(url).text else {
            summary = nil
            summaryURL = nil
            return
        }
        let parsed = BookSummary.parse(source, relativeTo: url)
        if summaryURL != url { summaryURL = url }
        if parsed != summary { summary = parsed }
    }

    // MARK: - Chapters

    /// Every markdown file in sidebar order.
    var treeFiles: [URL] {
        func flatten(_ nodes: [FileNode]) -> [URL] {
            nodes.flatMap { $0.isDirectory ? flatten($0.children ?? []) : [$0.url] }
        }
        return flatten(tree)
    }

    /// The order chapters are read in: the summary's, or the sidebar's when there isn't one.
    var readingOrder: [URL] {
        let files = treeFiles
        guard let summary else { return files }
        let existing = Set(files)
        let order = summary.readingOrder.filter(existing.contains)
        return order.isEmpty ? files : order
    }

    /// What the summary calls a chapter, else its file name without the extension.
    func chapterTitle(for url: URL) -> String {
        summary?.title(for: url) ?? url.deletingPathExtension().lastPathComponent
    }

    var previousChapter: ChapterLink? { chapter(offsetBy: -1) }
    var nextChapter: ChapterLink? { chapter(offsetBy: 1) }

    private func chapter(offsetBy offset: Int) -> ChapterLink? {
        guard let selection else { return nil }
        let order = readingOrder
        guard let index = order.firstIndex(of: selection), order.indices.contains(index + offset) else { return nil }
        let url = order[index + offset]
        return ChapterLink(title: chapterTitle(for: url), url: url)
    }

    func goToPreviousChapter() {
        if let previousChapter { navigate(to: previousChapter.url) }
    }

    func goToNextChapter() {
        if let nextChapter { navigate(to: nextChapter.url) }
    }

    // MARK: - Export

    /// The book's title from `book.toml`, else the folder name.
    var bookTitle: String {
        if let rootURL, let toml = try? TextFile.read(rootURL.appendingPathComponent("book.toml")).text,
           let title = BookSummary.bookValue("title", inBookTOML: toml) {
            return title
        }
        return projectName ?? "Book"
    }

    private var currentChapter: BookExport.Chapter? {
        guard let selection else { return nil }
        return BookExport.Chapter(url: selection, title: chapterTitle(for: selection), markdown: text)
    }

    /// Every chapter in reading order; the open one as edited.
    private var allChapters: [BookExport.Chapter] {
        readingOrder.compactMap { url in
            let markdown = url == selection ? text : (try? TextFile.read(url).text)
            return markdown.map { BookExport.Chapter(url: url, title: chapterTitle(for: url), markdown: $0) }
        }
    }

    enum ExportFormat {
        case html, pdf, epub

        var fileExtension: String {
            switch self {
            case .html: "html"
            case .pdf: "pdf"
            case .epub: "epub"
            }
        }
    }

    var canExport: Bool { selection != nil }

    func exportChapter(as format: ExportFormat) {
        guard let chapter = currentChapter else { return }
        let html = BookExport.page(title: chapter.title, body: BookExport.chapterBody(chapter))
        guard let url = savePanel(name: chapter.url.deletingPathExtension().lastPathComponent, format: format) else { return }
        write(format == .pdf ? nil : Data(html.utf8), pdfHTML: format == .pdf ? html : nil, to: url)
    }

    func exportBook(as format: ExportFormat) {
        let chapters = allChapters
        guard !chapters.isEmpty, let url = savePanel(name: bookTitle, format: format) else { return }
        switch format {
        case .epub:
            write(BookExport.epub(title: bookTitle, chapters: chapters), pdfHTML: nil, to: url)
        case .html, .pdf:
            let html = BookExport.page(title: bookTitle, body: BookExport.bookBody(title: bookTitle, chapters: chapters))
            write(format == .pdf ? nil : Data(html.utf8), pdfHTML: format == .pdf ? html : nil, to: url)
        }
    }

    func printChapter() {
        guard let chapter = currentChapter else { return }
        let html = BookExport.page(title: chapter.title, body: BookExport.chapterBody(chapter))
        PrintRenderer.print(html: html, title: chapter.title, window: NSApp.keyWindow)
    }

    private func savePanel(name: String, format: ExportFormat) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func write(_ data: Data?, pdfHTML: String?, to url: URL) {
        if let pdfHTML {
            if !PrintRenderer.exportPDF(html: pdfHTML, to: url) {
                errorMessage = "Couldn't create the PDF."
            }
            return
        }
        do {
            try data?.write(to: url, options: .atomic)
        } catch {
            errorMessage = "Couldn't export to \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Search

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    /// Reading order first, then any files the summary doesn't list.
    private var searchFiles: [URL] {
        let order = readingOrder
        let listed = Set(order)
        return order + treeFiles.filter { !listed.contains($0) }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        // The open file is searched as edited, not as last saved.
        let files = searchFiles.map { (url: $0, text: $0 == selection ? text : nil) }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                ProjectSearch.search(query, in: files)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.searchResults = results
            self.isSearching = false
        }
    }

    func openSearchResult(_ url: URL, match: ProjectSearch.Match) {
        navigate(to: url)
        pendingReveal = RevealRequest(range: match.range)
    }

    // MARK: - Loading and saving

    private func loadSelectedFile() {
        flushPendingSave()
        externalChange = nil
        guard let url = selection else {
            text = ""
            diskText = nil
            isDirty = false
            return
        }
        do {
            let file = try TextFile.read(url)
            text = file.text
            fileEncoding = file.encoding
            diskText = file.text
        } catch {
            text = ""
            diskText = nil
            fileEncoding = .utf8
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
        isDirty = false
        lastSaveError = nil
        revealInSidebar(url)
    }

    /// Called by the editor on every change. Saves are debounced so typing stays cheap.
    func updateText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, let url = selection, externalChange == nil else { return }
        // Never overwrite a change another app made since we last read or wrote the file.
        if let onDisk = try? TextFile.read(url).text, let diskText, onDisk != diskText {
            externalChange = url
            return
        }
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            let used = try TextFile.write(text, to: url, encoding: fileEncoding)
            if used != fileEncoding {
                errorMessage = "\(url.lastPathComponent) was saved as UTF-8 because its original encoding can't represent some of the new text."
                fileEncoding = used
            }
            diskText = text
            isDirty = false
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
            errorMessage = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Writes any pending edits for the current file before switching away or quitting.
    /// If the file changed on disk meanwhile, the edits go to a conflicted copy beside it
    /// rather than being lost or overwriting the other change.
    func flushPendingSave() {
        guard isDirty else { return }
        saveNow()
        guard let url = externalChange, url == selection else { return }
        let copy = url.deletingPathExtension()
            .appendingPathExtension("conflicted copy")
            .appendingPathExtension(url.pathExtension)
        if (try? TextFile.write(text, to: copy, encoding: fileEncoding)) != nil {
            errorMessage = "\(url.lastPathComponent) changed on disk while you had unsaved edits. Your version was saved as \(copy.lastPathComponent)."
        } else {
            errorMessage = "\(url.lastPathComponent) changed on disk and your unsaved edits couldn't be saved."
        }
        externalChange = nil
        isDirty = false
    }

    // MARK: - Navigation

    /// Selects a file; the selection observer records it in the history.
    func navigate(to url: URL) {
        selection = url.standardizedFileURL
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = selection { forwardStack.append(current) }
        isTraversingHistory = true
        selection = previous
        isTraversingHistory = false
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = selection { backStack.append(current) }
        isTraversingHistory = true
        selection = next
        isTraversingHistory = false
    }

    /// Opens a markdown link: markdown files inside the project open in the app,
    /// everything else goes to the system.
    func open(linkDestination: String) {
        switch LinkResolver.resolve(linkDestination, relativeTo: selection) {
        case .external(let url):
            NSWorkspace.shared.open(url)
        case .anchor(let name):
            pendingAnchor = AnchorRequest(anchor: name)
        case .invalid:
            NSSound.beep()
        case .file(var url, let fragment):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                errorMessage = "The linked file doesn't exist:\n\(url.path)"
                return
            }
            if isDirectory.boolValue {
                guard let index = ["README.md", "index.md", "SUMMARY.md"]
                    .map({ url.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                    NSWorkspace.shared.open(url)
                    return
                }
                url = index
            }
            if FileNode.isMarkdownFile(url), isInsideProject(url) {
                if FileNode.find(url, in: tree) == nil { refreshTree() }
                navigate(to: url)
                if let fragment {
                    pendingAnchor = AnchorRequest(anchor: fragment)
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func isInsideProject(_ url: URL) -> Bool {
        guard let rootURL else { return false }
        return url.standardizedFileURL.path.hasPrefix(rootURL.path + "/")
    }

    private func revealInSidebar(_ url: URL) {
        for folder in FileNode.ancestorFolders(of: url, in: tree) {
            expandedFolders.insert(folder)
        }
    }

    // MARK: - File operations

    func requestNewFile(in folder: URL? = nil) {
        guard let target = folder ?? selection?.deletingLastPathComponent() ?? rootURL else { return }
        newFileName = "Untitled"
        newFileFolder = target
    }

    func createRequestedFile() {
        guard let folder = newFileFolder else { return }
        newFileFolder = nil
        var name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !FileNode.isMarkdownFile(URL(fileURLWithPath: name)) { name += ".md" }
        let url = folder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "A file named \(name) already exists."
            return
        }
        let title = url.deletingPathExtension().lastPathComponent
        do {
            try "# \(title)\n\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't create \(name): \(error.localizedDescription)"
            return
        }
        refreshTree()
        expandedFolders.insert(folder)
        navigate(to: url)
    }

    func deletePendingNode() {
        guard let node = nodePendingDeletion else { return }
        nodePendingDeletion = nil
        if let selection, selection == node.url || selection.path.hasPrefix(node.url.path + "/") {
            flushPendingSave()
            self.selection = nil
        }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            errorMessage = "Couldn't delete \(node.name): \(error.localizedDescription)"
        }
        refreshTree()
    }

    func requestRename(_ node: FileNode) {
        renameName = node.isDirectory ? node.name : node.url.deletingPathExtension().lastPathComponent
        nodePendingRename = node
    }

    func renamePendingNode() {
        guard let node = nodePendingRename else { return }
        nodePendingRename = nil
        var name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }
        if !node.isDirectory, !FileNode.isMarkdownFile(URL(fileURLWithPath: name)) {
            name += "." + (node.url.pathExtension.isEmpty ? "md" : node.url.pathExtension)
        }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        guard destination != node.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "Something named \(name) already exists."
            return
        }

        flushPendingSave()
        do {
            try FileManager.default.moveItem(at: node.url, to: destination)
        } catch {
            errorMessage = "Couldn't rename \(node.name): \(error.localizedDescription)"
            return
        }

        // Keep the selection and history pointing at the moved item(s).
        let remap: (URL) -> URL = { url in
            if url == node.url { return destination }
            if node.isDirectory, url.path.hasPrefix(node.url.path + "/") {
                let suffix = url.path.dropFirst(node.url.path.count)
                return URL(fileURLWithPath: destination.path + suffix)
            }
            return url
        }
        backStack = backStack.map(remap)
        forwardStack = forwardStack.map(remap)
        if node.isDirectory {
            expandedFolders = Set(expandedFolders.map(remap))
        }
        refreshTree()
        if let selection, remap(selection) != selection {
            isTraversingHistory = true
            self.selection = remap(selection)
            isTraversingHistory = false
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Outline

    struct OutlineEntry: Identifiable, Hashable {
        let id: Int
        let level: Int
        let title: String
    }

    @ObservationIgnored private var statisticsCache: (text: String, words: Int)?

    /// Words in the open document (markdown syntax isn't counted as words).
    var wordCount: Int {
        if let statisticsCache, statisticsCache.text == text { return statisticsCache.words }
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        statisticsCache = (text, words)
        return words
    }

    /// Reading time in minutes at 230 words a minute, at least one.
    var readingMinutes: Int { max(1, Int((Double(wordCount) / 230).rounded())) }

    @ObservationIgnored private var outlineCache: (text: String, entries: [OutlineEntry])?

    /// Headings of the current document, for the Outline menu.
    var outline: [OutlineEntry] {
        if let outlineCache, outlineCache.text == text { return outlineCache.entries }
        let ns = text as NSString
        let entries = MarkdownHighlighter.scan(text).headings
            .sorted { $0.line.location < $1.line.location }
            .enumerated()
            .map { index, heading in
                let title = HeadingSlug.plainText(ofHeadingSource: ns.substring(with: heading.content))
                return OutlineEntry(id: index, level: heading.level, title: title.isEmpty ? "Untitled" : title)
            }
        outlineCache = (text, entries)
        return entries
    }

    func jump(to entry: OutlineEntry) {
        pendingAnchor = AnchorRequest(anchor: HeadingSlug.slug(for: entry.title))
    }

    // MARK: - Watching the folder

    private func startWatching(_ url: URL) {
        watcher = FolderWatcher(url: url) { [weak self] in
            self?.folderDidChangeOnDisk()
        }
    }

    private func folderDidChangeOnDisk() {
        refreshTree()
        reloadCurrentFileIfChangedOnDisk()
    }

    /// Picks up edits made by other apps. With unsaved edits of our own, asks which to keep.
    private func reloadCurrentFileIfChangedOnDisk() {
        guard let url = selection, let onDisk = try? TextFile.read(url).text,
              onDisk != diskText else { return }
        if isDirty, onDisk != text {
            externalChange = url
        } else {
            text = onDisk
            diskText = onDisk
            isDirty = false
        }
    }

    /// Resolves an external change: keep the edits here (overwriting the file) or take the
    /// version on disk (discarding them).
    func resolveExternalChange(keepMine: Bool) {
        guard let url = externalChange, url == selection else {
            externalChange = nil
            return
        }
        externalChange = nil
        if keepMine {
            write(to: url)
        } else if let file = try? TextFile.read(url) {
            text = file.text
            fileEncoding = file.encoding
            diskText = file.text
            isDirty = false
        }
    }
}

/// A request to select (and scroll to) a range of the open file.
struct RevealRequest: Equatable {
    let id = UUID()
    let range: NSRange
}

/// A neighbouring chapter in the reading order.
struct ChapterLink: Equatable {
    let title: String
    let url: URL
}

/// A request to scroll to a heading. Each request has its own identity so the same
/// anchor can be followed twice in a row.
struct AnchorRequest: Equatable {
    let id = UUID()
    let anchor: String
}
