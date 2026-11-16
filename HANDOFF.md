# mdbook handoff

A native macOS markdown book reader and editor. SwiftUI shell, AppKit text system for the
editor, no third-party dependencies yet. This document is the state of play for whoever
(or whatever) picks the project up next. `CLAUDE.md` holds the short working rules;
this file holds the context behind them.

Repository: https://github.com/newworldcodes/mdbook (branch `main`).
Test corpus: `~/www/rust/elp` (README plus `docs/*.md` with large tables, code fences
and relative links). It is the best folder to open when checking changes by eye.

## Build, test, run

```sh
# Build
xcodebuild -project mdbook.xcodeproj -scheme mdbook -destination 'platform=macOS' -quiet build

# Unit + UI tests (Swift Testing; ~1 minute)
xcodebuild -project mdbook.xcodeproj -scheme mdbook -destination 'platform=macOS' test 2>&1 \
  | grep -E 'Test Suite .* (passed|failed)|TEST (SUCCEEDED|FAILED)'

# Launch the built app on a folder (sandbox grants access because Launch Services opens it)
APP=$(xcodebuild -project mdbook.xcodeproj -scheme mdbook -destination 'platform=macOS' \
      -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/ {print $3}')/mdbook.app
open -a "$APP" ~/www/rust/elp --args -editorLayout split   # or -editorLayout wysiwyg
```

Visual checks without clicking around: `mdbook/Editor/EditorPreviews.swift` has three
`#Preview`s (WYSIWYG editor, source editor, rendered preview) fed by `SampleMarkdown.text`,
which exercises every construct. Render them in Xcode's canvas, or screenshot the running app
with `screencapture -l<windowID>` (find the id with `CGWindowListCopyWindowInfo`).

The project file is Xcode 27's JSON-style `mdbook.xcodeproj/project.xcproj`, not a
`project.pbxproj`. Do not hand-edit it. See "Adding swift-markdown" below for why.

## What exists

| Area | Files | Notes |
|---|---|---|
| App shell | `mdbookApp.swift`, `AppDelegate.swift`, `ContentView.swift` | `NavigationSplitView`, toolbar (back/forward, layout picker, outline menu, save state), menus (File, Format, View, Go). AppDelegate owns the model and handles folders/files opened from Finder or `open -a`. |
| Project model | `Models/ProjectModel.swift` | `@Observable`. Folder tree, selection, autosave (1 s debounce + ⌘S + flush on resign/terminate), history, link opening, new/rename/trash, outline, anchors, FSEvents watcher (`FolderWatcher.swift`). Persists the last project as a security-scoped bookmark. Standalone-file mode when only a file was granted by the sandbox. |
| File tree | `Models/FileNode.swift` | Markdown files plus folders that contain them. Folders first, natural sort. |
| Sidebar | `Views/ProjectSidebarView.swift` | Recursive `DisclosureGroup`s bound to `expandedFolders`; context menus. |
| Editor | `Editor/MarkdownEditorView.swift` (representable + coordinator), `MarkdownTextView.swift` (NSTextView subclass), `MarkdownStyler.swift`, `MarkdownLayoutManager.swift`, `EditorTheme.swift` | TextKit 1 stack built by hand so the layout manager delegate can hide glyphs. Two modes: `.wysiwyg` (hide markers away from the caret) and `.source` (monospace, coloured syntax). |
| Markdown scanning | `Markdown/MarkdownHighlighter.swift` | Regex, line-oriented scanner producing `MarkdownSpans` (UTF-16 `NSRange`s) for the styler. **This is what the swift-markdown migration replaces.** |
| Preview | `Views/MarkdownPreviewView.swift`, `Markdown/MarkdownBlockParser.swift` | Foundation's `AttributedString(markdown:)` (cmark-gfm) → `MarkdownBlock` tree → SwiftUI. Tables via `Grid`, task lists, images (local or `AsyncImage`), anchors via `ScrollViewReader`, approximate scroll sync from the source pane. |
| Links | `Markdown/LinkResolver.swift`, `HeadingSlug.swift` | Relative paths resolve against the document; folders fall back to README/index/SUMMARY; `#anchor` and `file.md#anchor` use GitHub-style slugs. |
| Tables | `Markdown/MarkdownTableFormatter.swift` + styler/layout manager | Grid rendering when the caret is outside (pipes made clear and kerned so columns line up in the proportional font; delimiter row collapsed; header fill and grid drawn by the layout manager). Aligned monospaced source when the caret is inside; columns re-padded on leave. |
| Code highlighting | `Markdown/CodeHighlighter.swift` | Hand-written tokenizer, ~20 languages plus a generic fallback. Used by both editor and preview. Colours in `EditorTheme.color(for:)`. |
| Tests | `mdbookTests/mdbookTests.swift` | 37 Swift Testing tests: block parser, highlighter, table formatter, code highlighter, link resolver, slugs, file tree. No tests yet for the coordinator, autosave, rename or history. |

## How the WYSIWYG editor works (read before touching it)

- The text storage always contains the exact markdown source. Styling is attributes only;
  saving writes `textView.string`.
- Every keystroke rescans the whole document (`MarkdownHighlighter.scan`) and reapplies all
  attributes (`MarkdownStyler.applyAll`). Fine for chapters, will stutter on huge files.
