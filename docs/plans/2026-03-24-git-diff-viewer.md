# Git Diff Viewer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a git diff viewer to the editor sidebar, triggered by clicking modified files in the git status panel, with side-by-side and unified views plus enhanced syntax highlighting.

**Architecture:** Extend EditorTab with a DiffTab subclass that holds old/new content and parsed hunks. EditorSidebarView swaps between editor content views and diff content views based on the active tab type. GitStatusView gets a delegate to notify MainWindowController when a file is clicked, which creates a DiffTab and opens it.

**Tech Stack:** Swift, AppKit, NSTextView (read-only for diffs), unified diff parsing, regex-based syntax highlighting

---

### Task 1: Enhance SyntaxHighlighter with Per-Language Keywords and Priority Ordering

**Files:**
- Modify: `Sources/amux/Helpers/SyntaxHighlighter.swift`

**Step 1: Add painted-ranges tracking to prevent overwriting**

Add an `IndexSet` that tracks already-highlighted ranges. Comments and strings get painted first and are never overwritten by later passes (keywords, types, numbers).

```swift
// In the highlight() method, after setting base attributes:
var paintedRanges = IndexSet()

// Modify apply() to accept and update paintedRanges:
private func apply(
    pattern: String,
    to textStorage: NSTextStorage,
    in text: String,
    color: NSColor,
    paintedRanges: inout IndexSet,
    isPrimary: Bool = false  // true for comments/strings -- locks ranges
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
        let range = match.range
        // Skip if any part overlaps already-painted range
        let matchIndexSet = IndexSet(integersIn: range.location..<(range.location + range.length))
        if !isPrimary && !paintedRanges.intersection(matchIndexSet).isEmpty {
            continue
        }
        textStorage.addAttribute(.foregroundColor, value: color, range: range)
        if isPrimary {
            paintedRanges.formUnion(matchIndexSet)
        }
    }
}
```

**Step 2: Add per-language keyword sets**

```swift
private static let swiftKeywords: Set<String> = [
    "func", "class", "struct", "enum", "protocol", "extension", "import",
    "return", "if", "else", "for", "while", "do", "switch", "case",
    "break", "continue", "var", "let", "private", "public", "internal",
    "fileprivate", "open", "static", "override", "guard", "throw",
    "throws", "try", "catch", "defer", "where", "in", "is", "as",
    "self", "super", "nil", "true", "false", "init", "deinit",
    "typealias", "associatedtype", "weak", "unowned", "lazy",
    "mutating", "nonmutating", "convenience", "required", "final",
    "inout", "some", "any", "async", "await", "actor", "nonisolated",
    "sending", "consume", "borrowing", "consuming",
]

private static let pythonKeywords: Set<String> = [
    "def", "class", "import", "from", "return", "if", "elif", "else",
    "for", "while", "break", "continue", "pass", "raise", "try",
    "except", "finally", "with", "as", "yield", "lambda", "global",
    "nonlocal", "assert", "del", "in", "is", "not", "and", "or",
    "True", "False", "None", "async", "await", "match", "case",
]

private static let jstsKeywords: Set<String> = [
    "function", "class", "const", "let", "var", "return", "if", "else",
    "for", "while", "do", "switch", "case", "break", "continue",
    "throw", "try", "catch", "finally", "new", "delete", "typeof",
    "instanceof", "in", "of", "import", "export", "default", "from",
    "async", "await", "yield", "this", "super", "null", "undefined",
    "true", "false", "void", "static", "extends", "implements",
    "interface", "type", "enum", "namespace", "abstract", "readonly",
    "private", "public", "protected", "override", "as", "satisfies",
]

private static let rustKeywords: Set<String> = [
    "fn", "struct", "enum", "impl", "trait", "type", "use", "mod",
    "pub", "crate", "self", "super", "let", "mut", "const", "static",
    "if", "else", "match", "for", "while", "loop", "break", "continue",
    "return", "where", "as", "in", "ref", "move", "async", "await",
    "dyn", "unsafe", "extern", "true", "false",
]

private static let goKeywords: Set<String> = [
    "func", "struct", "interface", "type", "package", "import",
    "return", "if", "else", "for", "switch", "case", "break",
    "continue", "var", "const", "range", "map", "chan", "go",
    "defer", "select", "default", "fallthrough", "goto", "nil",
    "true", "false", "make", "new", "append", "len", "cap",
]

private static let cKeywords: Set<String> = [
    "auto", "break", "case", "char", "const", "continue", "default",
    "do", "double", "else", "enum", "extern", "float", "for", "goto",
    "if", "int", "long", "register", "return", "short", "signed",
    "sizeof", "static", "struct", "switch", "typedef", "union",
    "unsigned", "void", "volatile", "while", "inline", "restrict",
    "class", "namespace", "template", "typename", "virtual", "override",
    "public", "private", "protected", "new", "delete", "throw",
    "try", "catch", "nullptr", "true", "false", "using", "include",
    "define", "ifdef", "ifndef", "endif", "pragma",
]

private static func keywords(for ext: String) -> Set<String> {
    switch ext {
    case "swift": return swiftKeywords
    case "py": return pythonKeywords
    case "js", "ts", "tsx", "jsx": return jstsKeywords
    case "rs": return rustKeywords
    case "go": return goKeywords
    case "c", "h", "cpp", "hpp", "m", "mm": return cKeywords
    default: return keywords  // fallback to shared set
    }
}
```

