//
//  CodeHighlighter.swift
//  mdbook
//
//  A small, dependency-free tokenizer for fenced code blocks. It recognises
//  comments, strings, numbers, keywords, types and attributes for the common
//  languages, and falls back to generic C-like rules for anything unknown.
//

import Foundation

nonisolated struct CodeToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyword, string, comment, number, type, attribute, tag, property
    }

    var kind: Kind
    var range: NSRange
}

nonisolated enum CodeHighlighter {
    struct Language: Sendable {
        var lineComments: [String] = ["//"]
        var blockComment: (open: String, close: String)? = ("/*", "*/")
        /// Delimiters that open a string on one line.
        var stringDelimiters: Set<Character> = ["\"", "'"]
        /// Delimiters whose strings may span lines (template literals, raw strings).
        var multilineStringDelimiters: Set<Character> = []
        var keywords: Set<String> = []
        /// Highlight capitalised identifiers as types.
        var capitalisedTypes = true
        /// `@attribute` or `#directive` prefixes.
        var attributePrefixes: Set<Character> = []
        /// Treat `key:` / `key =` at line start as a property (YAML, TOML, JSON keys).
        var highlightsKeys = false
        /// Markup mode: tags and attributes rather than keywords.
        var isMarkup = false
    }

    static func tokens(in code: String, language name: String?) -> [CodeToken] {
        let language = self.language(named: name)
        var scanner = Scanner(code: code, language: language)
        return language.isMarkup ? scanner.scanMarkup() : scanner.scan()
    }

    // MARK: - Language table

    static func language(named rawName: String?) -> Language {
        let name = (rawName ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        switch name {
        case "swift":
            return Language(
                keywords: swiftKeywords,
                attributePrefixes: ["@", "#"]
            )
        case "rust", "rs":
            return Language(keywords: rustKeywords, attributePrefixes: ["#"])
        case "kotlin", "kt", "elp":
            return Language(keywords: kotlinKeywords, attributePrefixes: ["@"])
        case "java":
            return Language(keywords: javaKeywords, attributePrefixes: ["@"])
        case "javascript", "js", "jsx", "typescript", "ts", "tsx":
            return Language(
                multilineStringDelimiters: ["`"],
                keywords: javascriptKeywords,
                attributePrefixes: ["@"]
            )
        case "python", "py":
            return Language(
                lineComments: ["#"],
                blockComment: nil,
                keywords: pythonKeywords,
                attributePrefixes: ["@"]
            )
        case "ruby", "rb":
            return Language(lineComments: ["#"], blockComment: nil, keywords: rubyKeywords, attributePrefixes: ["@"])
        case "go", "golang":
            return Language(multilineStringDelimiters: ["`"], keywords: goKeywords)
        case "c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c", "m", "mm":
            return Language(keywords: cKeywords, attributePrefixes: ["#", "@"])
        case "csharp", "cs", "c#":
            return Language(keywords: csharpKeywords, attributePrefixes: ["#"])
        case "php":
            return Language(lineComments: ["//", "#"], keywords: phpKeywords, capitalisedTypes: true)
        case "sh", "bash", "zsh", "shell", "console", "fish":
            return Language(lineComments: ["#"], blockComment: nil, keywords: shellKeywords, capitalisedTypes: false)
        case "sql", "mysql", "postgres", "postgresql", "sqlite":
            return Language(lineComments: ["--"], keywords: sqlKeywords, capitalisedTypes: false)
        case "json", "jsonc", "json5":
            return Language(keywords: ["true", "false", "null"], capitalisedTypes: false, highlightsKeys: true)
        case "yaml", "yml":
            return Language(lineComments: ["#"], blockComment: nil, keywords: ["true", "false", "null", "yes", "no", "on", "off", "~"], capitalisedTypes: false, highlightsKeys: true)
        case "toml", "ini", "cfg", "conf", "properties":
            return Language(lineComments: ["#", ";"], blockComment: nil, keywords: ["true", "false"], capitalisedTypes: false, highlightsKeys: true)
        case "html", "xml", "svg", "xhtml", "vue", "svelte", "velp":
            return Language(lineComments: [], blockComment: ("<!--", "-->"), isMarkup: true)
        case "css", "scss", "less", "selp":
            return Language(lineComments: ["//"], keywords: cssKeywords, capitalisedTypes: false, attributePrefixes: ["@"], highlightsKeys: true)
        case "makefile", "make", "dockerfile", "docker":
            return Language(lineComments: ["#"], blockComment: nil, keywords: dockerKeywords, capitalisedTypes: false)
        case "":
            return Language(keywords: genericKeywords)
        default:
            return Language(keywords: genericKeywords)
        }
    }

    // MARK: - Scanner

    private struct Scanner {
        let utf16: [UInt16]
        let language: Language
        var tokens: [CodeToken] = []

        init(code: String, language: Language) {
            utf16 = Array(code.utf16)
            self.language = language
        }

        private func character(at index: Int) -> Character? {
            guard index < utf16.count, let scalar = UnicodeScalar(utf16[index]) else { return nil }
            return Character(scalar)
        }

        private func hasPrefix(_ prefix: String, at index: Int) -> Bool {
            let units = Array(prefix.utf16)
            guard index + units.count <= utf16.count else { return false }
            for (offset, unit) in units.enumerated() where utf16[index + offset] != unit { return false }
            return true
        }

        private func isIdentifierStart(_ character: Character) -> Bool {
            character.isLetter || character == "_" || character == "$"
        }

        private func isIdentifierPart(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_" || character == "$"
        }

        private func index(ofLineEndFrom index: Int) -> Int {
            var end = index
            while end < utf16.count, utf16[end] != 0x0A { end += 1 }
            return end
        }

        // MARK: Code

        mutating func scan() -> [CodeToken] {
            var index = 0
            var atLineStart = true
            while index < utf16.count {
                guard let character = character(at: index) else { index += 1; continue }

                if character == "\n" {
                    atLineStart = true
                    index += 1
                    continue
                }
                if character.isWhitespace {
                    index += 1
                    continue
                }

                if let comment = language.lineComments.first(where: { hasPrefix($0, at: index) }),
                   !(comment == "#" && isShebangOrDirectiveException(at: index)) {
                    let end = self.index(ofLineEndFrom: index)
                    tokens.append(CodeToken(kind: .comment, range: NSRange(location: index, length: end - index)))
                    index = end
                    continue
                }

                if let block = language.blockComment, hasPrefix(block.open, at: index) {
                    index = scanBlock(from: index, open: block.open, close: block.close, kind: .comment)
                    atLineStart = false
                    continue
                }

                if language.multilineStringDelimiters.contains(character) {
                    index = scanString(from: index, delimiter: character, multiline: true)
                    atLineStart = false
                    continue
                }
                if language.stringDelimiters.contains(character) {
                    index = scanString(from: index, delimiter: character, multiline: false)
                    atLineStart = false
                    continue
                }

                if character.isNumber || (character == "." && (self.character(at: index + 1)?.isNumber ?? false)) {
                    var end = index + 1
                    while let next = self.character(at: end), next.isHexDigit || next == "." || next == "_" || next == "x" || next == "o" || next == "b" || next == "e" || next == "E" {
                        end += 1
                    }
                    tokens.append(CodeToken(kind: .number, range: NSRange(location: index, length: end - index)))
                    index = end
                    atLineStart = false
                    continue
                }

                if language.attributePrefixes.contains(character), let next = self.character(at: index + 1), isIdentifierStart(next) || next == "[" {
                    var end = index + 1
                    while let next = self.character(at: end), isIdentifierPart(next) || next == "." { end += 1 }
                    tokens.append(CodeToken(kind: .attribute, range: NSRange(location: index, length: end - index)))
                    index = end
                    atLineStart = false
                    continue
                }

                if isIdentifierStart(character) {
                    var end = index + 1
                    while let next = self.character(at: end), isIdentifierPart(next) { end += 1 }
                    let word = String(utf16CodeUnits: Array(utf16[index..<end]), count: end - index)
                    let range = NSRange(location: index, length: end - index)
                    if language.keywords.contains(word) || language.keywords.contains(word.lowercased()) && language.lineComments == ["--"] {
                        tokens.append(CodeToken(kind: .keyword, range: range))
                    } else if language.highlightsKeys, atLineStart, isKey(after: end) {
                        tokens.append(CodeToken(kind: .property, range: range))
                    } else if language.capitalisedTypes, character.isUppercase {
                        tokens.append(CodeToken(kind: .type, range: range))
                    }
                    index = end
                    atLineStart = false
                    continue
                }

                atLineStart = false
                index += 1
            }
            return tokens
        }

        /// `#!/bin/sh` and C-style `#include` are not comments even where `#` opens one.
        private func isShebangOrDirectiveException(at index: Int) -> Bool {
            hasPrefix("#!", at: index)
        }

        /// Whether the identifier ending at `end` is followed by `:` or `=` (a key).
        private func isKey(after end: Int) -> Bool {
            var cursor = end
            while let next = character(at: cursor), next == " " || next == "\t" { cursor += 1 }
            guard let next = character(at: cursor) else { return false }
            return next == ":" || next == "="
        }

        private mutating func scanBlock(from start: Int, open: String, close: String, kind: CodeToken.Kind) -> Int {
            var index = start + open.utf16.count
            while index < utf16.count, !hasPrefix(close, at: index) { index += 1 }
            let end = min(utf16.count, index + close.utf16.count)
            tokens.append(CodeToken(kind: kind, range: NSRange(location: start, length: end - start)))
            return end
        }

        private mutating func scanString(from start: Int, delimiter: Character, multiline: Bool) -> Int {
            // Triple-quoted strings (Swift, Python) span lines.
            let isTriple = hasPrefix(String(repeating: delimiter, count: 3), at: start)
            let spansLines = multiline || isTriple
            var index = start + (isTriple ? 3 : 1)
            while index < utf16.count {
                guard let character = character(at: index) else { break }
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == "\n", !spansLines { break }
                if character == delimiter {
                    if isTriple {
                        if hasPrefix(String(repeating: delimiter, count: 3), at: index) {
                            index += 3
                            break
                        }
                    } else {
                        index += 1
                        break
                    }
                }
                index += 1
            }
            let end = min(index, utf16.count)
            // JSON/YAML keys: a string immediately followed by a colon.
            let kind: CodeToken.Kind = language.highlightsKeys && isKey(after: end) ? .property : .string
            tokens.append(CodeToken(kind: kind, range: NSRange(location: start, length: end - start)))
            return end
        }

        // MARK: Markup

        mutating func scanMarkup() -> [CodeToken] {
            var index = 0
            while index < utf16.count {
                if let block = language.blockComment, hasPrefix(block.open, at: index) {
                    index = scanBlock(from: index, open: block.open, close: block.close, kind: .comment)
                    continue
                }
                guard character(at: index) == "<" else { index += 1; continue }

                // Tag name.
                var cursor = index + 1
                if character(at: cursor) == "/" || character(at: cursor) == "?" || character(at: cursor) == "!" { cursor += 1 }
                let nameStart = cursor
                while let next = character(at: cursor), isIdentifierPart(next) || next == "-" || next == ":" { cursor += 1 }
                guard cursor > nameStart else { index += 1; continue }
                tokens.append(CodeToken(kind: .tag, range: NSRange(location: index, length: cursor - index)))

                // Attributes until the closing angle bracket.
                while cursor < utf16.count, let next = character(at: cursor), next != ">" {
                    if next == "\"" || next == "'" {
                        cursor = scanString(from: cursor, delimiter: next, multiline: true)
                    } else if isIdentifierStart(next) {
                        let attributeStart = cursor
                        while let part = character(at: cursor), isIdentifierPart(part) || part == "-" || part == ":" { cursor += 1 }
                        tokens.append(CodeToken(kind: .attribute, range: NSRange(location: attributeStart, length: cursor - attributeStart)))
                    } else {
                        cursor += 1
                    }
                }
                if cursor < utf16.count {
                    tokens.append(CodeToken(kind: .tag, range: NSRange(location: cursor, length: 1)))
                    cursor += 1
                }
                index = cursor
            }
            return tokens
        }
    }

    // MARK: - Keyword lists

    private static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal",
        "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript",
        "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard",
        "if", "in", "repeat", "return", "throw", "switch", "where", "while", "as", "any", "false", "is", "nil", "self", "Self",
        "super", "throws", "true", "try", "async", "await", "actor", "some", "macro", "consuming", "borrowing", "nonisolated",
        "override", "mutating", "nonmutating", "convenience", "required", "final", "lazy", "weak", "unowned", "indirect", "get", "set", "willSet", "didSet",
    ]

    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if",
        "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
        "super", "trait", "true", "type", "unsafe", "use", "where", "while", "union", "macro_rules",
    ]

    private static let kotlinKeywords: Set<String> = [
        "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "fn", "if", "in", "interface", "is", "null", "object",
        "package", "return", "super", "this", "throw", "true", "try", "typealias", "val", "var", "when", "while", "by", "catch",
        "constructor", "delegate", "dynamic", "field", "file", "finally", "get", "import", "init", "param", "property", "receiver",
        "set", "setparam", "where", "abstract", "actual", "annotation", "companion", "const", "crossinline", "data", "enum",
        "expect", "external", "final", "infix", "inline", "inner", "internal", "lateinit", "noinline", "open", "operator", "out",
        "override", "private", "protected", "public", "reified", "sealed", "suspend", "tailrec", "vararg", "export", "match", "let", "mut", "pure", "with", "struct", "type", "component", "extend", "macro", "throws",
    ]

    private static let javaKeywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do",
        "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if", "implements", "import", "instanceof",
        "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static",
        "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while",
        "true", "false", "null", "var", "record", "sealed", "permits", "yield",
    ]

    private static let javascriptKeywords: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends",
        "finally", "for", "function", "if", "import", "in", "instanceof", "new", "return", "super", "switch", "this", "throw", "try",
        "typeof", "var", "void", "while", "with", "yield", "let", "static", "async", "await", "of", "true", "false", "null",
        "undefined", "interface", "type", "enum", "implements", "readonly", "declare", "namespace", "abstract", "public", "private",
        "protected", "as", "satisfies", "keyof", "from",
    ]

    private static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
        "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
        "return", "try", "while", "with", "yield", "match", "case", "self", "print",
    ]

    private static let rubyKeywords: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false", "for",
        "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true",
        "undef", "unless", "until", "when", "while", "yield", "require", "attr_accessor", "attr_reader", "puts", "lambda", "proc",
    ]

    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if",
        "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "true", "false",
        "nil", "iota", "string", "int", "int64", "int32", "uint", "byte", "rune", "bool", "error", "float64", "any",
    ]

    private static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for",
        "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
        "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "true", "false", "nullptr", "NULL", "class",
        "namespace", "template", "typename", "using", "virtual", "override", "public", "private", "protected", "new", "delete",
        "this", "try", "catch", "throw", "constexpr", "auto", "explicit", "friend", "operator", "static_cast", "dynamic_cast",
        "reinterpret_cast", "const_cast", "noexcept", "mutable", "self", "id", "nil", "YES", "NO", "interface", "implementation",
        "property", "synthesize", "end", "selector", "strong", "weak", "nonatomic", "atomic", "readonly", "copy", "assign",
    ]

    private static let csharpKeywords: Set<String> = [
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked", "class", "const", "continue",
        "decimal", "default", "delegate", "do", "double", "else", "enum", "event", "explicit", "extern", "false", "finally", "fixed",
        "float", "for", "foreach", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock", "long", "namespace",
        "new", "null", "object", "operator", "out", "override", "params", "private", "protected", "public", "readonly", "ref",
        "return", "sbyte", "sealed", "short", "sizeof", "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true",
        "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "var", "virtual", "void", "volatile", "while",
        "async", "await", "record", "init", "get", "set", "yield",
    ]

    private static let phpKeywords: Set<String> = [
        "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue", "declare",
        "default", "do", "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile",
        "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "goto", "if", "implements", "include",
        "include_once", "instanceof", "insteadof", "interface", "isset", "list", "match", "namespace", "new", "or", "print",
        "private", "protected", "public", "readonly", "require", "require_once", "return", "static", "switch", "throw", "trait",
        "try", "unset", "use", "var", "while", "xor", "yield", "true", "false", "null",
    ]

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return",
        "local", "export", "source", "exit", "echo", "cd", "ls", "rm", "mkdir", "cp", "mv", "cat", "grep", "sed", "awk", "sudo",
        "git", "npm", "cargo", "swift", "make", "curl", "set", "unset", "readonly", "declare", "shift", "test", "true", "false",
        "brew", "xcodebuild", "python", "pip", "docker", "ssh", "chmod", "chown", "touch", "find", "xargs", "tar", "open",
    ]

    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add",
        "column", "primary", "key", "foreign", "references", "not", "null", "unique", "index", "join", "inner", "left", "right",
        "outer", "full", "on", "as", "and", "or", "in", "is", "like", "between", "order", "by", "group", "having", "limit", "offset",
        "distinct", "count", "sum", "avg", "min", "max", "case", "when", "then", "else", "end", "union", "all", "exists", "begin",
        "commit", "rollback", "transaction", "default", "constraint", "cascade", "if", "with", "returning", "integer", "text",
        "varchar", "boolean", "timestamp", "date", "real", "blob", "true", "false",
    ]

    private static let cssKeywords: Set<String> = [
        "important", "inherit", "initial", "unset", "none", "auto", "block", "inline", "flex", "grid", "absolute", "relative", "fixed",
        "sticky", "solid", "bold", "normal", "center", "left", "right", "hidden", "visible", "transparent", "var", "calc", "url",
        "rgb", "rgba", "hsl", "linear-gradient",
    ]

    private static let dockerKeywords: Set<String> = [
        "FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG",
        "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS", "ifeq", "ifneq", "endif", "include", "define", "endef", "export",
        "PHONY",
    ]

    private static let genericKeywords: Set<String> = [
        "if", "else", "elif", "for", "while", "do", "return", "break", "continue", "switch", "case", "default", "fn", "func",
        "function", "def", "let", "var", "val", "const", "mut", "import", "export", "from", "package", "module", "use", "class",
        "struct", "enum", "interface", "trait", "impl", "extends", "implements", "new", "this", "self", "super", "true", "false",
        "null", "nil", "none", "None", "try", "catch", "finally", "throw", "throws", "async", "await", "yield", "in", "is", "as",
        "not", "and", "or", "public", "private", "protected", "static", "match", "when", "type", "typealias", "with", "pure", "component",
    ]
}
