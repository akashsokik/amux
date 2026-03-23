# Editor Sidebar Design

**Date:** 2026-03-23
**Status:** Approved

## Overview

Add a right-side editor sidebar to amux that allows users to open and edit files from the FileTree tab. The sidebar supports tabs for multiple open files, syntax highlighting via TreeSitter, and a pill button to open files in the system's GUI editor.

## Layout & Structure

The MainWindowController layout changes from:

```
[ SidebarView | SplitContainerView ]
```

To:

```
[ SidebarView | SplitContainerView | EditorSidebarView ]
```

- **EditorSidebarView** sits to the right of `SplitContainerView`, separated by a `SidebarResizeHandle` (reusing the existing resize handle pattern).
- Width: resizable, 250-500pt range, default 350pt.
- Hidden by default. A toggle button in the main window header (right corner) shows/hides it.
- When visible but no file opened: shows a centered placeholder (e.g. "Click a file in the tree to open it").
- When hidden, `SplitContainerView` takes the full remaining width.

## Tab Bar & File Management

The EditorSidebarView has its own tab bar at the top:

- **Tab bar** (28pt height, matching PaneTabBar style):
  - Each tab shows the filename (not full path), with tooltip showing full path.
  - Active tab highlighted with the app's theme accent color.
  - Click to switch between open files.
  - Close button (x) on each tab, or middle-click to close.
  - Tabs scroll horizontally if they overflow.
  - Unsaved changes indicated by a dot on the tab.

- **Header area** (above or integrated with tab bar):
  - "Open in Editor" pill button -- detects best available GUI editor on system (VS Code > Sublime > TextEdit, or default app for file type via NSWorkspace).
  - Full file path shown as breadcrumb or subtitle text.

- **File opening flow**:
  - Click file in FileTree -> if EditorSidebar hidden, show it -> open file in new tab (or focus existing tab if already open).
  - Re-clicking an already-open file focuses its tab rather than opening a duplicate.

## Editor View & Syntax Highlighting

The main content area of each tab is a text editor:

- **NSTextView-based editor** with:
  - Read-write capability, standard text editing (undo/redo, cut/copy/paste).
  - Line numbers gutter on the left.
  - Monospace font (matching terminal font or system monospace).
  - Theme-aware colors (respects the app's existing Theme system).

- **TreeSitter for syntax highlighting**:
  - Use SwiftTreeSitter package (Swift bindings for tree-sitter).
  - Bundle common language grammars: Swift, Python, JavaScript/TypeScript, Rust, Go, C/C++, JSON, YAML, Markdown, HTML/CSS, Shell/Bash.
  - Falls back to plain text for unrecognized file types.
  - Re-highlights incrementally on edits.

- **File operations**:
  - Auto-detect encoding on open (UTF-8 default).
  - Save with Cmd+S (writes back to disk).
  - Dirty state tracked per tab (dot indicator on tab).
  - Prompt to save unsaved changes when closing a tab.

## Communication Between Views

- **Delegation pattern** (matching the existing codebase style):
  - FileTreeView gets a new delegate method: `fileTreeView(_:didSelectFile:atPath:)`.
  - MainWindowController acts as the delegate.
  - On file selection, MainWindowController calls `editorSidebarView.openFile(at:)` which either creates a new tab or focuses an existing one.
  - If the editor sidebar is hidden, MainWindowController shows it first.

- **Toggle button**:
  - Added to the window's title bar area (right side).
  - Keyboard shortcut (Cmd+Shift+E) to toggle.
  - Button icon changes state to reflect open/closed.

- **"Open in Editor" pill**:
  - Uses `NSWorkspace.shared.open(_:)` for default app, or detects known editors via `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` checking for VS Code, Sublime, etc. in priority order.
  - Opens the currently active tab's file.

## Approach

Standalone right sidebar view (Approach A) -- a new `EditorSidebarView` as a peer to `SplitContainerView` in `MainWindowController`, mirroring how the left `SidebarView` works. Clean separation from terminal logic, no impact on split tree.

## New Files

- `Sources/amux/Views/EditorSidebarView.swift` -- main sidebar container with tab bar, placeholder, resize handle
- `Sources/amux/Views/EditorTabView.swift` -- individual editor tab content (NSTextView + TreeSitter highlighting + line numbers)
- `Sources/amux/Models/EditorTab.swift` -- data model for an open file tab (path, dirty state, content)
- `Sources/amux/Helpers/SyntaxHighlighter.swift` -- TreeSitter wrapper for syntax highlighting
- `Sources/amux/Helpers/ExternalEditorHelper.swift` -- detect and launch GUI editors

## Modified Files

- `Sources/amux/Views/MainWindowController.swift` -- add EditorSidebarView to layout, toggle button, coordinate FileTree -> Editor
- `Sources/amux/Views/FileTreeView.swift` -- add delegate method for file selection
- `Package.swift` -- add SwiftTreeSitter dependency