**Step 3: Add function name, decorator, preprocessor, and operator patterns**

```swift
// Function names: identifier followed by (
private static let functionPattern = #"\b[a-zA-Z_]\w*(?=\s*\()"#

// Decorators/attributes: @Something
private static let decoratorPattern = #"@[A-Za-z_]\w*"#

// Preprocessor: #include, #import, #if, etc.
private static let preprocessorPattern = #"^\s*#\w+"#

// Operators
private static let operatorPattern = #"(?<!=)=>|->|!=|==|<=|>=|&&|\|\||[+\-*/%&|^~<>]=?"#

private func functionColor() -> NSColor {
    Theme.primary.blended(withFraction: 0.4, of: Theme.primaryText) ?? Theme.primary
}

private func decoratorColor() -> NSColor {
    Theme.secondary
}

private func preprocessorColor() -> NSColor {
    Theme.secondary.blended(withFraction: 0.3, of: Theme.primaryText) ?? Theme.secondary
}

private func operatorColor() -> NSColor {
    Theme.onSurfaceVariant
}
```

**Step 4: Update highlight() to use new patterns in correct order**

Apply in this order with painted ranges:
1. Comments (isPrimary: true) -- locks ranges
2. Strings (isPrimary: true) -- locks ranges
3. Preprocessor directives
4. Decorators/attributes (only for swift, py, java, kt, ts, tsx)
5. Numbers
6. Keywords (per-language)
7. Function names
8. Types (PascalCase)
9. Operators

**Step 5: Build and verify**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds with no errors

**Step 6: Commit**

```bash
git add Sources/amux/Helpers/SyntaxHighlighter.swift
git commit -m "feat: enhance syntax highlighter with per-language keywords and priority ordering"
```

---

### Task 2: Add Diff Data Models and GitHelper Diff Methods

**Files:**
- Create: `Sources/amux/Models/DiffModels.swift`
- Modify: `Sources/amux/Helpers/GitHelper.swift`
- Modify: `Sources/amux/Models/EditorTab.swift`

**Step 1: Create DiffModels.swift with DiffLine, DiffHunk, DiffViewMode, and parser**

