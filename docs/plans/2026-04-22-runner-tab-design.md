# Runner tab (right sidebar) — design

Status: approved, ready for implementation plan
Date: 2026-04-22

## Goal

Add a third tab to `RightSidebarView` called **Runner** that lets the user start, stop, and monitor project-local commands (dev servers, build scripts, make targets, arbitrary shell commands) without leaving the app. Primary use case: running one or more servers alongside agents and watching their logs inline, with the option to promote any task into a full Ghostty pane when TUI / color / interactivity is needed.

## Decisions locked during brainstorming

1. **Interaction model: hybrid** — auto-detected tasks (from `package.json`, `Makefile`, `Procfile`) unioned with user-pinned custom tasks in `.amux/tasks.json`.
2. **Log surface: hybrid** — inline plain-text stream in the sidebar by default, per-task "Open in pane" button to promote a running task into a Ghostty pane in the main area.
3. **Scope: per-worktree, config committed** — `.amux/tasks.json` lives at the worktree root; teams can commit or gitignore as they prefer. Tasks always run in the active worktree's cwd.
4. **Concurrency: multi-task, single-instance** — many different tasks may run in parallel; re-running a running task restarts it.

## Out of scope for v1

- Task dependencies / chains.
- Env var editing UI (inline `FOO=bar cmd` in the command string is fine).
- Multiple concurrent instances of the same task.
- Remote / SSH execution.
- Inline ANSI color or TUI rendering (use "Open in pane" for those).

## UX

Third icon in the right sidebar's icon bar (`play.circle` or `bolt.horizontal.circle`). Activating it swaps the right sidebar content to `RunnerPanelView`.

Layout, top to bottom:

1. **Header row** — "TASKS" title, refresh button (re-runs auto-detectors), "+" button (add custom task).
2. **Task list** — `NSOutlineView` grouped by source (`npm`, `make`, `Procfile`, `pinned`). Each row: play/stop toggle, task name, running-status dot, optional "custom override" badge.
3. **Draggable split** (reuse the `NSSplitView` chrome from `GitPanelView`).
4. **Log panel** — header shows selected task name plus actions: promote to pane, stop, clear. Below it, a scrollable text view tailing the selected task's log ring buffer. Auto-scroll with pin-on-scrollup behavior.

Empty states:

- No worktree open: "Open a worktree to run tasks."
- Worktree open, nothing detected, nothing pinned: "No tasks detected. Tap + to add one, or create `.amux/tasks.json`."

Optional v1 keybinding: `Cmd+R` toggles the Runner tab (mirrors the existing `Cmd+/` toggle).

## Architecture

### New files

- `Sources/amux/Views/RunnerPanelView.swift` — AppKit view, mirrors `GitPanelView`'s chrome, glass, and split conventions.
- `Sources/amux/Models/RunnerTask.swift` — value type: `id`, `name`, `command`, `cwd?`, `source` (`.npm | .make | .procfile | .pinned`).
- `Sources/amux/Models/RunnerTaskStore.swift` — loads `.amux/tasks.json`, runs auto-detectors, publishes the merged list; watches the file and the active worktree for changes.
- `Sources/amux/Models/TaskRunner.swift` — manages `TaskRunSession` instances (one per running task). Owns `Process`, pipes, ring buffer, lifecycle.
- `Sources/amux/Helpers/TaskAutoDetect.swift` — pure parsers for `package.json`, `Makefile`, `Procfile`.
- `Sources/amux/Helpers/ANSIStripper.swift` — CSI escape stripping for inline display.

### Touched files

- `Sources/amux/Views/RightSidebarView.swift` — add `.runner` to `RightSidebarMode`, add a third icon-bar button, host `RunnerPanelView`, route mode changes, update `applyMode()` / `themeDidChange()`.
- `Sources/amux/Views/MainWindowController.swift` — instantiate `RunnerPanelView`, wire the active-worktree-path binding, expose or reuse the "spawn terminal pane running command X" path used elsewhere for `TerminalPane`.
- (Optional) `Sources/amux/Shortcuts/…` — add `Cmd+R` shortcut.

## Data model and persistence

### `.amux/tasks.json`

```json
{
  "version": 1,
  "tasks": [
    { "id": "backend", "name": "Backend", "command": "./run.sh api", "cwd": null },
    { "id": "worker",  "name": "Worker",  "command": "cargo run -p worker" }
  ]
}
```

- `cwd` is optional; if null, runs in the active worktree root. If a relative path, resolved against the worktree root. Absolute paths are allowed but discouraged.
- `id` must be unique within the file; used as the React-style key for list rendering and for override matching.

### Merge rules

