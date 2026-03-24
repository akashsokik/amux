import Foundation
import SwiftTreeSitter

import TreeSitterSwift
import TreeSitterRust
import TreeSitterJSON
import TreeSitterHTML
import TreeSitterRuby
import TreeSitterJava
import TreeSitterTypeScript
import TreeSitterGo
import TreeSitterCPP
import TreeSitterBash
import TreeSitterMarkdown

final class TreeSitterManager {
    static let shared = TreeSitterManager()

    private var cache: [String: LanguageConfiguration] = [:]

    /// Maps file extensions to language identifiers used for configuration lookup.
    private let extensionToLanguage: [String: String] = [
        // Swift
        "swift": "Swift",
        // Rust
        "rs": "Rust",
        // JSON
        "json": "JSON",
        "jsonc": "JSON",
        // HTML
        "html": "HTML",
        "htm": "HTML",
        // Ruby
        "rb": "Ruby",
        // Java
        "java": "Java",
        // TypeScript
        "ts": "TypeScript",
        "tsx": "TypeScript",
        // Go
        "go": "Go",
        // C++
        "cpp": "Cpp",
        "hpp": "Cpp",
        "cc": "Cpp",
        "cxx": "Cpp",
        "mm": "Cpp",
        // Bash
        "sh": "Bash",
        "bash": "Bash",
        "zsh": "Bash",
        // Markdown
        "md": "Markdown",
        "markdown": "Markdown",
    ]

    private init() {}

    /// Returns a `LanguageConfiguration` for the given file extension, or nil if unsupported.
    func configuration(for fileExtension: String) -> LanguageConfiguration? {
        let ext = fileExtension.lowercased()

        guard let languageName = extensionToLanguage[ext] else {
            return nil
        }

        if let cached = cache[languageName] {
            return cached
        }

        let config = makeConfiguration(for: languageName)
        if let config = config {
            cache[languageName] = config
        }
        return config
    }

    /// Returns the language name for a given file extension, or nil if unsupported.
    func languageName(for fileExtension: String) -> String? {
        return extensionToLanguage[fileExtension.lowercased()]
    }

    private func makeConfiguration(for languageName: String) -> LanguageConfiguration? {
        switch languageName {
        case "Swift":
            return try? LanguageConfiguration(tree_sitter_swift(), name: "Swift")
        case "Rust":
            return try? LanguageConfiguration(tree_sitter_rust(), name: "Rust")
        case "JSON":
            return try? LanguageConfiguration(tree_sitter_json(), name: "JSON")
        case "HTML":
            return try? LanguageConfiguration(tree_sitter_html(), name: "HTML")
        case "Ruby":
            return try? LanguageConfiguration(tree_sitter_ruby(), name: "Ruby")
        case "Java":
            return try? LanguageConfiguration(tree_sitter_java(), name: "Java")
        case "TypeScript":
            return try? LanguageConfiguration(tree_sitter_typescript(), name: "TypeScript")
        case "Go":
            return try? LanguageConfiguration(tree_sitter_go(), name: "Go")
        case "Cpp":
            return try? LanguageConfiguration(tree_sitter_cpp(), name: "Cpp")
        case "Bash":
            return try? LanguageConfiguration(tree_sitter_bash(), name: "Bash")
        case "Markdown":
            return try? LanguageConfiguration(tree_sitter_markdown(), name: "Markdown")
        default:
            return nil
        }
    }
}
