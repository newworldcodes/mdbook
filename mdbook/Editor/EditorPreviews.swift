//
//  EditorPreviews.swift
//  mdbook
//
//  Xcode previews with representative markdown for eyeballing the editor and renderer.
//

import SwiftUI

enum SampleMarkdown {
    static let text = """
    # Chapter One

    Welcome to **mdbook**, a *markdown* reader with ~~rough~~ smooth editing and `inline code`.
    See the [next chapter](chapter-two.md) or visit <https://example.com>.

    ## Tasks

    - [x] Parse GitHub Flavored Markdown
    - [ ] Write the second chapter
      1. Outline
      2. Draft

    > Quotes keep their *emphasis* and indent nicely.

    ```swift
    let greeting = "Hello, world"
    print(greeting)
    ```

    | Feature | Status |
    |:--------|-------:|
    | Tables  | done   |
    | Images  | done   |

    ---

    Final paragraph with a bare link https://apple.com and an image ![Logo](images/logo.png).
    """
}

#Preview("WYSIWYG editor") {
    @Previewable @State var text = SampleMarkdown.text
    MarkdownEditorView(text: $text, mode: .wysiwyg, onOpenLink: { _ in })
        .frame(width: 640, height: 720)
}

#Preview("Source editor") {
    @Previewable @State var text = SampleMarkdown.text
    MarkdownEditorView(text: $text, mode: .source, onOpenLink: { _ in })
        .frame(width: 640, height: 720)
}

#Preview("Rendered preview") {
    MarkdownPreviewView(text: SampleMarkdown.text, documentURL: nil, onOpenLink: { _ in })
        .frame(width: 640, height: 720)
}
