# Tree-Sitter Syntax Highlighting for Editor

**Date:** 2026-03-24
**Status:** Approved

## Summary

Replace the regex-based `SyntaxHighlighter` with tree-sitter AST-based highlighting using SwiftTreeSitter + Neon's `TextViewHighlighter`. This provides accurate, multi-language syntax highlighting with incremental parsing, visible-range optimization, and proper handling of nested constructs (string interpolation, multiline comments, etc.).

## Approach

Use ChimeHQ's **Neon** library which wraps SwiftTreeSitter and provides a turnkey `TextViewHighlighter` integration for NSTextView. Neon handles:
- NSTextStorage delegate hookup
- Scroll-aware visible-range-only highlighting
- Incremental re-parsing on edits
- Flicker prevention via buffered invalidations
- Style application via `NSLayoutManager.setTemporaryAttributes` (ephemeral)

## Language Support

### Tier 1 (initial)
Swift, Python, JavaScript, TypeScript, Rust, Go, C, C++, JSON, HTML, CSS, Bash, Ruby, Java, Markdown

### Detection
File extension mapped to `LanguageConfiguration` via `TreeSitterManager`. Unrecognized extensions get plain text (no highlighting).

## Architecture

### New Files
- **`TreeSitterManager.swift`** -- singleton that lazily creates/caches `LanguageConfiguration` per language. Maps file extensions to language names.

### Modified Files
- **`EditorTextContentView`** (in `EditorSidebarView.swift`) -- replace `SyntaxHighlighter` with Neon `TextViewHighlighter?`. On `setText()`, look up language config and create/reconfigure the highlighter.
- **`Package.swift`** -- add SPM dependencies for swift-tree-sitter, Neon, and all grammar packages.

### Deleted Files
- **`SyntaxHighlighter.swift`** -- fully replaced by tree-sitter.

### Unchanged
- `EditorSidebarView`, `EditorTab`, tab management, file loading, save/dirty state
- NSTextView setup (scroll view, find bar, undo, font)
- `Theme` color system

## Data Flow

### File Open
1. `EditorSidebarView.openFile()` loads content into `EditorTab`
2. `renderState()` calls `editorContentView.setText(content, fileExtension: ext)`
3. `setText` asks `TreeSitterManager` for the `LanguageConfiguration` matching the extension
4. Creates/reconfigures `TextViewHighlighter` with that config + theme attribute provider
5. Neon handles all subsequent highlighting automatically

### Theme Change
1. `Theme.didChangeNotification` fires
2. `EditorTextContentView.refreshTheme()` invalidates the highlighter to re-apply with new colors

## Token Color Mapping

| Token | Color |
|---|---|
| `keyword` | `Theme.primary` blended 25% with `primaryText` |
| `string`, `string.special` | `Theme.secondary` blended 20% with `primaryText` |
| `comment` | `Theme.tertiaryText` |
| `number`, `float` | `Theme.primaryContainer` blended 35% with `primaryText` |
| `type`, `type.builtin` | `Theme.onSurfaceVariant` |
| `function`, `function.method` | `Theme.primary` |
| `variable`, `variable.builtin` | `Theme.primaryText` |
| `operator` | `Theme.secondaryText` |
| `constant`, `constant.builtin` | `Theme.secondary` |
| `property` | `Theme.primaryText` |
| `punctuation` | `Theme.secondaryText` |
| fallback | `Theme.primaryText` |

Font: `NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)` for all tokens.

## SPM Dependencies

```swift
// Core
.package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.9.0"),
.package(url: "https://github.com/ChimeHQ/Neon", branch: "main"), // pin to commit hash

// Grammars
.package(url: "https://github.com/alex-pinkus/tree-sitter-swift", branch: "with-generated-files"),
.package(url: "https://github.com/tree-sitter/tree-sitter-python", from: "0.23.6"),
.package(url: "https://github.com/tree-sitter/tree-sitter-javascript", from: "0.23.1"),
.package(url: "https://github.com/tree-sitter/tree-sitter-typescript", from: "0.23.2"),
.package(url: "https://github.com/tree-sitter/tree-sitter-rust", from: "0.23.2"),
.package(url: "https://github.com/tree-sitter/tree-sitter-go", from: "0.23.4"),
.package(url: "https://github.com/tree-sitter/tree-sitter-c", from: "0.23.4"),
.package(url: "https://github.com/tree-sitter/tree-sitter-cpp", from: "0.23.4"),
.package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.8"),
.package(url: "https://github.com/tree-sitter/tree-sitter-html", from: "0.23.2"),
.package(url: "https://github.com/tree-sitter/tree-sitter-css", from: "0.23.1"),
.package(url: "https://github.com/tree-sitter/tree-sitter-bash", from: "0.23.3"),
.package(url: "https://github.com/tree-sitter/tree-sitter-ruby", from: "0.23.1"),
.package(url: "https://github.com/tree-sitter/tree-sitter-java", from: "0.23.4"),
.package(url: "https://github.com/MDeiml/tree-sitter-markdown", from: "0.4.1"),
```

## Edge Cases

- **Large files:** Neon's visible-range optimization handles this. The 120k char ceiling goes away.
- **Unknown languages:** No highlighter created; plain text display.
- **Neon stability:** Pin to specific commit hash rather than tracking `main`.
- **Build time:** First compile slower with 15+ C grammar libs; incremental builds unaffected.
- **TextStorage delegate:** Neon uses it; no conflict with current code (NSTextView delegate stays separate for `textDidChange`/dirty tracking).
- **Glassmorphism:** Neon only touches foreground text attributes; background unaffected.
