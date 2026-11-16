//
//  ContentView.swift
//  mdbook
//

import SwiftUI

struct ContentView: View {
    @Environment(ProjectModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
        } detail: {
            DocumentAreaView(model: model)
                .environment(\.markdownTextScale, settings.scale)
                .environment(\.markdownFontDesign, settings.font.fontDesign)
        }
        .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "Search Project")
        .searchFocused($isSearchFocused)
        .onChange(of: model.searchFocusRequest) { _, _ in
            columnVisibility = .all
            isSearchFocused = true
        }
        .navigationTitle(model.selectedFileName ?? model.projectName ?? "mdbook")
        .navigationSubtitle(model.selectedFileName == nil ? "" : (model.projectName ?? ""))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!model.canGoBack)
                .help("Go back")

                Button {
                    model.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!model.canGoForward)
                .help("Go forward")
            }

            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.goToPreviousChapter()
                } label: {
                    Label("Previous Chapter", systemImage: "arrow.up.doc")
                }
                .disabled(model.previousChapter == nil)
                .help(model.previousChapter.map { "Previous chapter: \($0.title)" } ?? "No previous chapter")

                Button {
                    model.goToNextChapter()
                } label: {
                    Label("Next Chapter", systemImage: "arrow.down.doc")
                }
                .disabled(model.nextChapter == nil)
                .help(model.nextChapter.map { "Next chapter: \($0.title)" } ?? "No next chapter")
            }

            ToolbarItem(placement: .principal) {
                Picker("Layout", selection: $model.layout) {
                    ForEach(EditorLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.systemImage)
                            .tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Switch between the in-place editor and source/preview panes")
            }

            ToolbarItem(placement: .automatic) {
                if model.selection != nil {
                    Menu {
                        ForEach(model.outline) { entry in
                            Button {
                                model.jump(to: entry)
                            } label: {
                                Text(String(repeating: "    ", count: max(0, entry.level - 1)) + entry.title)
                            }
                        }
                    } label: {
                        Label("Outline", systemImage: "list.bullet.indent")
                    }
                    .disabled(model.outline.isEmpty)
                    .help("Jump to a heading in this document")
                }
            }

            ToolbarItem(placement: .automatic) {
                if model.selection != nil {
                    Text("\(model.wordCount.formatted()) words · \(model.readingMinutes) min")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Word count and reading time for this chapter")
                }
            }

            ToolbarItem(placement: .automatic) {
                if model.selection != nil {
                    Text(model.isDirty ? "Unsaved" : "Saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 50)
                        .accessibilityLabel(model.isDirty ? "Unsaved changes" : "All changes saved")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    model.openFolderPanel()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open a folder as a project")
            }
        }
        .modifier(ProjectAlerts(model: model))
        .task {
            model.restoreLastProject()
        }
    }

}

/// The project's alerts and confirmations: external changes, errors, new file, rename, delete.
struct ProjectAlerts: ViewModifier {
    @Bindable var model: ProjectModel

    func body(content: Content) -> some View {
        content
            .alert(
                "\u{201C}\(model.externalChange?.lastPathComponent ?? "")\u{201D} Changed on Disk",
                isPresented: externalChangeBinding
            ) {
                Button("Keep My Version") { model.resolveExternalChange(keepMine: true) }
                Button("Reload from Disk", role: .destructive) { model.resolveExternalChange(keepMine: false) }
            } message: {
                Text("Another app changed this file while you had unsaved edits. Keeping your version overwrites theirs; reloading discards your edits.")
            }
            .alert("Something Went Wrong", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert("New File", isPresented: newFileBinding) {
                TextField("Name", text: $model.newFileName)
                Button("Create") { model.createRequestedFile() }
                Button("Cancel", role: .cancel) { model.newFileFolder = nil }
            } message: {
                Text("Enter a name for the new markdown file.")
            }
            .alert("Rename", isPresented: renameBinding) {
                TextField("Name", text: $model.renameName)
                Button("Rename") { model.renamePendingNode() }
                Button("Cancel", role: .cancel) { model.nodePendingRename = nil }
            } message: {
                Text("Enter a new name for \u{201C}\(model.nodePendingRename?.name ?? "")\u{201D}.")
            }
            .confirmationDialog(
                "Move \u{201C}\(model.nodePendingDeletion?.name ?? "")\u{201D} to the Trash?",
                isPresented: deleteBinding,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) { model.deletePendingNode() }
                Button("Cancel", role: .cancel) { model.nodePendingDeletion = nil }
            } message: {
                Text("You can restore it from the Trash later.")
            }
    }

    private var externalChangeBinding: Binding<Bool> {
        Binding(
            get: { model.externalChange != nil },
            // Dismissing without choosing keeps the edits but leaves saving paused until the
            // next change on disk or file switch; treat it as "keep mine" instead.
            set: { if !$0, model.externalChange != nil { model.resolveExternalChange(keepMine: true) } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var newFileBinding: Binding<Bool> {
        Binding(
            get: { model.newFileFolder != nil },
            set: { if !$0 { model.newFileFolder = nil } }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { model.nodePendingRename != nil },
            set: { if !$0 { model.nodePendingRename = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { model.nodePendingDeletion != nil },
            set: { if !$0 { model.nodePendingDeletion = nil } }
        )
    }
}

/// The detail column: WYSIWYG editor or source + preview split.
struct DocumentAreaView: View {
    @Bindable var model: ProjectModel
    @Environment(AppSettings.self) private var settings
    @State private var sourceScrollFraction: Double?

    var body: some View {
        if let selection = model.selection {
            Group {
                switch model.layout {
                case .wysiwyg:
                    MarkdownEditorView(
                        text: textBinding,
                        mode: .wysiwyg,
                        onOpenLink: model.open(linkDestination:),
                        documentURL: selection,
                        projectFiles: model.treeFiles,
                        textScale: settings.scale,
                        readingFont: settings.font,
                        focusMode: settings.focusMode,
                        typewriterMode: settings.typewriterMode,
                        anchorRequest: model.pendingAnchor,
                        revealRequest: model.pendingReveal
                    )
                case .split:
                    HSplitView {
                        MarkdownEditorView(
                            text: textBinding,
                            mode: .source,
                            onOpenLink: model.open(linkDestination:),
                            documentURL: selection,
                            projectFiles: model.treeFiles,
                            textScale: settings.scale,
                            typewriterMode: settings.typewriterMode,
                            anchorRequest: model.pendingAnchor,
                            revealRequest: model.pendingReveal,
                            onScroll: { sourceScrollFraction = $0 }
                        )
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                        MarkdownPreviewView(
                            text: model.text,
                            documentURL: selection,
                            onOpenLink: model.open(linkDestination:),
                            anchorRequest: model.pendingAnchor,
                            scrollFraction: sourceScrollFraction,
                            previousChapter: model.previousChapter,
                            nextChapter: model.nextChapter,
                            onOpenChapter: model.navigate(to:)
                        )
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .id(selection)
        } else if model.rootURL == nil {
            ContentUnavailableView {
                Label("Welcome to mdbook", systemImage: "book")
            } description: {
                Text("Open a folder to read and edit its markdown files as a book.")
            } actions: {
                Button("Open Folder…") { model.openFolderPanel() }
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            ContentUnavailableView("No Document Selected", systemImage: "doc.text", description: Text("Choose a file in the sidebar."))
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { model.text },
            set: { model.updateText($0) }
        )
    }
}

#Preview {
    ContentView()
        .environment(ProjectModel())
        .environment(AppSettings())
}