```swift
import Foundation

enum DiffLineType {
    case context
    case added
    case removed
}

struct DiffLine {
    let type: DiffLineType
    let content: String
    let oldLineNumber: Int?  // nil for added lines
    let newLineNumber: Int?  // nil for removed lines
}

struct DiffHunk {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [DiffLine]
}

enum DiffViewMode {
    case sideBySide
    case unified
}

enum DiffParser {
    /// Parse unified diff output into hunks.
    static func parse(_ diffOutput: String) -> [DiffHunk] {
        let lines = diffOutput.components(separatedBy: "\n")
        var hunks: [DiffHunk] = []
        var currentLines: [DiffLine] = []
        var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
        var oldLine = 0, newLine = 0
        var inHunk = false

        for line in lines {
            if line.hasPrefix("@@") {
                // Save previous hunk
                if inHunk && !currentLines.isEmpty {
                    hunks.append(DiffHunk(
                        oldStart: oldStart, oldCount: oldCount,
                        newStart: newStart, newCount: newCount,
                        lines: currentLines
                    ))
                }

                // Parse @@ -oldStart,oldCount +newStart,newCount @@
                let parts = line.components(separatedBy: " ")
                if parts.count >= 3 {
                    let oldPart = parts[1].dropFirst() // remove -
                    let newPart = parts[2].dropFirst() // remove +
                    let oldNums = oldPart.components(separatedBy: ",")
                    let newNums = newPart.components(separatedBy: ",")
                    oldStart = Int(oldNums[0]) ?? 0
                    oldCount = oldNums.count > 1 ? (Int(oldNums[1]) ?? 0) : 1
                    newStart = Int(newNums[0]) ?? 0
                    newCount = newNums.count > 1 ? (Int(newNums[1]) ?? 0) : 1
                }

                oldLine = oldStart
                newLine = newStart
                currentLines = []
                inHunk = true
            } else if inHunk {
                if line.hasPrefix("+") {
                    currentLines.append(DiffLine(
                        type: .added,
                        content: String(line.dropFirst()),
                        oldLineNumber: nil,
                        newLineNumber: newLine
                    ))
                    newLine += 1
                } else if line.hasPrefix("-") {
                    currentLines.append(DiffLine(
                        type: .removed,
                        content: String(line.dropFirst()),
                        oldLineNumber: oldLine,
                        newLineNumber: nil
                    ))
                    oldLine += 1
                } else if line.hasPrefix(" ") || line.isEmpty {
                    let content = line.isEmpty ? "" : String(line.dropFirst())
                    currentLines.append(DiffLine(
                        type: .context,
                        content: content,
                        oldLineNumber: oldLine,
                        newLineNumber: newLine
                    ))
                    oldLine += 1
                    newLine += 1
                }
            }
        }

        // Save last hunk
        if inHunk && !currentLines.isEmpty {
            hunks.append(DiffHunk(
                oldStart: oldStart, oldCount: oldCount,
                newStart: newStart, newCount: newCount,
                lines: currentLines
            ))
        }

        return hunks
    }
}
```

**Step 2: Add diff methods to GitHelper**

Add to `Sources/amux/Helpers/GitHelper.swift`:

```swift
// MARK: - Diff Content

/// Get the unified diff for a specific file (unstaged changes).
static func diff(for filePath: String, in cwd: String) -> String? {
    return run(["diff", "--", filePath], in: cwd)
}

/// Get the unified diff for a specific file (staged changes).
static func diffCached(for filePath: String, in cwd: String) -> String? {
    return run(["diff", "--cached", "--", filePath], in: cwd)
}

/// Get file content at HEAD.
static func showHead(for filePath: String, in cwd: String) -> String? {
    return run(["show", "HEAD:\(filePath)"], in: cwd)
}
```

**Step 3: Create DiffTab subclass of EditorTab**

Add to `Sources/amux/Models/EditorTab.swift`:

```swift
class DiffTab: EditorTab {
    let oldContent: String
    let newContent: String
    let hunks: [DiffHunk]
    let fileStatus: GitHelper.FileStatus
    var viewMode: DiffViewMode = .sideBySide

    init(
        filePath: String,
        oldContent: String,
        newContent: String,
        hunks: [DiffHunk],
        fileStatus: GitHelper.FileStatus
    ) {
        self.oldContent = oldContent
        self.newContent = newContent
        self.hunks = hunks
        self.fileStatus = fileStatus
        super.init(
            filePath: filePath,
            content: newContent,
            encoding: .utf8,
            isEditable: false
        )
    }
}
```

**Step 4: Build and verify**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/amux/Models/DiffModels.swift Sources/amux/Helpers/GitHelper.swift Sources/amux/Models/EditorTab.swift
git commit -m "feat: add diff data models, parser, and GitHelper diff methods"
```

---

### Task 3: Build the Unified Diff View

**Files:**
- Create: `Sources/amux/Views/DiffContentView.swift`

This task creates the UnifiedDiffView first since it's simpler -- single scroll view with line-by-line rendering.

**Step 1: Create DiffContentView.swift with the UnifiedDiffView**

The UnifiedDiffView is a read-only NSTextView inside an NSScrollView with:
- A line-number gutter showing old/new line numbers (two columns)
- Per-line background tinting (red for removed, green for added)
- Syntax highlighting via SyntaxHighlighter on the content
- ThinScroller for consistency

Key implementation details:
- Build an NSAttributedString from all hunk lines
- Use NSTextView's `layoutManager` to get line rects for background drawing
- Custom `NSView` overlay or `drawBackground` to paint line backgrounds
- Line gutter as a separate NSRulerView or custom NSView pinned to the left

The gutter should show two columns:
- Left column: old line number (blank for added lines)
- Right column: new line number (blank for removed lines)

Colors (theme-aware):
- Added bg: `NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 0.10)` over surface
- Removed bg: `NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 0.10)` over surface
- Gutter added: same green at 0.15 alpha
- Gutter removed: same red at 0.15 alpha
- Gutter text: `Theme.quaternaryText`

**Step 2: Build and verify**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/amux/Views/DiffContentView.swift
git commit -m "feat: add unified diff view with line gutters and background tinting"
```

