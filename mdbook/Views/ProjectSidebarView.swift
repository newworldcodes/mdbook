//
//  ProjectSidebarView.swift
//  mdbook
//

import SwiftUI

struct ProjectSidebarView: View {
    @Bindable var model: ProjectModel

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
                    ForEach(model.tree) { node in
                        FileNodeRow(node: node, model: model)
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
