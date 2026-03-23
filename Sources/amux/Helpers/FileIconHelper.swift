import AppKit

struct FileIconInfo {
    let symbolName: String
    let color: NSColor

    static var directory: FileIconInfo {
        FileIconInfo(symbolName: "folder.fill", color: Theme.tertiaryText)
    }

    static let defaultFile = FileIconInfo(
        symbolName: "doc",
        color: NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1.0)
    )

    /// Returns icon info for a file based on its name and extension.
    static func forFile(named name: String) -> FileIconInfo {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()

        // Check special filenames first
        let lower = name.lowercased()
        if let special = specialFilenames[lower] { return special }

        // Then extension
        if let info = extensionMap[ext] { return info }

        return defaultFile
    }

    // MARK: - Extension Map

    private static let extensionMap: [String: FileIconInfo] = {
        var map = [String: FileIconInfo]()

        // Swift
        let swift = FileIconInfo(symbolName: "swift", color: NSColor(srgbRed: 0.94, green: 0.32, blue: 0.22, alpha: 1.0))
        map["swift"] = swift

        // JavaScript
        let js = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.97, green: 0.84, blue: 0.18, alpha: 1.0))
        for e in ["js", "jsx", "mjs", "cjs"] { map[e] = js }

        // TypeScript
        let ts = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.19, green: 0.47, blue: 0.84, alpha: 1.0))
        for e in ["ts", "tsx"] { map[e] = ts }

        // Python
        let py = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.25, green: 0.55, blue: 0.77, alpha: 1.0))
        for e in ["py", "pyw", "pyi"] { map[e] = py }

        // Ruby
        let rb = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.80, green: 0.20, blue: 0.18, alpha: 1.0))
        for e in ["rb", "rake", "gemspec"] { map[e] = rb }

        // Go
        let go = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.00, green: 0.68, blue: 0.85, alpha: 1.0))
        map["go"] = go

        // Rust
        let rs = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.87, green: 0.42, blue: 0.20, alpha: 1.0))
        map["rs"] = rs

        // C / Objective-C
        let c = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.33, green: 0.49, blue: 0.68, alpha: 1.0))
        for e in ["c", "h", "m", "mm"] { map[e] = c }

        // C++
        let cpp = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.00, green: 0.35, blue: 0.61, alpha: 1.0))
        for e in ["cpp", "hpp", "cc", "cxx", "hxx"] { map[e] = cpp }

        // Java / Kotlin
        let java = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.69, green: 0.40, blue: 0.22, alpha: 1.0))
        for e in ["java", "kt", "kts"] { map[e] = java }

        // C#
        let cs = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.38, green: 0.22, blue: 0.72, alpha: 1.0))
        map["cs"] = cs

        // Lua
        let lua = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.00, green: 0.00, blue: 0.80, alpha: 1.0))
        map["lua"] = lua

        // PHP
        let php = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.47, green: 0.44, blue: 0.70, alpha: 1.0))
        map["php"] = php

        // Zig
        let zig = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.95, green: 0.65, blue: 0.15, alpha: 1.0))
        map["zig"] = zig

        // Elixir / Erlang
        let elixir = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.44, green: 0.28, blue: 0.57, alpha: 1.0))
        for e in ["ex", "exs", "erl"] { map[e] = elixir }

        // HTML
        let html = FileIconInfo(symbolName: "globe", color: NSColor(srgbRed: 0.89, green: 0.30, blue: 0.15, alpha: 1.0))
        for e in ["html", "htm"] { map[e] = html }

        // CSS / Styles
        let css = FileIconInfo(symbolName: "paintbrush", color: NSColor(srgbRed: 0.22, green: 0.36, blue: 0.85, alpha: 1.0))
        for e in ["css", "scss", "sass", "less", "styl"] { map[e] = css }

        // JSON
        let json = FileIconInfo(symbolName: "doc.text", color: NSColor(srgbRed: 0.96, green: 0.77, blue: 0.09, alpha: 1.0))
        for e in ["json", "jsonc", "jsonl"] { map[e] = json }

        // XML / SVG
        let xml = FileIconInfo(symbolName: "chevron.left.forwardslash.chevron.right", color: NSColor(srgbRed: 0.89, green: 0.55, blue: 0.15, alpha: 1.0))
        for e in ["xml", "plist", "xib", "storyboard", "svg"] { map[e] = xml }

        // YAML
        let yaml = FileIconInfo(symbolName: "gearshape", color: NSColor(srgbRed: 0.80, green: 0.20, blue: 0.25, alpha: 1.0))
        for e in ["yml", "yaml"] { map[e] = yaml }

        // TOML
        let toml = FileIconInfo(symbolName: "gearshape", color: NSColor(srgbRed: 0.62, green: 0.47, blue: 0.35, alpha: 1.0))
        map["toml"] = toml

        // INI / Config
        let ini = FileIconInfo(symbolName: "gearshape", color: NSColor(srgbRed: 0.55, green: 0.55, blue: 0.60, alpha: 1.0))
        for e in ["ini", "conf", "cfg", "env", "properties"] { map[e] = ini }

        // Shell
        let shell = FileIconInfo(symbolName: "terminal", color: NSColor(srgbRed: 0.30, green: 0.69, blue: 0.31, alpha: 1.0))
        for e in ["sh", "bash", "zsh", "fish", "csh", "ksh"] { map[e] = shell }

        // Markdown / Docs
        let md = FileIconInfo(symbolName: "book", color: NSColor(srgbRed: 0.22, green: 0.47, blue: 0.84, alpha: 1.0))
        for e in ["md", "markdown", "mdx", "rst", "adoc"] { map[e] = md }

        // Plain text
        let txt = FileIconInfo(symbolName: "doc.text", color: NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1.0))
        for e in ["txt", "text", "log"] { map[e] = txt }

        // SQL
        let sql = FileIconInfo(symbolName: "cylinder", color: NSColor(srgbRed: 0.22, green: 0.47, blue: 0.74, alpha: 1.0))
        map["sql"] = sql

        // GraphQL
        let gql = FileIconInfo(symbolName: "arrow.triangle.branch", color: NSColor(srgbRed: 0.88, green: 0.00, blue: 0.56, alpha: 1.0))
        for e in ["graphql", "gql"] { map[e] = gql }

        // Images
        let img = FileIconInfo(symbolName: "photo", color: NSColor(srgbRed: 0.66, green: 0.33, blue: 0.97, alpha: 1.0))
        for e in ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "ico", "icns"] { map[e] = img }

        // Protobuf
        let proto = FileIconInfo(symbolName: "doc.text", color: NSColor(srgbRed: 0.40, green: 0.60, blue: 0.40, alpha: 1.0))
        map["proto"] = proto

        // Lock files
        let lock = FileIconInfo(symbolName: "lock", color: NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1.0))
        map["lock"] = lock

        // Diff / Patch
        let diff = FileIconInfo(symbolName: "doc.text", color: NSColor(srgbRed: 0.40, green: 0.72, blue: 0.40, alpha: 1.0))
        for e in ["diff", "patch"] { map[e] = diff }

        return map
    }()

    // MARK: - Special Filenames

    private static let specialFilenames: [String: FileIconInfo] = [
        "makefile": FileIconInfo(symbolName: "hammer", color: NSColor(srgbRed: 0.89, green: 0.55, blue: 0.15, alpha: 1.0)),
        "dockerfile": FileIconInfo(symbolName: "shippingbox", color: NSColor(srgbRed: 0.09, green: 0.56, blue: 0.84, alpha: 1.0)),
        "podfile": FileIconInfo(symbolName: "shippingbox", color: NSColor(srgbRed: 0.89, green: 0.30, blue: 0.15, alpha: 1.0)),
        "gemfile": FileIconInfo(symbolName: "shippingbox", color: NSColor(srgbRed: 0.80, green: 0.20, blue: 0.18, alpha: 1.0)),
        "rakefile": FileIconInfo(symbolName: "hammer", color: NSColor(srgbRed: 0.80, green: 0.20, blue: 0.18, alpha: 1.0)),
        "package.swift": FileIconInfo(symbolName: "shippingbox", color: NSColor(srgbRed: 0.94, green: 0.32, blue: 0.22, alpha: 1.0)),
        "cargo.toml": FileIconInfo(symbolName: "shippingbox", color: NSColor(srgbRed: 0.87, green: 0.42, blue: 0.20, alpha: 1.0)),
        "go.mod": FileIconInfo(symbolName: "shippingbox", color: NSColor(srgbRed: 0.00, green: 0.68, blue: 0.85, alpha: 1.0)),
        ".gitignore": FileIconInfo(symbolName: "eye.slash", color: NSColor(srgbRed: 0.94, green: 0.32, blue: 0.22, alpha: 1.0)),
        ".gitattributes": FileIconInfo(symbolName: "arrow.triangle.branch", color: NSColor(srgbRed: 0.94, green: 0.32, blue: 0.22, alpha: 1.0)),
        "license": FileIconInfo(symbolName: "doc.text", color: NSColor(srgbRed: 0.96, green: 0.77, blue: 0.09, alpha: 1.0)),
        "readme.md": FileIconInfo(symbolName: "book", color: NSColor(srgbRed: 0.22, green: 0.47, blue: 0.84, alpha: 1.0)),
    ]
}
