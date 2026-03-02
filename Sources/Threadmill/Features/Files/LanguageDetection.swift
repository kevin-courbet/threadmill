import Foundation
import CodeEditLanguages

enum LanguageDetection {
    /// Map file path to CodeLanguage via extension (or filename for special cases)
    static func language(for filePath: String) -> CodeLanguage {
        let url = URL(fileURLWithPath: filePath)
        let fileName = url.lastPathComponent.lowercased()

        // Special filenames
        if fileName == "dockerfile" { return .dockerfile }
        if fileName == "makefile" || fileName == "gnumakefile" { return CodeLanguage.default }

        let ext = url.pathExtension.lowercased()
        if let lang = languageFromExtension(ext) {
            return codeLanguageFromString(lang)
        }
        return CodeLanguage.default
    }

    /// Convert file extension or language string to CodeLanguage
    static func codeLanguageFromString(_ lang: String) -> CodeLanguage {
        if let mapped = languageFromExtension(lang.lowercased()) {
            return codeLanguageFromLanguageString(mapped)
        }
        return codeLanguageFromLanguageString(lang)
    }

    private static func codeLanguageFromLanguageString(_ lang: String) -> CodeLanguage {
        switch lang.lowercased() {
        case "swift": return .swift
        case "javascript": return .javascript
        case "jsx": return .jsx
        case "typescript": return .typescript
        case "tsx": return .tsx
        case "python": return .python
        case "ruby": return .ruby
        case "java": return .java
        case "kotlin": return .kotlin
        case "c": return .c
        case "cpp": return .cpp
        case "csharp": return .cSharp
        case "go": return .go
        case "gomod": return .goMod
        case "rust": return .rust
        case "php": return .php
        case "html": return .html
        case "css", "scss", "sass", "less": return .css
        case "json": return .json
        case "markdown": return .markdown
        case "bash": return .bash
        case "sql": return .sql
        case "yaml": return .yaml
        case "dockerfile": return .dockerfile
        case "lua": return .lua
        case "perl": return .perl
        case "elixir": return .elixir
        case "haskell": return .haskell
        case "scala": return .scala
        case "dart": return .dart
        case "julia": return .julia
        case "toml": return .toml
        case "zig": return .zig
        case "verilog": return .verilog
        case "objc", "objective-c": return .objc
        case "ocaml": return .ocaml
        case "regex": return .regex
        case "jsdoc": return .jsdoc
        case "agda": return .agda
        default: return CodeLanguage.default
        }
    }

    private static let extensionMapping: [String: String] = [
        "swift": "swift",
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "ts": "typescript",
        "tsx": "tsx",
        "py": "python",
        "pyw": "python",
        "pyi": "python",
        "rb": "ruby",
        "erb": "ruby",
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "c": "c",
        "h": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "hh": "cpp",
        "hxx": "cpp",
        "cs": "csharp",
        "go": "go",
        "rs": "rust",
        "php": "php",
        "html": "html",
        "htm": "html",
        "css": "css",
        "scss": "css",
        "sass": "css",
        "less": "css",
        "json": "json",
        "xml": "html",
        "svg": "html",
        "md": "markdown",
        "markdown": "markdown",
        "mdx": "markdown",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "sql": "sql",
        "yaml": "yaml",
        "yml": "yaml",
        "dockerfile": "dockerfile",
        "lua": "lua",
        "pl": "perl",
        "pm": "perl",
        "ex": "elixir",
        "exs": "elixir",
        "hs": "haskell",
        "scala": "scala",
        "dart": "dart",
        "toml": "toml",
        "zig": "zig",
    ]

    private static func languageFromExtension(_ ext: String) -> String? {
        extensionMapping[ext]
    }
}
