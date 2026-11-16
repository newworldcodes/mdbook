//
//  MathText.swift
//  mdbook
//
//  A small TeX-to-Unicode converter for math in prose: `x^2 + \alpha_i \leq \frac{1}{n}`
//  becomes `x² + αᵢ ≤ 1⁄n`. It isn't a typesetter (no stacked fractions, matrices or
//  big operators with limits), but it reads well for the inline formulas books are full
//  of, and works everywhere text does: the preview, PDF, EPUB and rich-text copy.
//

import Foundation

nonisolated enum MathText {
    static func unicode(fromTeX tex: String) -> String {
        var parser = Parser(characters: Array(tex))
        return parser.parseSequence(until: nil)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        /// Inside a sub/superscript: no spacing around operators (`n+1` stays `ⁿ⁺¹`).
        var compact = false

        mutating func parseSequence(until terminator: Character?) -> String {
            var output = ""
            while index < characters.count {
                let character = characters[index]
                if let terminator, character == terminator {
                    index += 1
                    return output
                }
                switch character {
                case "\\":
                    output += parseCommand()
                case "{":
                    index += 1
                    output += parseSequence(until: "}")
                case "^", "_":
                    index += 1
                    let wasCompact = compact
                    compact = true
                    let argument = parseArgument().trimmingCharacters(in: .whitespaces)
                    compact = wasCompact
                    output += character == "^" ? MathText.superscript(argument) : MathText.subscript(argument)
                case "~":
                    output += " "
                    index += 1
                default:
                    output += compact ? String(character) : MathText.operatorSpacing[character] ?? String(character)
                    index += 1
                }
            }
            return output
        }

        /// One argument: a `{group}`, a `\command` or a single character.
        mutating func parseArgument() -> String {
            while index < characters.count, characters[index] == " " { index += 1 }
            guard index < characters.count else { return "" }
            switch characters[index] {
            case "{":
                index += 1
                return parseSequence(until: "}")
            case "\\":
                return parseCommand()
            default:
                defer { index += 1 }
                return String(characters[index])
            }
        }

        mutating func parseCommand() -> String {
            index += 1 // backslash
            guard index < characters.count else { return "\\" }
            // Single-symbol commands: \, \; \{ \} \\ …
            if !characters[index].isLetter {
                let symbol = characters[index]
                index += 1
                switch symbol {
                case ",", ";", ":", " ", "!": return symbol == "!" ? "" : " "
                case "\\": return "\n"
                default: return String(symbol)
                }
            }
            var name = ""
            while index < characters.count, characters[index].isLetter {
                name.append(characters[index])
                index += 1
            }
            switch name {
            case "frac", "dfrac", "tfrac":
                let numerator = parseArgument()
                let denominator = parseArgument()
                return MathText.fraction(numerator, denominator)
            case "sqrt":
                var degree = ""
                if index < characters.count, characters[index] == "[" {
                    index += 1
                    degree = parseSequence(until: "]")
                }
                let radicand = parseArgument()
                let root = ["3": "∛", "4": "∜"][degree] ?? (degree.isEmpty ? "√" : MathText.superscript(degree) + "√")
                return root + (radicand.count > 1 ? "(\(radicand))" : radicand)
            case "text", "textrm", "mathrm", "operatorname", "textit", "mathit", "textbf", "mathbf", "mathsf", "mathtt", "boldsymbol":
                return parseArgument()
            case "mathbb":
                let argument = parseArgument()
                return String(argument.map { MathText.blackboard[$0] ?? $0 })
            case "mathcal":
                let argument = parseArgument()
                return String(argument.map { MathText.calligraphic[$0] ?? $0 })
            case "left", "right", "big", "Big", "bigg", "Bigg", "displaystyle", "textstyle", "limits", "nolimits":
                return ""
            case "quad": return "  "
            case "qquad": return "    "
            case "overline", "bar":
                return parseArgument().map { String($0) + "\u{0305}" }.joined()
            case "hat":
                return parseArgument() + "\u{0302}"
            case "vec":
                return parseArgument() + "\u{20D7}"
            case "dot":
                return parseArgument() + "\u{0307}"
            case "tilde":
                return parseArgument() + "\u{0303}"
            default:
                if let symbol = MathText.symbols[name] { return symbol }
                if MathText.functions.contains(name) { return name }
                return "\\" + name
            }
        }
    }

    // MARK: Tables

    static func superscript(_ text: String) -> String {
        let mapped = text.compactMap { superscripts[$0] }
        return mapped.count == text.count ? String(mapped) : "^(\(text))"
    }

    static func `subscript`(_ text: String) -> String {
        let mapped = text.compactMap { subscripts[$0] }
        return mapped.count == text.count ? String(mapped) : "_(\(text))"
    }

    static func fraction(_ numerator: String, _ denominator: String) -> String {
        let vulgar: [String: String] = ["1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾", "1/5": "⅕", "1/8": "⅛"]
        if let glyph = vulgar["\(numerator)/\(denominator)"] { return glyph }
        let wrap = { (part: String) in part.count > 1 && part.contains(where: { "+-−±=<>≤≥ ".contains($0) }) ? "(\(part))" : part }
        return "\(wrap(numerator))⁄\(wrap(denominator))"
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "j": "ʲ", "k": "ᵏ",
        "l": "ˡ", "m": "ᵐ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "z": "ᶻ",
        "T": "ᵀ", "*": "*", "′": "′", "'": "′",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ",
        "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
        "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    /// Binary operators and relations get spaces around them, as TeX does.
    private static let operatorSpacing: [Character: String] = ["=": " = ", "+": " + ", "<": " < ", ">": " > ", "-": " − "]

    private static let functions: Set<String> = ["sin", "cos", "tan", "log", "ln", "exp", "max", "min", "lim", "det", "dim", "gcd", "mod", "arg", "deg"]

    private static let blackboard: [Character: Character] = ["N": "ℕ", "Z": "ℤ", "Q": "ℚ", "R": "ℝ", "C": "ℂ", "P": "ℙ", "H": "ℍ"]
    private static let calligraphic: [Character: Character] = ["L": "ℒ", "H": "ℋ", "F": "ℱ", "B": "ℬ", "E": "ℰ", "M": "ℳ", "O": "𝒪", "P": "𝒫", "A": "𝒜", "C": "𝒞", "N": "𝒩", "S": "𝒮"]

    private static let symbols: [String: String] = [
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ",
        "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators and relations
        "times": " × ", "cdot": " · ", "div": " ÷ ", "pm": " ± ", "mp": " ∓ ", "ast": "∗", "star": "⋆", "circ": "∘",
        "leq": " ≤ ", "le": " ≤ ", "geq": " ≥ ", "ge": " ≥ ", "neq": " ≠ ", "ne": " ≠ ", "approx": " ≈ ",
        "equiv": " ≡ ", "sim": " ∼ ", "simeq": " ≃ ", "cong": " ≅ ", "propto": " ∝ ", "ll": " ≪ ", "gg": " ≫ ",
        "in": " ∈ ", "notin": " ∉ ", "ni": " ∋ ", "subset": " ⊂ ", "subseteq": " ⊆ ", "supset": " ⊃ ", "supseteq": " ⊇ ",
        "cup": " ∪ ", "cap": " ∩ ", "setminus": " ∖ ", "emptyset": "∅", "varnothing": "∅",
        "land": " ∧ ", "wedge": " ∧ ", "lor": " ∨ ", "vee": " ∨ ", "lnot": "¬", "neg": "¬", "oplus": " ⊕ ", "otimes": " ⊗ ",
        "forall": "∀", "exists": "∃", "nexists": "∄", "partial": "∂", "nabla": "∇", "infty": "∞",
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "oint": "∮",
        "to": " → ", "rightarrow": " → ", "leftarrow": " ← ", "gets": " ← ", "leftrightarrow": " ↔ ",
        "Rightarrow": " ⇒ ", "implies": " ⇒ ", "Leftarrow": " ⇐ ", "Leftrightarrow": " ⇔ ", "iff": " ⇔ ",
        "mapsto": " ↦ ", "uparrow": "↑", "downarrow": "↓",
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
        "mid": " ∣ ", "parallel": " ∥ ", "perp": " ⊥ ", "angle": "∠", "triangle": "△", "prime": "′",
        "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "degree": "°", "top": "⊤", "bot": "⊥",
        "lbrace": "{", "rbrace": "}", "vert": "|", "Vert": "‖",
    ]
}

/// Emoji for GitHub-style `:shortcodes:`.
nonisolated enum Emoji {
    /// The emoji for a shortcode: GitHub's common aliases first, then any emoji whose Unicode
    /// name the code spells (`:rocket:` → ROCKET → 🚀).
    static func character(forShortcode code: String) -> String? {
        if let alias = aliases[code] { return alias }
        let name = code.replacingOccurrences(of: "_", with: " ").uppercased()
        guard let converted = "\\N{\(name)}".applyingTransform(StringTransform("Name-Any"), reverse: false),
              !converted.contains("\\N{"), converted.count == 1,
              converted.unicodeScalars.first?.properties.isEmoji == true,
              converted.unicodeScalars.first.map({ $0.value > 0x7F }) == true else { return nil }
        return converted
    }

    private static let aliases: [String: String] = [
        "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎", "smile": "😄", "smiley": "😃", "grin": "😁",
        "laughing": "😆", "joy": "😂", "wink": "😉", "blush": "😊", "heart_eyes": "😍", "sweat_smile": "😅",
        "thinking": "🤔", "neutral_face": "😐", "confused": "😕", "cry": "😢", "sob": "😭", "angry": "😠",
        "scream": "😱", "sunglasses": "😎", "slightly_smiling_face": "🙂", "upside_down_face": "🙃", "facepalm": "🤦",
        "shrug": "🤷", "tada": "🎉", "sparkles": "✨", "fire": "🔥", "boom": "💥", "zap": "⚡", "star": "⭐",
        "star2": "🌟", "heart": "❤️", "broken_heart": "💔", "100": "💯", "ok_hand": "👌", "clap": "👏",
        "wave": "👋", "pray": "🙏", "muscle": "💪", "eyes": "👀", "raised_hands": "🙌", "point_right": "👉",
        "point_left": "👈", "point_up": "☝️", "point_down": "👇", "v": "✌️", "white_check_mark": "✅",
        "heavy_check_mark": "✔️", "x": "❌", "heavy_multiplication_x": "✖️", "warning": "⚠️", "no_entry": "⛔",
        "no_entry_sign": "🚫", "question": "❓", "exclamation": "❗", "bangbang": "‼️", "information_source": "ℹ️",
        "bulb": "💡", "memo": "📝", "pencil": "📝", "pencil2": "✏️", "book": "📖", "books": "📚", "bookmark": "🔖",
        "link": "🔗", "lock": "🔒", "unlock": "🔓", "key": "🔑", "mag": "🔍", "gear": "⚙️", "wrench": "🔧",
        "hammer": "🔨", "hammer_and_wrench": "🛠️", "package": "📦", "construction": "🚧", "rotating_light": "🚨",
        "bug": "🐛", "beetle": "🐞", "rocket": "🚀", "chart_with_upwards_trend": "📈", "chart_with_downwards_trend": "📉",
        "calendar": "📆", "date": "📅", "clock": "🕐", "hourglass": "⌛", "stopwatch": "⏱️", "art": "🎨",
        "lipstick": "💄", "recycle": "♻️", "truck": "🚚", "arrow_up": "⬆️", "arrow_down": "⬇️",
        "arrow_right": "➡️", "arrow_left": "⬅️", "heavy_plus_sign": "➕", "heavy_minus_sign": "➖",
        "fast_forward": "⏩", "rewind": "⏪", "white_circle": "⚪", "red_circle": "🔴", "large_blue_circle": "🔵",
        "green_heart": "💚", "blue_heart": "💙", "purple_heart": "💜", "yellow_heart": "💛", "coffee": "☕",
        "beer": "🍺", "pizza": "🍕", "cake": "🍰", "gift": "🎁", "trophy": "🏆", "medal": "🏅", "crown": "👑",
        "gem": "💎", "moneybag": "💰", "dollar": "💵", "earth_americas": "🌎", "globe_with_meridians": "🌐",
        "sunny": "☀️", "cloud": "☁️", "umbrella": "☔", "snowflake": "❄️", "rainbow": "🌈", "seedling": "🌱",
        "evergreen_tree": "🌲", "cat": "🐱", "dog": "🐶", "penguin": "🐧", "snake": "🐍", "crab": "🦀",
        "whale": "🐳", "octocat": "🐙", "robot": "🤖", "ghost": "👻", "skull": "💀", "alien": "👽",
        "poop": "💩", "hankey": "💩", "see_no_evil": "🙈", "speech_balloon": "💬", "thought_balloon": "💭",
        "mailbox": "📫", "email": "📧", "phone": "📱", "computer": "💻", "keyboard": "⌨️", "floppy_disk": "💾",
        "cd": "💿", "file_folder": "📁", "open_file_folder": "📂", "page_facing_up": "📄", "clipboard": "📋",
        "pushpin": "📌", "paperclip": "📎", "scissors": "✂️", "triangular_flag_on_post": "🚩", "checkered_flag": "🏁",
        "new": "🆕", "free": "🆓", "up": "🆙", "cool": "🆒", "sos": "🆘", "abc": "🔤", "1234": "🔢",
    ]
}
