# Tree-Sitter Syntax Highlighting Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace regex-based syntax highlighting with tree-sitter AST-based highlighting using SwiftTreeSitter + Neon.

**Architecture:** Add SwiftTreeSitter and Neon as SPM dependencies alongside 15 tree-sitter grammar packages. A new `TreeSitterManager` singleton maps file extensions to `LanguageConfiguration` instances. `EditorTextContentView` replaces its `SyntaxHighlighter` with Neon's `TextViewHighlighter` which hooks into the NSTextView automatically.

**Tech Stack:** SwiftTreeSitter, Neon (ChimeHQ), tree-sitter grammar SPM packages, AppKit NSTextView

**Design doc:** `docs/plans/2026-03-24-tree-sitter-editor-design.md`

---

### Task 1: Add SPM Dependencies to Package.swift

**Files:**
- Modify: `Package.swift`

**Step 1: Update Package.swift with all dependencies**

The swift-tools-version must be bumped to 6.0 because Neon requires it. Add all tree-sitter grammar packages and wire them into the `amux` target.

Note: Some grammar packages may not have stable tags with SPM support. If a package fails to resolve, use `branch: "main"` or find the correct tag by checking the repo. The TypeScript grammar provides two products (TypeScript and TSX) from a single package. Some grammars (like tree-sitter-markdown) may provide multiple products. Resolve any dependency issues iteratively.

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "amux",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Tree-sitter core
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.9.0"),
        .package(url: "https://github.com/ChimeHQ/Neon", branch: "main"),

        // Grammars
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", branch: "with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java", branch: "master"),
        .package(url: "https://github.com/MDeiml/tree-sitter-markdown", branch: "split_parser"),
    ],
    targets: [
        .target(
            name: "CGhostty",
            path: "Sources/CGhostty",
            publicHeadersPath: "include"
        ),

        .executableTarget(
            name: "amux",
            dependencies: [
                "CGhostty",
                .product(name: "Neon", package: "Neon"),
                .product(name: "TreeSitterClient", package: "Neon"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "SwiftTreeSitterLayer", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypescript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCpp", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ],
            path: "Sources/amux",
            resources: [
                .copy("../../Resources/Fonts"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/vendor/ghostty-dist/macos-arm64_x86_64",
                    "-lghostty",
                    "-lc++",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
```

**Important:** The exact product names and branch/tag values above are best guesses. Many tree-sitter grammar repos have inconsistent SPM support. You MUST:
1. Try `swift package resolve` after editing
2. If a grammar fails, check its actual repo for the correct branch name, product name, or whether it has a `Package.swift` at all
3. For grammars without SPM support, skip them and note which ones are missing
4. The TypeScript package may expose products named differently (e.g., `TreeSitterTSX` separately)
5. Neon's `swift-tools-version: 6.0` requirement means the root package must also be 6.0

**Step 2: Resolve dependencies**

Run: `swift package resolve`
Expected: All packages download successfully. If any fail, fix the URL/branch/product name and re-resolve.

**Step 3: Verify build compiles**

Run: `swift build 2>&1 | head -50`
Expected: Build succeeds (warnings OK, errors not OK). Fix any Swift 6 concurrency issues by adding `@preconcurrency import` or `nonisolated(unsafe)` as needed.

**Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat: add tree-sitter and Neon SPM dependencies"
```

---

### Task 2: Create TreeSitterManager

**Files:**
- Create: `Sources/amux/Helpers/TreeSitterManager.swift`

**Step 1: Create TreeSitterManager with language registry**

```swift
import SwiftTreeSitter

// Import all grammar C functions.
// The actual import syntax depends on each grammar package's module name.
// For example: import TreeSitterSwift gives access to tree_sitter_swift()
// You may need @preconcurrency imports for Swift 6 concurrency compliance.
import TreeSitterSwift
import TreeSitterPython
import TreeSitterJavaScript
// ... etc for each grammar that resolved successfully

final class TreeSitterManager {
    static let shared = TreeSitterManager()

    private var cache: [String: LanguageConfiguration] = [:]

    private init() {}

    /// Returns the LanguageConfiguration for a given file extension, or nil if unsupported.
    func configuration(for fileExtension: String) -> LanguageConfiguration? {
        let ext = fileExtension.lowercased()
        guard let name = Self.languageName(for: ext) else { return nil }

        if let cached = cache[name] { return cached }

        guard let config = Self.makeConfig(for: name) else { return nil }
        cache[name] = config
        return config
    }

    // MARK: - Extension to language name mapping

    private static func languageName(for ext: String) -> String? {
        switch ext {
        case "swift": return "Swift"
        case "py": return "Python"
        case "js", "jsx", "mjs", "cjs": return "JavaScript"
        case "ts", "tsx": return "TypeScript"
        case "rs": return "Rust"
        case "go": return "Go"
        case "c", "h": return "C"
        case "cpp", "hpp", "cc", "cxx", "mm": return "Cpp"
        case "json", "jsonc": return "JSON"
        case "html", "htm": return "HTML"
        case "css": return "CSS"
        case "sh", "bash", "zsh": return "Bash"
        case "rb": return "Ruby"
        case "java": return "Java"
        case "md", "markdown": return "Markdown"
        default: return nil
        }
    }

    // MARK: - Language configuration factory

    private static func makeConfig(for name: String) -> LanguageConfiguration? {
        // Each branch creates a LanguageConfiguration from the grammar's C entry point.
        // The LanguageConfiguration initializer loads the language AND its bundled
        // highlights.scm query from the SPM resource bundle automatically.
        //
        // If a grammar doesn't bundle queries, you'll need to provide them manually
        // or the highlighting will produce no tokens (harmless - just no colors).
        //
        // Use try? because some grammars may fail to load.
        switch name {
        case "Swift": return try? LanguageConfiguration(tree_sitter_swift(), name: "Swift")
        case "Python": return try? LanguageConfiguration(tree_sitter_python(), name: "Python")
        case "JavaScript": return try? LanguageConfiguration(tree_sitter_javascript(), name: "JavaScript")
        case "TypeScript": return try? LanguageConfiguration(tree_sitter_typescript(), name: "TypeScript")
        case "Rust": return try? LanguageConfiguration(tree_sitter_rust(), name: "Rust")
        case "Go": return try? LanguageConfiguration(tree_sitter_go(), name: "Go")
        case "C": return try? LanguageConfiguration(tree_sitter_c(), name: "C")
        case "Cpp": return try? LanguageConfiguration(tree_sitter_cpp(), name: "Cpp")
        case "JSON": return try? LanguageConfiguration(tree_sitter_json(), name: "JSON")
        case "HTML": return try? LanguageConfiguration(tree_sitter_html(), name: "HTML")
        case "CSS": return try? LanguageConfiguration(tree_sitter_css(), name: "CSS")
        case "Bash": return try? LanguageConfiguration(tree_sitter_bash(), name: "Bash")
        case "Ruby": return try? LanguageConfiguration(tree_sitter_ruby(), name: "Ruby")
        case "Java": return try? LanguageConfiguration(tree_sitter_java(), name: "Java")
        case "Markdown": return try? LanguageConfiguration(tree_sitter_markdown(), name: "Markdown")
        default: return nil
        }
    }
}
```

**Important notes for the implementer:**
- The C function names (e.g., `tree_sitter_swift()`) depend on what the grammar package actually exports. Check each grammar's C header or Swift module to find the correct function name.
- `LanguageConfiguration` init may use a different signature in the version you resolve. Check the SwiftTreeSitter API.
- Some grammars may not bundle `highlights.scm` as SPM resources. If highlighting produces no tokens for a language, you may need to manually bundle the `.scm` file or skip that language.

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

**Step 3: Commit**

```bash
git add Sources/amux/Helpers/TreeSitterManager.swift
git commit -m "feat: add TreeSitterManager for language configuration"
```

---

### Task 3: Replace SyntaxHighlighter with Neon TextViewHighlighter

**Files:**
- Modify: `Sources/amux/Views/EditorSidebarView.swift` (lines 1389-1518, the `EditorTextContentView` class)
- Delete: `Sources/amux/Helpers/SyntaxHighlighter.swift`

**Step 1: Update EditorTextContentView to use Neon**

Replace the `highlighter: SyntaxHighlighter` property and all highlighting logic with Neon's `TextViewHighlighter`. The key changes:

1. Replace `private var highlighter: SyntaxHighlighter!` with `private var highlighter: TextViewHighlighter?`
2. Remove the `applyHighlighting()` method
3. In `setText()`, create/reconfigure the `TextViewHighlighter` based on the file extension
4. In `refreshTheme()`, invalidate/recreate the highlighter to pick up new colors
5. In `textDidChange()`, remove the `applyHighlighting()` call (Neon handles it automatically)

The updated `EditorTextContentView` should look like:

```swift
import Neon
import SwiftTreeSitter
import TreeSitterClient

class EditorTextContentView: NSView, NSTextViewDelegate {
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var highlighter: TextViewHighlighter?
    private var isBindingText = false
    private var currentFileExtension = ""

    var onTextChange: ((String) -> Void)?

    private var editorSurfaceColor: NSColor {
        Theme.sidebarBg
    }

    // ... init, setupUI unchanged except remove SyntaxHighlighter creation ...

    func setText(_ text: String, fileExtension: String, isEditable: Bool) {
        isBindingText = true
        currentFileExtension = fileExtension
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.textColor = isEditable ? Theme.primaryText : Theme.secondaryText
        isBindingText = false
        configureHighlighter()
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
    }

    func refreshTheme() {
        layer?.backgroundColor = editorSurfaceColor.cgColor
        scrollView.backgroundColor = editorSurfaceColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = editorSurfaceColor
        textView.insertionPointColor = Theme.primaryText
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.activeBg,
            .foregroundColor: Theme.primaryText,
        ]
        if textView.isEditable {
            textView.textColor = Theme.primaryText
        } else {
            textView.textColor = Theme.secondaryText
        }
        // Recreate highlighter to pick up new theme colors
        configureHighlighter()
    }

    func textDidChange(_ notification: Notification) {
        guard !isBindingText else { return }
        onTextChange?(textView.string)
        // Neon handles re-highlighting automatically via NSTextStorage delegate
    }

    private func configureHighlighter() {
        // Drop old highlighter
        highlighter = nil

        guard let langConfig = TreeSitterManager.shared.configuration(for: currentFileExtension) else {
            return
        }

        // Create the Neon TextViewHighlighter.
        // The exact API depends on the version of Neon that resolves.
        // Check Neon's README/source for the current initializer signature.
        // The core idea: pass the textView, language config, and an attribute provider
        // that maps token names to text attributes (colors).
        do {
            highlighter = try TextViewHighlighter(
                textView: textView,
                configuration: .init(
                    languageConfiguration: langConfig,
                    attributeProvider: { token in
                        Self.attributes(for: token.name)
                    },
                    languageProvider: { _ in nil },
                    locationTransformer: { _ in nil }
                )
            )
        } catch {
            print("[Editor] Failed to create highlighter: \(error)")
        }
    }

    /// Map tree-sitter token names to NSAttributedString attributes using Theme colors.
    private static func attributes(for tokenName: String) -> [NSAttributedString.Key: Any] {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let color: NSColor

        // Token names from highlights.scm queries use dot-separated hierarchies.
        // Match on prefix for broad categories.
        if tokenName.hasPrefix("keyword") {
            color = Theme.primary.blended(withFraction: 0.25, of: Theme.primaryText) ?? Theme.primary
        } else if tokenName.hasPrefix("string") {
            color = Theme.secondary.blended(withFraction: 0.2, of: Theme.primaryText) ?? Theme.secondary
        } else if tokenName.hasPrefix("comment") {
            color = Theme.tertiaryText
        } else if tokenName.hasPrefix("number") || tokenName.hasPrefix("float") {
            color = Theme.primaryContainer.blended(withFraction: 0.35, of: Theme.primaryText) ?? Theme.primaryContainer
        } else if tokenName.hasPrefix("type") {
            color = Theme.onSurfaceVariant
        } else if tokenName.hasPrefix("function") || tokenName.hasPrefix("method") {
            color = Theme.primary
        } else if tokenName.hasPrefix("operator") || tokenName.hasPrefix("punctuation") {
            color = Theme.secondaryText
        } else if tokenName.hasPrefix("constant") {
            color = Theme.secondary
        } else {
            color = Theme.primaryText
        }

        return [
            .foregroundColor: color,
            .font: font,
        ]
    }
}
```

**Important notes for the implementer:**
- The `TextViewHighlighter` initializer above is based on research but may differ from the actual API in the Neon version you resolve. Check the source/README.
- If `TextViewHighlighter` doesn't accept a `configuration` struct, look for alternative init patterns (it may take individual parameters).
- If Neon's `TextViewHighlighter` conflicts with the NSTextView delegate (currently set to `self`), you may need to forward delegate calls or use a different integration pattern. Check if Neon provides a way to work alongside an existing delegate.
- The `isRichText = false` setting on the textView may conflict with attributed string styling. You may need to change it to `true` or use Neon's temporary-attributes approach (via NSLayoutManager) which doesn't require rich text mode.

**Step 2: Delete SyntaxHighlighter.swift**

```bash
git rm Sources/amux/Helpers/SyntaxHighlighter.swift
```

**Step 3: Build and verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds with no errors referencing `SyntaxHighlighter`.

**Step 4: Commit**

```bash
git add Sources/amux/Views/EditorSidebarView.swift
git commit -m "feat: replace regex highlighter with tree-sitter via Neon"
```

---

### Task 4: Test and Iterate

**Files:**
- Possibly modify: `Sources/amux/Helpers/TreeSitterManager.swift`, `Sources/amux/Views/EditorSidebarView.swift`, `Package.swift`

**Step 1: Run the app**

Run: `bash run.sh`
Expected: App launches without crashes.

**Step 2: Open files and verify highlighting**

Test these scenarios:
1. Open a `.swift` file -- keywords, strings, comments, types should be colored
2. Open a `.py` file -- Python keywords and comments highlighted
3. Open a `.json` file -- keys and values colored
4. Open a `.txt` file -- plain text, no highlighting (no crash)
5. Open a large file (>120k chars) -- should highlight without the old ceiling
6. Type in the editor -- highlighting updates live as you type
7. Toggle theme -- colors update to match new theme
8. Toggle glassmorphism -- no visual conflict

**Step 3: Fix any issues found**

Common issues to watch for:
- Grammar that didn't bundle `highlights.scm` -- no colors for that language (add manual query or skip)
- Token names different than expected -- add `print(token.name)` in the attribute provider to discover actual names, then update the mapping
- Cursor position reset after highlighting -- Neon should handle this, but verify
- NSTextStorage delegate conflict -- if Neon and the existing delegate clash

**Step 4: Commit fixes**

```bash
git add -A
git commit -m "fix: resolve tree-sitter highlighting issues"
```

---

### Task 5: Final Cleanup

**Files:**
- Verify deleted: `Sources/amux/Helpers/SyntaxHighlighter.swift`
- Verify no remaining references to `SyntaxHighlighter` anywhere

**Step 1: Search for stale references**

Run: `grep -r "SyntaxHighlighter" Sources/`
Expected: No matches.

**Step 2: Full build**

Run: `bash run.sh`
Expected: Clean build, app launches, highlighting works.

**Step 3: Commit**

```bash
git add -A
git commit -m "chore: clean up stale syntax highlighter references"
```
