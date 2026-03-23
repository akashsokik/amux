# Shell Hook Status Indicators Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace process-tree-walking status detection with shell hook scripts (like cmux) that report idle/running state via files, giving instant and reliable status indicators in the sidebar.

**Architecture:** Shell integration scripts for fish/zsh/bash hook into preexec (command start) and precmd (prompt shown). Each script writes "running" or "idle" to a per-pane status file. The app sets `AMUX_STATUS_FILE` env var before each Ghostty surface creation so the shell inherits a unique file path. App-side polling reads these files. Ghostty's existing COMMAND_FINISHED callback still provides exit codes for success/error states.

**Tech Stack:** Fish/Zsh/Bash shell scripts, Swift file I/O, setenv() for per-pane env injection

---

### Task 1: Create shell integration scripts

**Files:**
- Create: `Resources/shell-integration/fish/vendor_conf.d/amux.fish`
- Create: `Resources/shell-integration/amux.zsh`
- Create: `Resources/shell-integration/amux.bash`

Fish goes in `fish/vendor_conf.d/` for XDG_DATA_DIRS auto-loading (same mechanism Ghostty uses).

### Task 2: Auto-load shell integration at app startup

**Files:**
- Modify: `Sources/amux/App/AppDelegate.swift` (add setupAmuxShellIntegration after setupGhosttyResourcesDir)

Set env vars before any surfaces are created:
- Fish: Prepend to `XDG_DATA_DIRS` so Fish auto-loads from `vendor_conf.d/`
- Bash: Set `BASH_ENV` to source our script
- Zsh: Set `AMUX_ZSH_SCRIPT` env var (sourced from .zshrc or via ZDOTDIR wrapper)

### Task 3: Set AMUX_STATUS_FILE per pane before surface creation

**Files:**
- Modify: `Sources/amux/Views/TerminalPane.swift`

Add `statusFilePath` property. Before `createSurface()`, set `AMUX_STATUS_FILE` env var to a unique `/tmp/amux-{pid}/pane-{uuid}` path, then unset after creation. Safe because surface creation is synchronous on main thread.

### Task 4: Replace process-tree polling with file-based status reading

**Files:**
- Modify: `Sources/amux/Views/MainWindowController.swift`

Rewrite `pollSessionStatuses()` to read pane status files instead of walking the process tree. Keep COMMAND_FINISHED for success/error.

### Task 5: Clean up temp files on pane close and app exit

**Files:**
- Modify: `Sources/amux/Views/TerminalPane.swift` (deinit)
- Modify: `Sources/amux/App/AppDelegate.swift` (applicationWillTerminate)

### Task 6: Remove old process-tree debug code

**Files:**
- Modify: `Sources/amux/Helpers/ProcessHelper.swift` (remove debugChildPids)
- Modify: `Sources/amux/Views/TerminalPane.swift` (remove retryShellPidDiscovery)
- Remove debug print statements

### State transitions

```
Shell prompt shown (precmd)   -> file: "idle"    -> sidebar: dim dot
User runs command (preexec)   -> file: "running" -> sidebar: blue dot
Command finishes (Ghostty CB) -> session: success/error -> sidebar: green/red dot
Next prompt shown (precmd)    -> file: "idle"    -> sidebar: dim dot
```
