# mdbook

macOS markdown book reader/editor. SwiftUI + AppKit text system, no third-party packages
yet. Read `HANDOFF.md` first for architecture, the WYSIWYG editor's invariants, and the
in-progress swift-markdown migration.

## Commands

```sh
xcodebuild -project mdbook.xcodeproj -scheme mdbook -destination 'platform=macOS' -quiet build
xcodebuild -project mdbook.xcodeproj -scheme mdbook -destination 'platform=macOS' test 2>&1 | grep -E 'Test Suite .* (passed|failed)|TEST (SUCCEEDED|FAILED)'
```

Run the app on the test corpus: build, then
`open -a <BUILT_PRODUCTS_DIR>/mdbook.app ~/www/rust/elp --args -editorLayout split`.

## Rules

- Never hand-edit `mdbook.xcodeproj/project.xcproj` (new JSON format; a bad edit silently
  empties the project in Xcode). Package dependencies get added through Xcode's UI.
- Keep the target macOS-only. The editor depends on NSTextView/TextKit 1.
- The text storage must always equal the markdown source; style with attributes only.
- Swift Testing for unit tests; `@Observable`, `@State private var`, async/await, no Combine.
- `SWIFT_DEFAULT_ACTOR_ISOLATION` is MainActor. Mark pure helpers `nonisolated`.
- Run the tests before committing. Commit per feature with an imperative subject.
- Verify UI changes by rendering the previews in `mdbook/Editor/EditorPreviews.swift` or by
  launching the app on the corpus and taking a screenshot.

## Style

PascalCase types, camelCase members, 4-space indent, descriptive comments only where the
logic is non-obvious. Markdown tables in docs use leading and trailing pipes.
