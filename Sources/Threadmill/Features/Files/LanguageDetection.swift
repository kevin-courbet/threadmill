import Foundation

enum CodeLanguage {
    case swift
    case javascript
    case jsx
    case typescript
    case tsx
    case python
    case ruby
    case java
    case kotlin
    case c
    case cpp
    case cSharp
    case go
    case rust
    case php
    case html
    case css
    case json
    case yaml
    case toml
    case markdown
    case bash
    case sql
    case lua
    case perl
    case elixir
    case haskell
    case scala
    case dart
    case zig
    case dockerfile
    case plainText
}

enum LanguageDetection {
    private static let extensionMap: [String: CodeLanguage] = [
        "swift": .swift,
        "js": .javascript,
        "jsx": .jsx,
        "ts": .typescript,
        "tsx": .tsx,
        "py": .python,
        "rb": .ruby,
        "java": .java,
        "kt": .kotlin,
        "c": .c,
        "cpp": .cpp,
        "h": .cpp,
        "hpp": .cpp,
        "cs": .cSharp,
        "go": .go,
        "rs": .rust,
        "php": .php,
        "html": .html,
        "css": .css,
        "scss": .css,
        "json": .json,
        "yaml": .yaml,
        "yml": .yaml,
        "toml": .toml,
        "xml": .html,
        "markdown": .markdown,
        "md": .markdown,
        "bash": .bash,
        "sh": .bash,
        "zsh": .bash,
        "sql": .sql,
        "lua": .lua,
        "pl": .perl,
        "perl": .perl,
        "elixir": .elixir,
        "ex": .elixir,
        "exs": .elixir,
        "hs": .haskell,
        "scala": .scala,
        "dart": .dart,
        "zig": .zig,
    ]

    static func language(for filePath: String) -> CodeLanguage {
        let url = URL(fileURLWithPath: filePath)
        let fileName = url.lastPathComponent.lowercased()
        if fileName == "dockerfile" {
            return .dockerfile
        }

        let ext = url.pathExtension.lowercased()
        return extensionMap[ext] ?? .plainText
    }
}
