//
//  AppDelegate.swift
//  mdbook
//
//  Owns the shared project model and handles folders/files opened from Finder,
//  the Dock, or `open -a mdbook <folder>`.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ProjectModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `mdbook /path/to/book` from a terminal or an Xcode scheme argument.
        // Other arguments (such as `-editorLayout split`) belong to user defaults.
        let existingPath = CommandLine.arguments.dropFirst().first { argument in
            !argument.hasPrefix("-") && FileManager.default.fileExists(atPath: argument)
        }
        if let existingPath {
            open(URL(fileURLWithPath: existingPath))
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushPendingSave()
    }

    private func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            model.openProject(at: url)
        } else {
            model.openFile(at: url)
        }
    }
}
