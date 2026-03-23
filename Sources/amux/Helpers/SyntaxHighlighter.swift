import AppKit

final class SyntaxHighlighter {
    private let defaultFont: NSFont

    private static let maxHighlightLength = 120_000

    private static let cLikeExtensions: Set<String> = [
        "swift", "js", "ts", "tsx", "jsx", "java", "kt",
        "c", "h", "m", "mm", "cpp", "hpp", "rs", "go",
        "css", "html", "json", "jsonc",
    ]

    private static let hashCommentExtensions: Set<String> = [
        "py", "rb", "sh", "bash", "zsh", "yml", "yaml", "toml",
    ]

    private static let markupExtensions: Set<String> = [
        "md", "markdown", "html", "xml",
    ]

    private static let keywords: Set<String> = [
        "func", "function", "def", "fn", "class", "struct", "enum", "protocol",
        "interface", "import", "from", "return", "if", "else", "for", "while",
        "do", "switch", "case", "break", "continue", "var", "let", "const",
        "val", "pub", "private", "public", "static", "override", "guard",
        "throw", "throws", "try", "catch", "finally", "async", "await",
        "self", "super", "nil", "null", "None", "true", "false", "True", "False",
        "in", "is", "as", "where", "with", "yield", "lambda", "pass",
        "type", "typealias", "typedef", "extension", "impl", "package",
    ]

    init(font: NSFont) {
        self.defaultFont = font
    }

    func highlight(textStorage: NSTextStorage, fileExtension: String) {
        let string = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(), range: fullRange)

        guard string.length <= Self.maxHighlightLength else {
            textStorage.endEditing()
            return
        }

        let text = string as String
        let ext = fileExtension.lowercased()

        for pattern in commentPatterns(for: ext) {
            apply(pattern: pattern, to: textStorage, in: text, color: commentColor())
        }

        for pattern in stringPatterns(for: ext) {
            apply(pattern: pattern, to: textStorage, in: text, color: stringColor())
        }

        apply(
            pattern: #"\b\d+(\.\d+)?\b"#,
            to: textStorage,
            in: text,
            color: numberColor()
        )
        apply(
            pattern: "\\b(" + Self.keywords.sorted().joined(separator: "|") + ")\\b",
            to: textStorage,
            in: text,
            color: keywordColor()
        )

        if !Self.markupExtensions.contains(ext) {
            apply(
                pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#,
                to: textStorage,
                in: text,
                color: typeColor()
            )
        }

        textStorage.endEditing()
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: Theme.primaryText,
            .font: defaultFont,
        ]
    }

    private func keywordColor() -> NSColor {
        Theme.primary.blended(withFraction: 0.25, of: Theme.primaryText) ?? Theme.primary
    }

    private func stringColor() -> NSColor {
        Theme.secondary.blended(withFraction: 0.2, of: Theme.primaryText) ?? Theme.secondary
    }

    private func commentColor() -> NSColor {
        Theme.tertiaryText
    }

    private func numberColor() -> NSColor {
        Theme.primaryContainer.blended(withFraction: 0.35, of: Theme.primaryText)
            ?? Theme.primaryContainer
    }

    private func typeColor() -> NSColor {
        Theme.onSurfaceVariant
    }

    private func commentPatterns(for fileExtension: String) -> [String] {
        var patterns: [String] = []

        if Self.cLikeExtensions.contains(fileExtension) || Self.markupExtensions.contains(fileExtension) {
            patterns.append(#"//.*$"#)
            patterns.append(#"/\*[\s\S]*?\*/"#)
        }

        if Self.hashCommentExtensions.contains(fileExtension) || fileExtension == "py" {
            patterns.append(#"#.*$"#)
        }

        if Self.markupExtensions.contains(fileExtension) {
            patterns.append(#"<!--[\s\S]*?-->"#)
        }

        return patterns
    }

    private func stringPatterns(for fileExtension: String) -> [String] {
        var patterns = [
            #""(?:[^"\\]|\\.)*""#,
            #"'(?:[^'\\]|\\.)*'"#,
        ]

        if Self.cLikeExtensions.contains(fileExtension) || Self.markupExtensions.contains(fileExtension) {
            patterns.append(#"`(?:[^`\\]|\\.)*`"#)
        }

        return patterns
    }

    private func apply(
        pattern: String,
        to textStorage: NSTextStorage,
        in text: String,
        color: NSColor
    ) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else { return }

        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )

        for match in matches {
            textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
