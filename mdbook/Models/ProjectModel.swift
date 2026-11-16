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
    }

    // MARK: Project state

    private(set) var rootURL: URL?
    private(set) var tree: [FileNode] = []
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
                MainActor.assumeIsolated { self?.refreshTree() }
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
        persistBookmark(for: scopeTarget)
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
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.projectBookmark)
        }
    }

    private func preferredEntryFile() -> URL? {
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
        if let selection, FileNode.find(selection, in: tree) == nil {
            // The selected file disappeared from disk.
            self.selection = nil
        }
    }

    // MARK: - Loading and saving

    private func loadSelectedFile() {
        flushPendingSave()
        guard let url = selection else {
            text = ""
            isDirty = false
            return
        }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            text = ""
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
        guard isDirty, let url = selection else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
            errorMessage = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Writes any pending edits for the current file before switching away or quitting.
    func flushPendingSave() {
        if isDirty { saveNow() }
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
        case .anchor:
            // In-document anchors are not yet supported; nothing to navigate to.
            NSSound.beep()
        case .invalid:
            NSSound.beep()
        case .file(var url):
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

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
