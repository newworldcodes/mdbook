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
| Files on disk | `Models/TextFile.swift` | Encoding detection (UTF-8/BOM, UTF-16, Windows-1252, Latin-1); files are saved in the encoding they were read in (UTF-8 if it can no longer represent the text). |
| Project model | `Models/ProjectModel.swift` | `@Observable`. Folder tree, selection, autosave (1 s debounce + ⌘S + flush on resign/terminate), history, link opening, new/rename/trash, outline, anchors, FSEvents watcher (`FolderWatcher.swift`). Keeps `diskText` (the file as last read/written): autosave never overwrites a file another app changed; with unsaved edits the user picks a version (`externalChange` alert), and on a file switch the edits go to a "conflicted copy". Persists the last project as a security-scoped bookmark. Standalone-file mode when only a file was granted by the sandbox. |
| File tree | `Models/FileNode.swift` | Markdown files plus folders that contain them. Folders first, natural sort. |
| Book structure | `Markdown/BookSummary.swift`, model "Chapters" section | mdBook SUMMARY.md (root, `book.toml`'s `src`, or `src/`): prefix/numbered/nested/draft/suffix chapters, parts, separators. Drives the sidebar's Contents (files collapse under "Files"), the reading order (sidebar order without a summary) and previous/next chapter (Go menu ⌥⌘←/→, toolbar, preview footer). |
| Sidebar | `Views/ProjectSidebarView.swift` | Recursive `DisclosureGroup`s bound to `expandedFolders`; context menus. Shows search results instead while the search field has a query. |
| Search | `Markdown/ProjectSearch.swift`, model "Search" section | Sidebar search field (⇧⌘F, "Find in Project"): case/diacritic-insensitive plain text over every file (reading order first; the open file as edited), debounced, off the main actor. A result opens the file and the editor selects the match via `RevealRequest`. |
| Editor | `Editor/MarkdownEditorView.swift` (representable + coordinator), `MarkdownTextView.swift` (NSTextView subclass), `MarkdownStyler.swift`, `MarkdownLayoutManager.swift`, `EditorTheme.swift` | TextKit 1 stack built by hand so the layout manager delegate can hide glyphs. Two modes: `.wysiwyg` (hide markers away from the caret) and `.source` (monospace, coloured syntax). |
| Markdown scanning | `Markdown/MarkdownHighlighter.swift`, `MarkdownSourceMap.swift` | A swift-markdown `MarkupWalker` producing `MarkdownSpans` (UTF-16 `NSRange`s) for the styler. The source map converts cmark's UTF-8 byte columns. See "swift-markdown" below for the cmark position bugs it works around. |
| Preview | `Views/MarkdownPreviewView.swift`, `Markdown/MarkdownBlockParser.swift` | swift-markdown tree → `MarkdownBlock` tree (inline `AttributedString`s with `inlinePresentationIntent` and `.link`) → SwiftUI. Tables via `Grid`, task lists, images (local or `AsyncImage`), anchors via `ScrollViewReader`, approximate scroll sync from the source pane. |
| Links | `Markdown/LinkResolver.swift`, `HeadingSlug.swift` | Relative paths resolve against the document; folders fall back to README/index/SUMMARY; `#anchor` and `file.md#anchor` use GitHub-style slugs. |
| Tables | `Markdown/MarkdownTableFormatter.swift`, `TableColumnSizer.swift`, `Editor/MarkdownTableRendering.swift` + styler/layout manager | Caret outside: the table is drawn by the layout manager with wrapping cells, fitted to the editor width (see below). Caret inside: aligned monospaced source; columns re-padded on leave. The preview's `TableGridLayout` uses the same `TableColumnSizer`, so both wrap cells instead of overflowing. |
| Export | `Markdown/HTMLRenderer.swift`, `Export/BookExport.swift`, `Export/PrintRenderer.swift` | `HTMLRenderer` walks the swift-markdown tree to XHTML-compatible HTML (GitHub heading ids, inline code colours, task boxes, table alignment). File ▸ Export Chapter/Book: HTML (one self-contained file, images as data URIs; a book gets a contents list, `chN-` id prefixes and cross-chapter links rewritten to anchors), PDF, and EPUB 3 (XHTML per chapter, tidied if raw HTML isn't well-formed; zipped by `StoredZip`). PDF/Print (⌘P) and Edit ▸ Copy as Rich Text go HTML → `NSAttributedString` → TextKit 1 text view → `NSPrintOperation`, because WKWebView's content process dies in the sandbox without the network entitlement. Printed tables are sized with `TableColumnSizer` (fixed layout) and images scaled to the page. |
| Footnotes, math, emoji | `Markdown/MarkdownExtensions.swift`, `Markdown/MathText.swift` | Not parsed by swift-markdown. For rendering, `MarkdownExtensions.prepare` rewrites the source first: footnote definitions extracted, references and inline `$math$` replaced by private-use-character tokens (math hex-encoded so cmark can't touch it), `$$…$$` turned into ```` ```math ````; consumers resolve tokens with `segments(in:)`. Preview: superscript numbers + notes list; exports: linked `<sup>` + footnotes section. Math is TeX→Unicode (`MathText`, not a typesetter). Emoji: GitHub aliases, else Unicode names. The editor keeps the source and styles it (`spans.footnoteReferences/footnoteLabels/math`); cmark reads `[^id]: x` as a link reference definition, hence the line pass and the `[^…]` link special case. |
| Preferences | `Models/AppSettings.swift` | Settings window (⌘,), View ▸ Zoom In/Out/Actual Size (text size 11–28 pt; everything scales from `EditorTheme.scale` and the preview's `markdownTextScale` environment), typeface (SF, New York, SF Rounded), focus mode (dims all but the caret's paragraph with layout-manager temporary attributes) and typewriter mode (caret line kept centred; bottom content inset so the end can centre). Toolbar shows word count and reading time. File ▸ Open Recent keeps the last ten projects as security-scoped bookmarks. |
| Code highlighting | `Markdown/CodeHighlighter.swift` | Hand-written tokenizer, ~20 languages plus a generic fallback. Used by both editor and preview. Colours in `EditorTheme.color(for:)`. |
| Tests | `mdbookTests/mdbookTests.swift`, `IncrementalStylingTests.swift`, `ProjectModelTests.swift` | 97 Swift Testing tests: block parser, highlighter (including cmark position quirks), source map, table formatter, code highlighter, link resolver, slugs, file tree. `ProjectModelTests` runs the model against a temporary book (autosave, external changes, conflicted copies, history, new/rename/delete, encodings, SUMMARY order) and saves/restores the user-defaults keys opening a project writes; `EditorCoordinatorTests` hosts the editor in a window. |

## How the WYSIWYG editor works (read before touching it)

- The text storage always contains the exact markdown source. Styling is attributes only;
  saving writes `textView.string`.
- After an edit the coordinator restyles incrementally (`Editor/IncrementalStyling.swift`):
  under 20K characters it rescans and restyles everything; up to 200K it rescans, diffs the
  new spans against the old ones shifted past the edit (`dirtyRange`), widens that to whole
  paragraphs and blocks (`expand`) and restyles only that region (`applyAll(region:)`);
  above 200K it restyles the edited paragraph at once with the old spans shifted
  (`shifted(past:delta:)`) and rescans a snapshot in the background, applying the diff if
  the text hasn't moved on (`textVersion`). `IncrementalStylingTests` checks both paths
  produce exactly what a full restyle does; keep it green when touching the styler.
- `MarkdownHighlighter.scan` works on a UTF-16 `NSString` copy: handing a native Swift
  string to `NSRegularExpression`/`character(at:)` made scanning quadratic. Post-passes
  use `RangeIndex` (binary search) rather than nested loops for the same reason.
- Markers (`**`, `` ` ``, `[`, `](url)`, `# `) carry `.markdownMarker` (value: the font to use
  when visible) and, when the caret is elsewhere, `.markdownHidden`. The coordinator's
  `NSLayoutManagerDelegate.layoutManager(_:shouldGenerateGlyphs:...)` turns hidden
  characters into `.null` glyphs, so they take no space. Caret movement only toggles the old
  and new paragraph's markers, except around tables, which restyle fully.
- The "active region" is the caret's paragraph, widened to the whole table when inside one.
- `MarkdownLayoutManager.drawBackground` paints code block panels (`.markdownCodeBlock`),
  editing-mode table header panels (`.markdownTableHeader`) and rendered tables.
- Block renderings (`MarkdownBlockRendering`: `MarkdownTableRendering`,
  `MarkdownImageRendering`) are things the editor draws for a run of source. The styler
  stores one on the source's characters (`.markdownBlockRendering`); the coordinator's
  `shouldSetLineFragmentRect` delegate grows the fragment holding the rendering's `anchor`
  by its height (below any visible text in that fragment) and collapses fragments made only
  of hidden source; the layout manager draws it there; a click inside puts the caret in the
  matching source. Hidden glyphs join the *previous* line's fragment and the hidden line's
  terminator starts a fragment of its own, so: look renderings up across a fragment's
  character range (`MarkdownLayoutManager.blockRendering(in:)`), and a hidden rendering's
  attribute also covers that terminator so it collapses. Entering or leaving a table or a line with images restyles just
  those paragraphs (`needsRestyleOnCaretChange`); a width change restyles (coalesced) so renderings refit.
  - Tables (caret outside): source hidden; cells are the styled source runs minus markers,
    column widths from `TableColumnSizer` for the container width.
  - Image lines (only images, linked badges and whitespace on the line): the images replace
    the hidden source when the caret is elsewhere, and sit under the visible source while
    it's edited. Images inside running text are drawn inline at line height while the caret
    is elsewhere: the source is hidden except its last character, which is kerned to the
    image's width (`.markdownInlineImage`) and covered by the image in `drawGlyphs` (after
    the glyphs, because a linked image's character gets the link colour and underline). The coordinator loads local
    images synchronously (cached; misses retried after each edit) and remote ones in the
    background, which needs the Outgoing Connections entitlement (not enabled yet; enable it
    in Signing & Capabilities, never by editing `project.xcproj`).
- Dropping or pasting image files links them where they are if they're inside the
  document's folder, else copies them into `images/` beside the document; pasted image data
  is saved there as a PNG. Pasting a URL over selected text makes a link.
- Block quotes (WYSIWYG): `>` runs are markers, hidden away from the caret; lines indent by
  depth (`MarkdownStyler.quoteIndent` per level, first-line indent reduced by the shown
  marker so text doesn't move) and carry `.markdownQuoteDepth` (terminator included). The
  layout manager draws one bar per level per line fragment, using the depth at the
  fragment's first visible character. Lazy lines inherit the depth above.
- Editing helpers in `MarkdownTextView`: Return continues lists and block quotes (lists
  inside quotes too; an empty `>` line ends the quote); Format ▸ Quote (⌘') toggles `> `; Tab/Shift-Tab indent and
  outdent list items (nesting by the sibling's marker width, renumbering ordered items);
  typing `](` or `#` in a link destination opens completion (chapter paths relative to the
  document, `#heading` slugs; the coordinator's `linkCompletions(for:)` supplies them).
- Typing attributes are scrubbed on every selection change so links, hidden flags and
  strikethrough never leak into new text.
- `isRichText = false`, smart quotes/dashes off, spell check off by default.

## swift-markdown

The editor's scanner and the preview's parser both use Apple's `swift-markdown`
(cmark-gfm, https://github.com/swiftlang/swift-markdown), so they agree on structure. The old
regex scanner and the Foundation `AttributedString(markdown:)` preview parser are gone.
Both parse with `.disableSmartOpts` so quotes stay as typed.

### Package

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

### How the scanner maps the tree

- `SourceLocation` columns are 1-based **UTF-8 byte** offsets; upper bounds are exclusive.
  `MarkdownSourceMap` converts them to UTF-16 (fast path for ASCII lines).
- Markers are a node's range minus its children's span (`Strong`, `Emphasis`,
  `Strikethrough`, `Link`, `Image`); code spans count their backticks. Every delimiter is
  checked against the characters it should contain and the construct is dropped if not, so
  a bad position never hides real text.
- Headings: ATX prefix/suffix around the children; setext underline is the line after the
  last child. Code blocks: whole lines, fences detected from the text, `language` is the
  first word of the info string. List items: marker is the gap before the first child, with
  the `[ ]` found inside it. Block quotes: `>` runs per line of the outermost quote (lazy
  lines get an empty marker). HTML blocks and inline HTML go in `spans.html` (dimmed, never
  hidden). Bare URLs come from `LinkResolver.bareURLs` because swift-markdown doesn't enable
  cmark-gfm's autolink extension.

### cmark position bugs worked around (all covered by tests)

1. **Continuation lines.** Inline columns are `paragraph start column + offset into the
   line's content` on every line, so on lines whose content starts elsewhere (task items,
   tab-indented or deeper lazy lines) they are wrong. `SpanWalker.offset(_:)` re-bases them
   on the line's real content start (after up to quote-depth `>` markers and whitespace).
2. **Tables that interrupt a paragraph** (`intro\n| a |\n|---|`) are reported starting on
   the paragraph's line, with header columns counted as if the lines were joined. The real
   header is found from the delimiter row and header columns go through
   `MarkdownSourceMap.offset(flowingFrom:)`. The interrupted paragraph itself has no range,
   so its inline styling is lost (rare; left alone).
3. **Escaped pipes in cells.** GFM drops the backslash of `\|` before parsing a cell, so
   later columns come up short by one per escape; they're shifted back.
4. **Multi-line setext headings** report a range running into the next block, hence the
   underline rule above.

Note GFM splits a table cell on an unescaped `|` even inside backticks (GitHub does the same).
`pipeRanges` still treats those as text, so the editor grid and the preview can differ on
such rows.

Comparing old vs new scanner over the corpus: no bad markers, slightly faster
(~65 ms vs ~72 ms for all 20 files), and multi-line emphasis and code spans the old
line-based scanner missed or mis-paired are now found.

Next: swift-markdown's `HTMLFormatter` is a candidate for HTML export.

## Known gaps (priority order)

1. Mermaid diagrams (shown as source) and real math typesetting: both need a JS library in a
   WKWebView, i.e. a bundled third-party asset plus the Outgoing Connections entitlement
   (WebKit's content process dies in the sandbox without it). Deferred for now.

Known quirks: links inside a rendered editor table aren't clickable (a click enters the
table); find/selection highlights don't show inside a rendered table; an image nested inside a
link renders as the image in the preview but isn't clickable; raw HTML blocks show as source
in the preview; auto-align rewrites table text when the caret leaves (undoable).

## Conventions

- Swift Testing (`@Test`, `#expect`) for unit tests, XCUIAutomation for UI tests.
- `@Observable` models, `@State private var`, async/await, no Combine.
- Default actor isolation is `MainActor`; pure helpers are marked `nonisolated`.
- Target is macOS only on purpose (AppKit text system). Don't re-add iOS.
- One feature per commit, imperative subject line, body explains the why.
