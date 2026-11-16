//
//  FileNode.swift
//  mdbook
//

import Foundation

/// A node in the project tree: either a markdown file or a folder that
/// (transitively) contains markdown files.
nonisolated struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    var id: URL { url }

    /// File extensions treated as markdown documents.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "txt"]

    /// Folder names that are never worth showing in a book/project.
    static let ignoredDirectoryNames: Set<String> = ["node_modules", ".git", ".build", "DerivedData"]

    static func isMarkdownFile(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Builds the tree of markdown files below `root`. Folders without any
    /// markdown descendants are pruned so the sidebar only shows useful entries.
    static func buildTree(at root: URL) -> [FileNode] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .nameKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var nodes: [FileNode] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.name ?? url.lastPathComponent
            if values?.isDirectory == true {
                guard !ignoredDirectoryNames.contains(name) else { continue }
                let children = buildTree(at: url)
                guard !children.isEmpty else { continue }
                nodes.append(FileNode(url: url.standardizedFileURL, name: name, isDirectory: true, children: children))
            } else if isMarkdownFile(url) {
                nodes.append(FileNode(url: url.standardizedFileURL, name: name, isDirectory: false, children: nil))
            }
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Depth-first search for the node with the given URL.
    static func find(_ url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url == url { return node }
            if let children = node.children, let found = find(url, in: children) {
                return found
            }
        }
        return nil
    }

    /// URLs of every folder on the path from the root to `url` (excluding the file itself).
    static func ancestorFolders(of url: URL, in nodes: [FileNode]) -> [URL] {
        for node in nodes {
            if node.url == url { return [] }
            if let children = node.children, FileNode.find(url, in: children) != nil {
                return [node.url] + ancestorFolders(of: url, in: children)
            }
        }
        return []
    }
}
