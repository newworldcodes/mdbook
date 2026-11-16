//
//  ProjectSidebarView.swift
//  mdbook
//

import SwiftUI

struct ProjectSidebarView: View {
    @Bindable var model: ProjectModel
    /// With a SUMMARY.md the Contents lead and the raw file list starts collapsed.
    @State private var filesExpanded = false

    var body: some View {
        Group {
            if model.rootURL == nil {
                ContentUnavailableView {
                    Label("No Project", systemImage: "folder")
                } description: {
                    Text("Open a folder of markdown files to get started.")
                } actions: {
                    Button("Open Folder…") { model.openFolderPanel() }
                }
            } else if model.tree.isEmpty {
                ContentUnavailableView {
                    Label("No Markdown Files", systemImage: "doc.text")
                } description: {
                    Text("This folder has no markdown files yet.")
                } actions: {
                    Button("New File…") { model.requestNewFile(in: model.rootURL) }
                }
            } else {
                List(selection: $model.selection) {
                    if let summary = model.summary {
                        ForEach(summary.parts) { part in
                            Section {
                                ForEach(part.entries) { entry in
                                    SummaryEntryRow(entry: entry, depth: 0)
                                }
                            } header: {
                                if let title = part.title {
                                    Text(title)
                                } else if part.id == 0 {
                                    Text("Contents")
                                }
                            }
                        }
                        Section("Files", isExpanded: $filesExpanded) {
                            fileRows
                        }
                    } else {
                        fileRows
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.rootURL != nil {
                HStack {
                    Button {
                        model.requestNewFile()
                    } label: {
                        Label("New File", systemImage: "square.and.pencil")
                    }
                    .help("Create a new markdown file")
                    Spacer()
                    Button {
                        model.refreshTree()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Rescan the project folder")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(8)
                .background(.bar)
            }
        }
    }
}

extension ProjectSidebarView {
    private var fileRows: some View {
        ForEach(model.tree) { node in
            FileNodeRow(node: node, model: model)
        }
    }
}

/// A chapter from SUMMARY.md; nested chapters are indented below it. Drafts (no file
/// yet) are shown dimmed and can't be selected.
struct SummaryEntryRow: View {
    let entry: BookSummary.Entry
    let depth: Int

    var body: some View {
        Group {
            if let url = entry.url {
                Label(entry.title, systemImage: "doc.text")
                    .tag(url)
            } else {
                Label(entry.title, systemImage: "doc.badge.ellipsis")
                    .foregroundStyle(.secondary)
                    .help("Draft chapter: no file yet")
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        ForEach(entry.children) { child in
            SummaryEntryRow(entry: child, depth: depth + 1)
        }
    }
}

/// A file or folder row; folders recurse into their children.
struct FileNodeRow: View {
    let node: FileNode
    @Bindable var model: ProjectModel

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(node.children ?? []) { child in
                    FileNodeRow(node: child, model: model)
                }
            } label: {
                Label(node.name, systemImage: "folder")
            }
            .contextMenu {
                Button("New File Here…") { model.requestNewFile(in: node.url) }
                Button("Rename…") { model.requestRename(node) }
                Button("Reveal in Finder") { model.revealInFinder(node.url) }
                Divider()
                Button("Move to Trash", role: .destructive) { model.nodePendingDeletion = node }
            }
        } else {
            Label(node.name, systemImage: "doc.text")
                .tag(node.url)
                .contextMenu {
                    Button("Rename…") { model.requestRename(node) }
                    Button("Reveal in Finder") { model.revealInFinder(node.url) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { model.nodePendingDeletion = node }
                }
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { model.expandedFolders.contains(node.url) },
            set: { expanded in
                if expanded {
                    model.expandedFolders.insert(node.url)
                } else {
                    model.expandedFolders.remove(node.url)
                }
            }
        )
    }
}
