//
//  mdbookApp.swift
//  mdbook
//

import AppKit
import SwiftUI

@main
struct mdbookApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    private var model: ProjectModel { appDelegate.model }
    private var settings: AppSettings { appDelegate.settings }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(settings)
                .frame(minWidth: 700, minHeight: 400)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New File…") { model.requestNewFile() }
                    .keyboardShortcut("n")
                    .disabled(model.rootURL == nil)
                Button("Open Folder…") { model.openFolderPanel() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.recentProjects) { project in
                        Button(project.name) { model.openRecentProject(project) }
                    }
                    Divider()
                    Button("Clear Menu") { model.clearRecentProjects() }
                }
                .disabled(model.recentProjects.isEmpty)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveNow() }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty)
                Divider()
                Menu("Export Chapter") {
                    Button("HTML…") { model.exportChapter(as: .html) }
                    Button("PDF…") { model.exportChapter(as: .pdf) }
                }
                .disabled(!model.canExport)
                Menu("Export Book") {
                    Button("HTML…") { model.exportBook(as: .html) }
                    Button("PDF…") { model.exportBook(as: .pdf) }
                    Button("EPUB…") { model.exportBook(as: .epub) }
                }
                .disabled(!model.canExport)
            }

            CommandGroup(replacing: .printItem) {
                Button("Print…") { model.printChapter() }
                    .keyboardShortcut("p")
                    .disabled(!model.canExport)
            }

            CommandGroup(replacing: .textFormatting) {
                Button("Bold") { send(#selector(MarkdownTextView.toggleBoldMarkdown(_:))) }
                    .keyboardShortcut("b")
                Button("Italic") { send(#selector(MarkdownTextView.toggleItalicMarkdown(_:))) }
                    .keyboardShortcut("i")
                Button("Strikethrough") { send(#selector(MarkdownTextView.toggleStrikethroughMarkdown(_:))) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Inline Code") { send(#selector(MarkdownTextView.toggleInlineCodeMarkdown(_:))) }
                    .keyboardShortcut("e")
                Divider()
                Button("Cycle Heading Level") { send(#selector(MarkdownTextView.toggleHeadingMarkdown(_:))) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Add Link") { send(#selector(MarkdownTextView.insertLinkMarkdown(_:))) }
                    .keyboardShortcut("k")
                Divider()
                Button("Insert Table") { send(#selector(MarkdownTextView.insertTableMarkdown(_:))) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Align Table Columns") { send(#selector(MarkdownTextView.formatTableMarkdown(_:))) }
                    .keyboardShortcut("t", modifiers: [.command, .option, .shift])
            }

            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(EditorLayout.allCases.enumerated()), id: \.element) { index, layout in
                    Button(layout.title) { model.layout = layout }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("Zoom In") { settings.zoomIn() }
                    .keyboardShortcut("+")
                    .disabled(!settings.canZoomIn)
                Button("Zoom Out") { settings.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(!settings.canZoomOut)
                Button("Actual Size") { settings.resetZoom() }
                    .keyboardShortcut("0")
                    .disabled(settings.textSize == AppSettings.defaultTextSize)
                Divider()
                Toggle("Focus Mode", isOn: Binding(get: { settings.focusMode }, set: { settings.focusMode = $0 }))
                Toggle("Typewriter Mode", isOn: Binding(get: { settings.typewriterMode }, set: { settings.typewriterMode = $0 }))
                Divider()
            }

            CommandGroup(after: .pasteboard) {
                Button("Copy as Rich Text") { send(#selector(MarkdownTextView.copyAsRichText(_:))) }
                    .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            }

            CommandGroup(after: .textEditing) {
                Button("Find in Project…") { model.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.rootURL == nil)
            }

            CommandMenu("Go") {
                Button("Back") { model.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                    .disabled(!model.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                    .disabled(!model.canGoForward)
                Divider()
                Button("Previous Chapter") { model.goToPreviousChapter() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(model.previousChapter == nil)
                Button("Next Chapter") { model.goToNextChapter() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(model.nextChapter == nil)
                Divider()
                Button("Reveal Current File in Finder") {
                    if let selection = model.selection { model.revealInFinder(selection) }
                }
                .disabled(model.selection == nil)
            }
        }

        Settings {
            SettingsView(settings: settings)
        }
    }

    /// Routes a formatting action to the focused editor through the responder chain.
    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
