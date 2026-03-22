# Sidebar Worktree & Git Status Tabs

## Overview

Add two new sidebar tabs to amux: a **Worktrees** tab for discovering and managing git worktrees, and a **Git Status** tab showing file-level status and diff stats for the current repo.

## Decisions

- Worktrees and git status are auto-discovered from the focused terminal pane's cwd
- Creating a worktree opens a new session in the new worktree directory
- Git status refreshes on `surfaceCommandFinished` + manual refresh button
- All git commands run via `Process` on a background queue

## Sidebar Icon Bar

4 buttons in the icon bar:

| Icon | SF Symbol | Mode |
|------|-----------|------|
| Terminal | `terminal` | Sessions |
| Folder | `folder` | File Tree |
| Branch | `arrow.triangle.branch` | Worktrees |
| Diff | `chart.bar.doc.horizontal` | Git Status |

`SidebarMode` enum: `.sessions`, `.fileTree`, `.worktrees`, `.gitStatus`

## Worktrees Tab

### Data Model

```swift
struct GitWorktreeInfo {
    let path: String
    let branch: String?      // nil if detached HEAD
    let isMain: Bool          // bare/main worktree
    let isCurrent: Bool       // matches focused pane's cwd
}
```

### UI

- Header: repo name (from git root)
- "+" button to create a new worktree
- List of worktrees, each showing branch name (bold if current) and relative path
- Right-click context menu: "Remove Worktree" (non-main only)

### Create Worktree Flow

1. Click "+"
2. Dialog asks for branch name
3. Runs `git worktree add ../<repo>-<branch> -b <branch>`
4. Creates a new session in the new worktree directory
5. Refreshes list

### Click Behavior

Clicking a worktree row opens a new session rooted in that worktree's path.

## Git Status Tab

### Data Model

```swift
struct GitStatusInfo {
    let branch: String
    let trackingBranch: String?
    let ahead: Int
    let behind: Int
    let files: [GitFileStatus]
}

struct GitFileStatus {
    enum Status { case staged, modified, untracked, deleted, renamed }
    let path: String
    let status: Status
    let linesAdded: Int
    let linesRemoved: Int
}
```

### UI

- Header: branch name with ahead/behind badges, refresh button
- Three collapsible sections (outline view):
  - **Staged** (green dot) -- files in index
  - **Modified** (yellow dot) -- unstaged changes
  - **Untracked** (grey dot) -- new files
- Each file row: status dot, relative path, `+N -M` stats right-aligned
- Empty state: "Working tree clean"

### Refresh Triggers

- Switching to the tab
- Focused pane changes
- `surfaceCommandFinished` callback fires (via notification)
- Manual refresh button

## Shared Infrastructure

### GitHelper (Helpers/GitHelper.swift)

Static methods running git commands via `Process`:

- `gitRepoRoot(from:)` -- `git rev-parse --show-toplevel`
- `listWorktrees(from:)` -- `git worktree list --porcelain`
- `addWorktree(from:branch:)` -- `git worktree add`
- `removeWorktree(from:path:)` -- `git worktree remove`
- `status(from:)` -- `git status --porcelain=v2 --branch` + `git diff --numstat` + `git diff --cached --numstat`

### Refresh Notification

`Notification.Name("GitDidRefresh")` posted by AppDelegate on `surfaceCommandFinished`. Both views observe this.

## Files

### New

| File | Purpose |
|------|---------|
| `Helpers/GitHelper.swift` | Git command utilities |
| `Models/GitWorktreeInfo.swift` | Worktree data struct |
| `Models/GitStatusInfo.swift` | Status data structs |
| `Views/WorktreeView.swift` | Worktree sidebar view |
| `Views/GitStatusView.swift` | Git status sidebar view |

### Modified

| File | Changes |
|------|---------|
| `SidebarView.swift` | 2 new icon bar buttons, 2 content views, extended mode enum |
| `AppDelegate.swift` | Post refresh notification, handle open-worktree delegate call |