- Markers (`**`, `` ` ``, `[`, `](url)`, `# `) carry `.markdownMarker` (value: the font to use
  when visible) and, when the caret is elsewhere, `.markdownHidden`. The coordinator's
  `NSLayoutManagerDelegate.layoutManager(_:shouldGenerateGlyphs:...)` turns hidden
  characters into `.null` glyphs, so they take no space. Caret movement only toggles the old
  and new paragraph's markers, except around tables, which restyle fully.
- The "active region" is the caret's paragraph, widened to the whole table when inside one.
- `MarkdownLayoutManager.drawBackground` paints code block panels (`.markdownCodeBlock`),
  editing-mode table header panels (`.markdownTableHeader`) and rendered table grids
  (`.markdownTableGrid` + `.markdownTableColumns` edges + `.markdownTablePipe`).
- Typing attributes are scrubbed on every selection change so links, hidden flags and
  strikethrough never leak into new text.
- `isRichText = false`, smart quotes/dashes off, spell check off by default.

## In progress: adopt swift-markdown

Decision taken: replace the regex scanner (and ideally the preview's parser) with Apple's
`swift-markdown` (https://github.com/swiftlang/swift-markdown, latest tag 0.9.0). Rationale: it
is cmark-gfm with source ranges on every node, which removes a class of edge cases (compound
styles, reference links, indented code, HTML blocks, setext corner cases) the regexes can't
get right.

### Package added

`swift-markdown` 0.9.0 (product **Markdown**, pulling in `swift-cmark` 0.9.0) is a dependency
of the `mdbook` target, added through Xcode's Project editor → Package Dependencies tab (the
"Add to Project" dropdown in File → Add Package Dependencies… came up empty). Pins live in
`mdbook.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. For the record,
Xcode wrote this to `project.xcproj` (still don't hand-edit it; use Xcode for package changes):

```json
"packages": [
  { "kind": "remote", "repository": "https://github.com/swiftlang/swift-markdown.git",
    "version": { "up-to-next-major-version": "0.9.0" } },
],
// inside the mdbook target:
"package-product-members": [
  { "package": "swift-markdown", "product-name": "Markdown",
    "build-phase": { "build-phase": "frameworks" } },
],
```

### Migration plan

1. `MarkdownSourceMap` (not yet in the repo; a draft was lost when the write failed): maps
   swift-markdown `SourceLocation` (1-based line, 1-based **UTF-8 byte** column — verify with a
   probe on a line containing an emoji) to UTF-16 offsets for `NSRange`.
2. Reimplement `MarkdownHighlighter.scan` as a `MarkupWalker` producing the same
   `MarkdownSpans`, so `MarkdownStyler` and the coordinator need no changes:
   - Node ranges include delimiters; child ranges don't. Marker ranges = parent range minus
     children (`Strong`, `Emphasis`, `Strikethrough`, `InlineCode`, `Link`, `Image`).
   - `Heading`: ATX prefix = gap before first child; setext underline = last line of range.
   - `CodeBlock`: first/last lines are fences; `language` from the node.
   - `ListItem`: marker = gap before first child; `checkbox` gives the task state, find `[ ]`
     with a tiny regex in that gap.
   - `Table`: `head`/`body` rows and cells have ranges; the delimiter row is the line
     between head and first body row; pipes via the existing `pipeRanges`.
   - `BlockQuote`: `>` markers per line in the gap before children.
   - `HTMLBlock` / `InlineHTML`: dim like markers.
3. Reimplement `MarkdownBlockParser.parse` on the same tree so editor and preview agree
   (build inline `AttributedString`s with `inlinePresentationIntent` and `.link`).
4. Keep the existing tests green; add cases for reference links, indented code, HTML blocks
   and nested emphasis. Expect to loosen `emphasis()`'s "8 markers" count if marker ranges
   are merged differently.
5. Consider `swift-markdown`'s `HTMLFormatter` for a later HTML export feature.

## Known gaps (priority order)

1. SUMMARY.md-driven chapter order with previous/next navigation.
2. Project-wide search.
3. Reference-style links, indented code blocks, inline HTML (all fall out of the migration).
4. Inline images in the WYSIWYG view (text attachments).
5. Incremental restyling for large files (or adopt STTextView).
6. Tab/Shift-Tab list indentation, paste URL over selection, drop images into the project.
7. "File changed on disk while you have unsaved edits" prompt; non-UTF-8 encodings.
8. Export to HTML/PDF, printing, copy as rich text.
9. Footnotes, math, Mermaid, emoji shortcodes.
10. Tests for the coordinator, autosave, rename and history.

Known quirks: tables wider than the editor wrap and break the grid; an image nested inside a
link renders as link text (Foundation drops `imageURL` there); auto-align rewrites table text
when the caret leaves (undoable).

## Conventions

- Swift Testing (`@Test`, `#expect`) for unit tests, XCUIAutomation for UI tests.
- `@Observable` models, `@State private var`, async/await, no Combine.
- Default actor isolation is `MainActor`; pure helpers are marked `nonisolated`.
- Target is macOS only on purpose (AppKit text system). Don't re-add iOS.
- One feature per commit, imperative subject line, body explains the why.