- Auto-detected tasks are keyed by `source:name` (e.g. `npm:dev`, `make:test`).
- Pinned tasks with the same `id` as an auto-detected task override that auto-detected task and render with a "custom" badge in place.
- Refresh button re-runs detectors. File watcher (`DispatchSource` on `.amux/tasks.json`) triggers a pinned reload.

### Auto-detect rules

- **`package.json`** — every key in `scripts` becomes `{pm} run {name}` where `{pm}` is:
  - `bun` if `bun.lock` or `bun.lockb` is present,
  - `pnpm` if `pnpm-lock.yaml` is present,
  - `yarn` if `yarn.lock` is present,
  - else `npm`.
- **`Makefile`** — regex `^([a-zA-Z0-9_-]+):` in the top-level Makefile, filter out names starting with `.`. Command = `make {name}`.
- **`Procfile`** — each `name: cmd` line becomes a task with the raw `cmd` (no prefix). Skip blank lines and lines starting with `#`.

## Process execution

### Spawn

- `Process` with `launchPath = /bin/sh`, `arguments = ["-lc", command]`. `-l` makes shell profile (aliases, PATH) apply. Matches how a developer would run the same command in Terminal.
- `currentDirectoryURL` = resolved `cwd` (worktree root by default).
- Env: inherit app env and override `TERM=dumb` so interactive tools suppress TUI sequences in the inline view. Promoted-to-pane spawns do not set this.
- `setpgid` so the process becomes its own process group; lets us `kill(-pgid)` the whole tree on stop.

### Capture

- One `Pipe` per stream (stdout, stderr). `readabilityHandler` appends incoming data to a serial queue, which writes into a single time-ordered ring buffer per `TaskRunSession`.
- Ring buffer caps: ~10,000 lines, ~2 MB. Oldest data evicted.
- UI tails the selected task's buffer via a coalesced notification (throttled to ~60 Hz) so a flood of log output cannot starve the main thread.

### Stop

- `SIGTERM` to the process group. After a 3-second grace period, escalate to `SIGKILL`.
- Session transitions to `terminated` with the exit code (or "killed" if we had to escalate).

### Restart

- Stop, wait for termination, then spawn.

### Promote to pane

- Capture current command and cwd.
- Stop the inline process.
- Call the existing `MainWindowController` / `TerminalPane` entry point for "open a new terminal pane running command X" (to be confirmed during implementation — we may need a small wrapper if the current API only supports opening a fresh shell).
- Inline log view clears and shows a one-line breadcrumb: "Promoted to pane at {timestamp}".

### Worktree awareness

- `RunnerPanelView` observes the active session's worktree path from `MainWindowController`.
- On worktree switch, swap to that worktree's `RunnerTaskStore` (cached map keyed by worktree path).
- Running sessions are keyed by `(worktreePath, taskId)`. When the user switches worktrees, sessions from other worktrees remain alive; their logs are hidden until the user switches back.
- v1.1 consideration: a global "running tasks" count badge in the icon bar across worktrees. Not required for v1.

## Error handling

| Case | Behavior |
|---|---|
| Command not on PATH (`sh -lc` returns 127) | Log shows `command not found`; session marked crashed with exit code 127. |
| Invalid JSON in `.amux/tasks.json` | One-line error banner above the task list with an "Edit file" button. Auto-detected tasks still render. |
| No worktree open | Empty state text. |
| No auto-detected tasks and no pinned file | Empty state text with guidance. |
| `Process` fails to spawn | Inline error from `NSError`; session marked crashed. |
| Output flood | Ring buffer caps; UI notifications coalesced. |
| `.amux/` does not exist when saving a new pinned task | Create the directory with `FileManager.createDirectory(withIntermediateDirectories: true)`. |

## Testing

- **Unit** — `TaskAutoDetect` parsers against fixture files for each source (happy path plus malformed cases).
- **Unit** — `RunnerTaskStore` merge/override semantics.
- **Unit** — `ANSIStripper` against a known set of escape sequences.
- **Integration smoke** — spawn `sh -c 'echo hi; exit 0'` and assert the buffer contains "hi" and exit status 0. Spawn `sleep 30`, `SIGTERM`, assert termination within the 3-second window.
- **Manual** — run a real Vite dev server, verify inline streaming. Promote to pane, verify the TUI renders correctly there. Invalid `tasks.json` shows the error banner. Open two worktrees, run the same task in each, confirm they do not collide.

## Open questions to confirm during implementation

1. What is the current API in `MainWindowController` / `TerminalPane` for spawning a terminal pane with a specific command? If none exists, we will add a small method rather than re-wiring the spawn path.
2. Icon glyph — `play.circle`, `bolt.horizontal.circle`, or `terminal.fill`? To be decided visually against the existing icon bar.
3. Whether to gitignore `.amux/tasks.json` by default (add to a repo-level `.gitignore` hint?) or leave it to the team. Default plan: do nothing automatic; the user decides.
