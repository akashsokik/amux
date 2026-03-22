# amux Design

## Overview

Native macOS terminal app embedding libghostty with a toggleable sidebar of independent workspace sessions, each supporting fully flexible binary splits with drag-to-resize and drag-to-rearrange.

## Architecture

### Layers

1. **CGhostty** -- C module wrapping ghostty.h headers for Swift interop
2. **GhosttyApp** -- Swift wrapper around `ghostty_app_t`, implements runtime callbacks
3. **SessionManager** -- Owns ordered list of `Session` objects
4. **Session** -- Owns a `SplitTree<TerminalPane>`, represents an independent workspace
5. **SplitTree** -- Binary tree: nodes are `Leaf(TerminalPane)` or `Split(direction, ratio, left, right)`
6. **TerminalPane** -- `NSView` subclass with `CAMetalLayer`, owns one `ghostty_surface_t`
7. **Sidebar** -- Toggleable `NSView` listing sessions, starts hidden
8. **MainWindowController** -- `NSWindowController` composing sidebar + active session's split view

### Data Flow

```
User Input (keyboard/mouse)
  -> AppKit NSEvent
  -> TerminalPane.keyDown / mouseDown
  -> ghostty_surface_key() / ghostty_surface_mouse_*()
  -> libghostty processes internally
  -> action_cb fires for split/navigate/title changes
  -> GhosttyApp routes to SessionManager
  -> SessionManager updates SplitTree / UI
```

### Key Design Decisions

- **One ghostty_app_t per process** -- all surfaces share one app instance
- **Split tree managed in Swift** -- not delegated to libghostty's internal split handling
- **Inactive sessions keep surfaces alive** -- processes continue running in background
- **No SwiftUI** -- pure AppKit for maximum control and minimal overhead
- **Direct modifier shortcuts** -- no prefix key, Cmd-based like native macOS apps

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Cmd+D | Split vertical |
| Cmd+Shift+D | Split horizontal |
| Cmd+W | Close pane |
| Cmd+Shift+W | Close session |
| Cmd+T | New session |
| Cmd+\ | Toggle sidebar |
| Cmd+Option+Arrow | Navigate panes (directional) |
| Cmd+Shift+Arrow | Resize active pane |
| Cmd+1-9 | Switch to session N |
| Cmd+Shift+] | Next session |
| Cmd+Shift+[ | Previous session |
| Cmd+Shift+Enter | Zoom/unzoom pane |
| Cmd+Shift+N | Rename session |
| Cmd+Option+= | Equalize splits |
| Cmd+Plus | Increase font size |
| Cmd+Minus | Decrease font size |
| Cmd+0 | Reset font size |

## Visual Design

- No title bars on panes
- 1px dividers between splits (subtle color, draggable)
- Sidebar: dark background, session list with activity indicator
- Active pane indicated by subtle border highlight or divider color change
- Window: frameless title bar integrated with content
- Font: system monospace, configurable

## File Structure

```
Sources/
  CGhostty/
    include/ghostty.h        -- C header stubs matching libghostty API
    module.modulemap
  amux/
    App/
      main.swift              -- NSApplication bootstrap
      AppDelegate.swift       -- App lifecycle, menu bar, GhosttyApp owner
    Models/
      SplitTree.swift         -- Binary split tree
      Session.swift           -- Session model
      SessionManager.swift    -- Session CRUD
    Views/
      MainWindowController.swift
      SidebarView.swift
      SplitContainerView.swift
      TerminalPane.swift
      DividerView.swift
    Bridge/
      GhosttyApp.swift        -- ghostty_app_t wrapper + runtime callbacks
      GhosttyConfig.swift     -- ghostty_config_t wrapper
    Shortcuts/
      KeyboardShortcuts.swift -- Shortcut definitions + menu integration
Resources/
  Info.plist
  amux.entitlements
Package.swift
build-ghostty.sh
```