---

### Task 4: Build the Side-by-Side Diff View

**Files:**
- Modify: `Sources/amux/Views/DiffContentView.swift`

**Step 1: Add SideBySideDiffView to DiffContentView.swift**

Two NSScrollViews side by side, each with a read-only NSTextView:
- Left pane: old content with line numbers gutter
- Right pane: new content with line numbers gutter
- Draggable divider between them (NSView with drag gesture, min 100px each side)
- Defaults to 50/50 split

Content alignment:
- Process hunks to create paired line arrays
- For added lines (right only): insert blank placeholder on left
- For removed lines (left only): insert blank placeholder on right
- Context lines appear on both sides at matching positions

Synchronized scrolling:
- Listen to `NSScrollView.boundsDidChangeNotification` on both clip views
- When one scrolls, update the other's contentView.bounds.origin to match
- Use a `isSyncingScroll` flag to prevent infinite recursion

Each side gets:
- Line number gutter (single column per side)
- Per-line background tinting (removed=red on left, added=green on right)
- Syntax highlighting applied independently to each side's full text

**Step 2: Add DiffContentView container**

DiffContentView is the parent that holds both views and swaps between them:

```swift
class DiffContentView: NSView {
    private var unifiedView: UnifiedDiffView?
    private var sideBySideView: SideBySideDiffView?
    private var currentMode: DiffViewMode = .sideBySide

    func configure(tab: DiffTab) {
        currentMode = tab.viewMode
        // Build/show the appropriate view
        showView(for: currentMode, tab: tab)
    }

    func switchMode(_ mode: DiffViewMode, tab: DiffTab) {
        currentMode = mode
        tab.viewMode = mode
        showView(for: mode, tab: tab)
    }

    private func showView(for mode: DiffViewMode, tab: DiffTab) {
        // Remove current subviews, create and add the appropriate view
        // Pin to all edges of self
    }

    func scrollToHunk(at index: Int) {
        // Scroll the active view to center the given hunk
    }

    func refreshTheme() {
        unifiedView?.refreshTheme()
        sideBySideView?.refreshTheme()
    }
}
```

**Step 3: Build and verify**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/amux/Views/DiffContentView.swift
git commit -m "feat: add side-by-side diff view with synchronized scrolling and resizable divider"
```

---

### Task 5: Build the DiffHeaderView

**Files:**
- Modify: `Sources/amux/Views/EditorSidebarView.swift`

**Step 1: Add DiffHeaderView class**

Add a new class in EditorSidebarView.swift (following the pattern of EditorHeaderView) with:

- **pathLabel**: NSTextField showing relative file path (same style as EditorHeaderView)
- **viewModeToggle**: NSSegmentedControl with 2 segments: "Side by Side" | "Unified"
  - Segment 0 selected by default
  - On change, calls `onViewModeChange?(mode)`
- **prevHunkButton**: DimIconButton with SF Symbol "chevron.up"
- **nextHunkButton**: DimIconButton with SF Symbol "chevron.down"
- **expandButton**: DimIconButton (same as EditorHeaderView) for expand/collapse
- **closeButton**: DimIconButton with "xmark" (same as EditorHeaderView)

Layout: pathLabel on left, then icon cluster on right: [viewModeToggle, prevHunk, nextHunk, expandButton, closeButton]

Callbacks:
```swift
var onViewModeChange: ((DiffViewMode) -> Void)?
var onPrevHunk: (() -> Void)?
var onNextHunk: (() -> Void)?
var onToggleExpand: (() -> Void)?
var onClose: (() -> Void)?
```

Height: 36pt (same as EditorHeaderView)

**Step 2: Build and verify**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/amux/Views/EditorSidebarView.swift
git commit -m "feat: add DiffHeaderView with view mode toggle and hunk navigation"
```

