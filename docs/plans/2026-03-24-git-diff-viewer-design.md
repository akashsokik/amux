# Git Diff Viewer in Editor Sidebar

## Summary

Add a git diff viewer to the editor sidebar, triggered by clicking modified files in the git status panel. Supports both side-by-side and unified diff views with full syntax highlighting. Read-only.

## Data Layer

### New GitHelper methods

- `git diff -- <file>` -- unstaged diff for a file
- `git diff --cached -- <file>` -- staged diff for a file
- `git show HEAD:<file>` -- file content at HEAD

### DiffTab model (subclass of EditorTab)

- `oldContent: String` -- file content at HEAD
- `newContent: String` -- current working tree content (read from disk)
- `hunks: [DiffHunk]` -- parsed diff hunks with line ranges and change types
- `fileStatus: GitHelper.FileStatus` -- staged/modified/etc.
- `isEditable` always `false`
- `viewMode: DiffViewMode` (.sideBySide | .unified) -- persisted per tab

### DiffHunk struct

- `oldStart: Int`, `oldCount: Int`
- `newStart: Int`, `newCount: Int`
- `lines: [DiffLine]` -- each with type (.context, .added, .removed) and content

### Diff parser

Parse unified diff output into `[DiffHunk]`. Line-by-line parser of `@@` headers and `+`/`-`/` ` prefixed lines.

## Diff Content Views

### DiffContentView

Container NSView that swaps between two sub-views based on `viewMode`.

### SideBySideDiffView

- Two `NSScrollView`s side by side, each containing a read-only `NSTextView`
- Left = old content, Right = new content
- Resizable divider (draggable, defaults to 50/50)
- Synchronized scrolling -- scroll one side, the other follows
- Line numbers in a gutter on each side
- Background colors per line: red tint for removed (left), green tint for added (right), no tint for context
- Empty placeholder lines inserted to keep hunks aligned
- Syntax highlighting applied independently to each side via SyntaxHighlighter

### UnifiedDiffView

- Single `NSScrollView` with read-only `NSTextView`
- Old line number + new line number in gutter (blank when line doesn't exist on that side)
- Removed lines: red-tinted background
- Added lines: green-tinted background
- Context lines: no tint
- Syntax highlighting applied to merged content

### Color scheme (theme-aware)

- Added line bg: green at ~10% opacity over surface
- Removed line bg: red at ~10% opacity over surface
- Added line gutter: slightly stronger green tint
- Removed line gutter: slightly stronger red tint

## Toolbar & Navigation

### DiffHeaderView

Replaces normal EditorHeaderView when a DiffTab is active:

- File path label -- relative path with truncation
- View mode toggle -- two-segment control: "Side by Side" | "Unified"
- Hunk navigation -- up/down arrow buttons for prev/next hunk, scrolls to center target
- Same height and styling as existing EditorHeaderView

### Tab strip integration

- DiffTab shows with a diff icon (SF Symbol `arrow.left.arrow.right`) instead of file-type icon
- Tab title: file name (same as regular tabs)

## Integration: GitStatusView to DiffTab

### Click handler

- Click on file row in git status panel opens a DiffTab in editor sidebar
- New delegate method: `gitStatusDidSelectFile(_ file: GitHelper.FileStatus, cwd: String)`
- MainWindowController receives this, creates DiffTab, passes to EditorSidebarView

### EditorSidebarView changes

- New method: `openDiff(tab: DiffTab)` -- adds to tab list, activates
- Prevents duplicate diff tabs for same file path
- When active tab is DiffTab: shows DiffHeaderView + DiffContentView
- When active tab is EditorTab: shows normal editor views
- Auto-shows sidebar if hidden

### Loading flow

1. User clicks modified file in git status panel
2. GitHelper fetches HEAD content + reads current file on background queue
3. Diff output parsed into hunks
4. DiffTab created with old content, new content, hunks
5. Tab opened in editor sidebar, diff view rendered

## Syntax Highlighter Enhancements

1. **Per-language keywords** -- language-specific keyword sets for Swift, Python, JS/TS, Rust, Go, C/C++. Shared set as fallback.
2. **Function/method names** -- `\b[a-zA-Z_]\w*(?=\s*\()`
3. **Decorators/attributes** -- `@[A-Za-z_]\w*` for Swift/Python/Java/Kotlin/TS
4. **Preprocessor directives** -- `^\s*#\w+` for C-family
5. **Operators** -- highlight =, ==, !=, ->, =>, etc.
6. **Property/dot access** -- highlight property name after `.` with variant color
7. **Priority ordering fix** -- "painted ranges" set so strings/comments are never overwritten by keyword/type passes
