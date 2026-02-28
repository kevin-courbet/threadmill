import AppKit

enum SyntaxHighlighter {
    enum Theme {
        static let keyword = NSColor(hex: 0xCBA6F7)
        static let string = NSColor(hex: 0xA6E3A1)
        static let comment = NSColor(hex: 0x6C7086)
        static let number = NSColor(hex: 0xFAB387)
        static let type = NSColor(hex: 0x89DCEB)
        static let function = NSColor(hex: 0x89B4FA)
        static let `operator` = NSColor(hex: 0x94E2D5)
        static let background = NSColor(hex: 0x1E1E2E)
        static let defaultText = NSColor(hex: 0xCDD6F4)
        static let font = NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    struct Rule {
        let pattern: String
        let options: NSRegularExpression.Options
        let color: NSColor
    }

    static func highlight(_ text: String, language: CodeLanguage) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: Theme.font,
                .foregroundColor: Theme.defaultText,
            ]
        )

        let fullRange = NSRange(text.startIndex..., in: text)
        for rule in rules(for: language) {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
                continue
            }

            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let matchRange = match?.range else {
                    return
                }
                attributed.addAttribute(.foregroundColor, value: rule.color, range: matchRange)
            }
        }

        return attributed
    }

    private static func rules(for language: CodeLanguage) -> [Rule] {
        var rules: [Rule] = [
            Rule(pattern: #"\b\d+(?:\.\d+)?\b"#, options: [], color: Theme.number),
            Rule(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, options: [], color: Theme.type),
            Rule(pattern: #"\b[a-zA-Z_][a-zA-Z0-9_]*\s*(?=\()"#, options: [], color: Theme.function),
            Rule(pattern: #"[-+*/%=!<>|&^~?:]+"#, options: [], color: Theme.operator),
        ]

        if let keywordPattern = keywordPattern(for: language) {
            rules.append(Rule(pattern: keywordPattern, options: [], color: Theme.keyword))
        }

        rules.append(contentsOf: [
            Rule(pattern: "\"\"\"[\\s\\S]*?\"\"\"", options: [], color: Theme.string),
            Rule(pattern: "'''[\\s\\S]*?'''", options: [], color: Theme.string),
            Rule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", options: [], color: Theme.string),
            Rule(pattern: "'(?:\\\\.|[^'\\\\])*'", options: [], color: Theme.string),
            Rule(pattern: "`(?:\\\\.|[^`\\\\])*`", options: [], color: Theme.string),
        ])

        rules.append(contentsOf: commentRules(for: language))
        return rules
    }

    private static func commentRules(for language: CodeLanguage) -> [Rule] {
        var rules: [Rule] = []

        if supportsSlashComments(language) {
            rules.append(Rule(pattern: #"//.*$"#, options: [.anchorsMatchLines], color: Theme.comment))
            rules.append(Rule(pattern: #"/\*[\s\S]*?\*/"#, options: [], color: Theme.comment))
        }

        if supportsHashComments(language) {
            rules.append(Rule(pattern: #"#.*$"#, options: [.anchorsMatchLines], color: Theme.comment))
        }

        if language == .html {
            rules.append(Rule(pattern: #"<!--[\s\S]*?-->"#, options: [], color: Theme.comment))
        }

        return rules
    }

    private static func keywordPattern(for language: CodeLanguage) -> String? {
        let keywords: [String]

        switch language {
        case .swift:
            keywords = [
                "func", "let", "var", "if", "else", "guard", "return", "import", "struct", "class", "enum", "protocol", "extension", "case", "switch", "for", "while", "do", "try", "catch", "throw", "throws", "async", "await", "self", "Self", "nil", "true", "false", "some", "any", "typealias", "init", "deinit", "override", "final", "static", "private", "public", "internal", "fileprivate", "open", "weak", "unowned", "lazy",
            ]

        case .javascript, .typescript, .jsx, .tsx:
            keywords = [
                "function", "const", "let", "var", "if", "else", "return", "import", "export", "from", "class", "extends", "new", "this", "async", "await", "try", "catch", "throw", "for", "while", "do", "switch", "case", "break", "continue", "default", "typeof", "instanceof", "in", "of", "yield", "null", "undefined", "true", "false",
            ]

        case .python:
            keywords = [
                "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "try", "except", "raise", "with", "yield", "lambda", "pass", "break", "continue", "and", "or", "not", "in", "is", "None", "True", "False", "self", "async", "await",
            ]

        case .rust:
            keywords = [
                "fn", "let", "mut", "if", "else", "match", "return", "use", "mod", "pub", "struct", "enum", "impl", "trait", "for", "while", "loop", "break", "continue", "self", "Self", "super", "crate", "async", "await", "move", "ref", "true", "false", "as", "type", "where", "unsafe", "dyn", "const", "static", "extern",
            ]

        case .go:
            keywords = [
                "func", "var", "const", "if", "else", "for", "range", "return", "import", "package", "type", "struct", "interface", "map", "chan", "go", "defer", "select", "case", "switch", "break", "continue", "true", "false", "nil", "make", "len", "append",
            ]

        case .plainText:
            return nil

        default:
            keywords = [
                "if", "else", "for", "while", "return", "import", "from", "class", "struct", "enum", "function", "func", "let", "var", "const", "true", "false", "null", "nil", "async", "await", "try", "catch", "throw", "switch", "case", "break", "continue",
            ]
        }

        let escaped = keywords.map(NSRegularExpression.escapedPattern(for:))
        return #"\b(?:"# + escaped.joined(separator: "|") + #")\b"#
    }

    private static func supportsSlashComments(_ language: CodeLanguage) -> Bool {
        switch language {
        case .python, .yaml, .toml, .bash, .plainText:
            return false
        default:
            return true
        }
    }

    private static func supportsHashComments(_ language: CodeLanguage) -> Bool {
        switch language {
        case .python, .yaml, .toml, .bash, .ruby, .perl, .dockerfile:
            return true
        default:
            return false
        }
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
