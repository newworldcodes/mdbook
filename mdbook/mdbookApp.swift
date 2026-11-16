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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 700, minHeight: 400)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New File…") { model.requestNewFile() }
                    .keyboardShortcut("n")
                    .disabled(model.rootURL == nil)
                Button("Open Folder…") { model.openFolderPanel() }
                    .keyboardShortcut("o")
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveNow() }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty)
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
    }

    /// Routes a formatting action to the focused editor through the responder chain.
    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
