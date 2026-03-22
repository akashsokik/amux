# amux

A native macOS terminal emulator built with Swift and powered by the Ghostty rendering engine. GPU-accelerated via Metal with session management, pane splitting, git integration, and a command palette.

**v0.1.0** | macOS 14+

## Features

### Terminal
- GPU-accelerated rendering via Metal (CAMetalLayer)
- Full keyboard and mouse input with modifier support
- Input method support (NSTextInputClient)
- Force Touch / pressure-sensitive trackpad support
- Font size adjustment (Cmd++/Cmd+-/Cmd+0)
- In-terminal search (Cmd+F)
- Shell integration via OSC 7 and OSC 133 sequences
- Background command completion notifications (for commands running >5s)
- Shell support: bash, zsh, fish, elvish, nushell

### Sessions
- Multiple named sessions, each with its own color from a 16-color palette
- Session persistence across launches (`~/.config/amux/sessions.json`)
- Quick switching via Cmd+1 through Cmd+9 or the sidebar

### Panes and Tabs
- Vertical splits (Cmd+D) and horizontal splits (Cmd+Shift+D)
- Multiple tabs per pane with drag-and-drop reordering between panes
- Directional focus navigation (Cmd+Shift+Arrow)
- Pane resizing (Ctrl+Opt+Arrow)
- Zoom/fullscreen a single pane (Cmd+Shift+Enter)
- Equalize all pane sizes (Cmd+Opt+=)
- Auto-close when shell exits

### Sidebar (Cmd+\)
- **Sessions** -- list, create, rename, delete sessions
- **File Tree** -- browse files from the current working directory
- **Git Status** -- branch name, dirty indicator, changed files grouped by section
- **Worktrees** -- list, add, and open git worktrees

### Git Integration
- Branch detection via direct `.git/HEAD` parsing (no subprocess)
- Dirty state detection via `.git/index` mtime comparison
- Auto-refresh on command completion
- Worktree management

### Command Palette (Cmd+P)
- Searchable overlay listing all actions with their keyboard shortcuts

### Themes
- Built-in themes: Kinetic Monolith (cyan), Obsidian (orange), Phosphor (neon green)
- Theme persisted to `~/.config/amux/prefs.json`
- Runtime theme switching via the menu
- Material Design 3-inspired color hierarchy

### Status Bar
Each pane displays:
- Current process name
- Working directory (clickable to copy)
- Git branch and dirty state

## Keyboard Shortcuts

| Action | Shortcut |
|---|---|
| New Session | Cmd+T |
| Close Session | Cmd+Shift+W |
| Rename Session | Cmd+Shift+N |
| Switch Session 1-9 | Cmd+1...9 |
| Split Vertical | Cmd+D |
| Split Horizontal | Cmd+Shift+D |
| Next Tab | Cmd+Shift+] |
| Previous Tab | Cmd+Shift+[ |
| Move Focus | Cmd+Shift+Arrow |
| Resize Pane | Ctrl+Opt+Arrow |
| Zoom Pane | Cmd+Shift+Enter |
| Equalize Panes | Cmd+Opt+= |
| Toggle Sidebar | Cmd+\ |
| Find | Cmd+F |
| Command Palette | Cmd+P |
| Increase Font | Cmd++ |
| Decrease Font | Cmd+- |
| Reset Font | Cmd+0 |

## Tech Stack

- **Language:** Swift 5.9
- **UI:** AppKit
- **Rendering:** Metal, QuartzCore
- **Terminal Engine:** [Ghostty](https://ghostty.org/) (libghostty, statically linked)
- **Build:** Swift Package Manager

## Building

### Prerequisites

- macOS 14+
- Swift 5.9+
- Pre-built Ghostty library in `vendor/ghostty/macos/GhosttyKit.xcframework/`

### Build and Run

```bash
./run.sh
```

This builds the Swift package, assembles a `.app` bundle at `.build/amux.app` with shell integration resources and terminfo, then launches the app.

## Project Structure

```
Sources/amux/
  App/           -- Entry point and AppDelegate
  Bridge/        -- Ghostty library wrapper and input translation
  Models/        -- Session, SplitTree, ThemeManager
  Views/         -- Window, panes, sidebar, command palette, search
  Helpers/       -- Process and git utilities
  Shortcuts/     -- Keyboard shortcut definitions
Resources/
  Fonts/         -- Bundled UI fonts (Space Grotesk)
vendor/
  ghostty/       -- Ghostty library and shell integration sources
```

## Configuration

amux stores its configuration in `~/.config/amux/`:

| File | Contents |
|---|---|
| `sessions.json` | Session state (names, colors, split layout, tabs) |
| `prefs.json` | Theme preference |

## License

MIT -- see [LICENSE](LICENSE).