---

### Task 6: Integrate DiffTab into EditorSidebarView

**Files:**
- Modify: `Sources/amux/Views/EditorSidebarView.swift`

**Step 1: Add diff view properties to EditorSidebarView**

```swift
// Add alongside existing properties:
private var diffHeaderView: DiffHeaderView!
private var diffContentView: DiffContentView!
private var currentHunkIndex: Int = 0
```

**Step 2: Create and add diff views in setupUI()**

Create `diffHeaderView` and `diffContentView` in setupUI(), hidden by default. Pin them to the same anchors as `headerView` and `editorContentView` respectively. The diff header replaces the normal header, and diffContentView replaces editorContentView, both hidden by default.

```swift
diffHeaderView = DiffHeaderView()
diffHeaderView.translatesAutoresizingMaskIntoConstraints = false
diffHeaderView.isHidden = true
diffHeaderView.onViewModeChange = { [weak self] mode in
    guard let self, let tab = self.activeTab as? DiffTab else { return }
    self.diffContentView.switchMode(mode, tab: tab)
}
diffHeaderView.onPrevHunk = { [weak self] in self?.navigateHunk(direction: -1) }
diffHeaderView.onNextHunk = { [weak self] in self?.navigateHunk(direction: 1) }
diffHeaderView.onToggleExpand = { [weak self] in
    self?.delegate?.editorSidebarDidRequestToggleExpand()
}
diffHeaderView.onClose = { [weak self] in self?.closeActiveTab() }
addSubview(diffHeaderView)

diffContentView = DiffContentView()
diffContentView.translatesAutoresizingMaskIntoConstraints = false
diffContentView.isHidden = true
contentContainer.addSubview(diffContentView)
```

Add constraints matching headerView and editorContentView positions.

**Step 3: Modify renderState() to handle DiffTab**

```swift
private func renderState() {
    refreshChrome()

    guard let tab = activeTab else {
        placeholderLabel.isHidden = false
        unsupportedLabel.isHidden = true
        editorContentView.isHidden = true
        diffHeaderView.isHidden = true
        diffContentView.isHidden = true
        headerView.isHidden = false
        return
    }

    placeholderLabel.isHidden = true

    if let diffTab = tab as? DiffTab {
        // Show diff views, hide editor views
        editorContentView.isHidden = true
        unsupportedLabel.isHidden = true
        headerView.isHidden = true
        diffHeaderView.isHidden = false
        diffContentView.isHidden = false
        diffHeaderView.configure(filePath: diffTab.filePath, mode: diffTab.viewMode)
        diffContentView.configure(tab: diffTab)
        currentHunkIndex = 0
    } else if tab.isEditable {
        // Normal editor
        headerView.isHidden = false
        diffHeaderView.isHidden = true
        diffContentView.isHidden = true
        unsupportedLabel.isHidden = true
        editorContentView.isHidden = false
        editorContentView.setText(
            tab.content,
            fileExtension: tab.fileExtension,
            isEditable: true
        )
    } else {
        headerView.isHidden = false
        diffHeaderView.isHidden = true
        diffContentView.isHidden = true
        editorContentView.isHidden = true
        unsupportedLabel.isHidden = false
    }
}
```

**Step 4: Add openDiff() method and hunk navigation**

```swift
func openDiff(tab: DiffTab) {
    // Reuse existing diff tab for same path
    if let existing = tabs.first(where: { $0.filePath == tab.filePath && $0 is DiffTab }) {
        activateTab(existing.id)
        return
    }
    tabs.append(tab)
    activateTab(tab.id)
}

private func navigateHunk(direction: Int) {
    guard let diffTab = activeTab as? DiffTab else { return }
    let count = diffTab.hunks.count
    guard count > 0 else { return }
    currentHunkIndex = (currentHunkIndex + direction + count) % count
    diffContentView.scrollToHunk(at: currentHunkIndex)
}
```

**Step 5: Update themeDidChange() to refresh diff views**

```swift
diffHeaderView.refreshTheme()
diffContentView.refreshTheme()
```

**Step 6: Update EditorTabStripView.updateTabs() to show diff icon**

In the `updateTabs` method, detect if a tab is a DiffTab and pass that info to `EditorTabItemView` so it shows the `arrow.left.arrow.right` SF Symbol instead of the file-type icon.

**Step 7: Build and verify**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 8: Commit**

```bash
git add Sources/amux/Views/EditorSidebarView.swift
git commit -m "feat: integrate DiffTab into editor sidebar with view swapping"
```

---

### Task 7: Wire GitStatusView Click to Open DiffTab

**Files:**
- Modify: `Sources/amux/Views/GitStatusView.swift`
- Modify: `Sources/amux/Views/SidebarView.swift`
- Modify: `Sources/amux/Views/MainWindowController.swift`

**Step 1: Add delegate protocol to GitStatusView**

```swift
protocol GitStatusViewDelegate: AnyObject {
    func gitStatusDidSelectFile(_ file: GitHelper.FileStatus, cwd: String)
}
```

Add `weak var delegate: GitStatusViewDelegate?` property.

**Step 2: Implement click handling in GitStatusView**

Add `outlineViewSelectionDidChange` delegate method (NSOutlineViewDelegate):

```swift
func outlineViewSelectionDidChange(_ notification: Notification) {
    let row = outlineView.selectedRow
    guard row >= 0,
          let item = outlineView.item(atRow: row) as? GitHelper.FileStatus,
          let cwd = currentCwd else { return }
    delegate?.gitStatusDidSelectFile(item, cwd: cwd)
    // Deselect to allow re-clicking
    outlineView.deselectRow(row)
}
```

**Step 3: Wire through SidebarView to MainWindowController**

SidebarView already has a delegate pattern (`SidebarViewDelegate`). Add a new method to SidebarView's delegate:

```swift
func sidebarDidSelectGitFile(_ file: GitHelper.FileStatus, cwd: String)
```

SidebarView becomes GitStatusViewDelegate, forwards to its own delegate.

**Step 4: Handle in MainWindowController**

```swift
func sidebarDidSelectGitFile(_ file: GitHelper.FileStatus, cwd: String) {
    if !isEditorSidebarVisible {
        toggleEditorSidebar()
    }

    // Load diff on background queue
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let isStaged = (file.kind == .staged || file.kind == .renamed)
        let diffOutput: String?
        if isStaged {
            diffOutput = GitHelper.diffCached(for: file.path, in: cwd)
        } else {
            diffOutput = GitHelper.diff(for: file.path, in: cwd)
        }

        let oldContent = GitHelper.showHead(for: file.path, in: cwd) ?? ""
        let fullPath = (cwd as NSString).appendingPathComponent(file.path)
        let newContent = (try? String(contentsOfFile: fullPath, encoding: .utf8)) ?? ""
        let hunks = DiffParser.parse(diffOutput ?? "")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let diffTab = DiffTab(
                filePath: file.path,
                oldContent: oldContent,
                newContent: newContent,
                hunks: hunks,
                fileStatus: file
            )
            self.editorSidebarView.openDiff(tab: diffTab)
        }
    }
}
```

**Step 5: Build and verify**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 6: Commit**

```bash
git add Sources/amux/Views/GitStatusView.swift Sources/amux/Views/SidebarView.swift Sources/amux/Views/MainWindowController.swift
git commit -m "feat: wire git status file click to open diff tab in editor sidebar"
```

---

### Task 8: Build and Smoke Test End-to-End

**Files:**
- No new files -- integration verification

**Step 1: Full build**

Run: `swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 2: Fix any compilation errors**

Address any type mismatches, missing protocol conformances, or constraint conflicts. This is expected since the plan involves cross-file wiring.

**Step 3: Manual smoke test checklist**

Run the app and verify:
1. Click a modified file in git status panel -- diff tab opens in editor sidebar
2. Side-by-side view shows old (left) and new (right) with proper alignment
3. Toggle to unified view -- shows interleaved diff with line backgrounds
4. Hunk navigation arrows scroll to prev/next change
5. Syntax highlighting works on diff content
6. Resizable divider in side-by-side view works
7. Scroll sync works -- scrolling one side scrolls the other
8. Tab strip shows diff icon for diff tabs
9. Closing diff tab works, switching between diff and regular tabs works
10. Theme changes propagate to diff views

**Step 4: Final commit**

```bash
git add -A
git commit -m "fix: resolve integration issues in git diff viewer"
```
