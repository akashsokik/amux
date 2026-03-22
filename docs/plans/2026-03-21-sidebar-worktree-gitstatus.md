# Sidebar Worktree & Git Status Tabs Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add two new sidebar tabs -- Worktrees (discover/manage git worktrees) and Git Status (file-level status + diff stats) -- alongside the existing Sessions and File Tree tabs.

**Architecture:** Extend the sidebar icon bar from 2 to 4 buttons. Each tab has its own NSView that occupies the same constraint region, toggled via isHidden. A new GitHelper utility runs git commands via Process on a background queue. Both new views refresh on a `commandDidFinish` notification posted by AppDelegate.

**Tech Stack:** AppKit (NSOutlineView, NSTableView), Process for git CLI, NotificationCenter for refresh coordination.

---

### Task 1: Create GitHelper utility

**Files:**
- Create: `Sources/amux/Helpers/GitHelper.swift`

**Step 1: Create GitHelper with shell runner and repo root detection**

```swift
import Foundation

enum GitHelper {
    /// Run a git command synchronously and return stdout. Returns nil if not in a git repo or command fails.
    static func run(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Get the git repository root for a given directory. Returns nil if not in a git repo.
    static func repoRoot(from cwd: String) -> String? {
        return run(["rev-parse", "--show-toplevel"], in: cwd)
    }
}
```

**Step 2: Add worktree methods**

```swift
    // MARK: - Worktrees

    struct WorktreeInfo {
        let path: String
        let branch: String?
        let isMain: Bool
        let isCurrent: Bool
    }

    /// List all worktrees for the repo containing `cwd`.
    static func listWorktrees(from cwd: String) -> [WorktreeInfo] {
        guard let output = run(["worktree", "list", "--porcelain"], in: cwd) else { return [] }
        let currentRoot = repoRoot(from: cwd)

        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        var isBare = false

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                // Save previous entry
                if let path = currentPath {
                    worktrees.append(WorktreeInfo(
                        path: path,
                        branch: currentBranch,
                        isMain: isBare || worktrees.isEmpty,
                        isCurrent: path == currentRoot
                    ))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
                isBare = false
            } else if line.hasPrefix("branch refs/heads/") {
                currentBranch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "bare" {
                isBare = true
            } else if line.hasPrefix("detached") {
                currentBranch = nil // detached HEAD
            }
        }
        // Save last entry
        if let path = currentPath {
            worktrees.append(WorktreeInfo(
                path: path,
                branch: currentBranch,
                isMain: isBare || worktrees.isEmpty,
                isCurrent: path == currentRoot
            ))
        }

        return worktrees
    }

    /// Create a new worktree. Returns the path on success.
    static func addWorktree(from cwd: String, branch: String) -> Result<String, String> {
        guard let root = repoRoot(from: cwd) else {
            return .failure("Not a git repository")
        }
        let repoName = URL(fileURLWithPath: root).lastPathComponent
        let parentDir = URL(fileURLWithPath: root).deletingLastPathComponent().path
        let worktreePath = "\(parentDir)/\(repoName)-\(branch)"

        if let _ = run(["worktree", "add", worktreePath, "-b", branch], in: root) {
            return .success(worktreePath)
        }
        // Try without -b (branch might already exist)
        if let _ = run(["worktree", "add", worktreePath, branch], in: root) {
            return .success(worktreePath)
        }
        return .failure("Failed to create worktree")
    }

    /// Remove a worktree by path.
    static func removeWorktree(from cwd: String, path: String) -> Result<Void, String> {
        if let _ = run(["worktree", "remove", path], in: cwd) {
            return .success(())
        }
        return .failure("Failed to remove worktree")
    }
```

**Step 3: Add git status methods**

```swift
    // MARK: - Git Status

    struct StatusInfo {
        let branch: String
        let trackingBranch: String?
        let ahead: Int
        let behind: Int
        let files: [FileStatus]
    }

    struct FileStatus {
        enum Kind: String {
            case staged, modified, untracked, deleted, renamed
        }
        let path: String
        let kind: Kind
        let linesAdded: Int
        let linesRemoved: Int
    }

    /// Get git status + diff stats for the repo containing `cwd`.
    static func status(from cwd: String) -> StatusInfo? {
        guard let statusOutput = run(["status", "--porcelain=v2", "--branch"], in: cwd) else { return nil }

        var branch = "HEAD"
        var trackingBranch: String?
        var ahead = 0
        var behind = 0
        var files: [FileStatus] = []

        // Parse --porcelain=v2 output
        for line in statusOutput.components(separatedBy: "\n") {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                trackingBranch = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).components(separatedBy: " ")
                if parts.count >= 2 {
                    ahead = abs(Int(parts[0]) ?? 0)
                    behind = abs(Int(parts[1]) ?? 0)
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // Changed entry: "1 XY sub mH mI mW hH hO path" or "2 XY sub mH mI mW hH hO Xscore path\torigPath"
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 9 else { continue }
                let xy = parts[1]
                let indexChar = xy.first ?? "."
                let workChar = xy.count > 1 ? xy[xy.index(after: xy.startIndex)] : Character(".")
                let path = parts.dropFirst(8).joined(separator: " ").components(separatedBy: "\t").first ?? ""

                if indexChar != "." && indexChar != "?" {
                    let kind: FileStatus.Kind = indexChar == "D" ? .deleted : (indexChar == "R" ? .renamed : .staged)
                    files.append(FileStatus(path: path, kind: kind, linesAdded: 0, linesRemoved: 0))
                }
                if workChar != "." && workChar != "?" {
                    let kind: FileStatus.Kind = workChar == "D" ? .deleted : .modified
                    // Avoid duplicating if already staged
                    if !files.contains(where: { $0.path == path && $0.kind == kind }) {
                        files.append(FileStatus(path: path, kind: kind, linesAdded: 0, linesRemoved: 0))
                    }
                }
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst("? ".count))
                files.append(FileStatus(path: path, kind: .untracked, linesAdded: 0, linesRemoved: 0))
            }
        }

        // Enrich with diff stats
        let stagedStats = parseDiffNumstat(run(["diff", "--cached", "--numstat"], in: cwd))
        let unstagedStats = parseDiffNumstat(run(["diff", "--numstat"], in: cwd))

        for i in files.indices {
            let path = files[i].path
            if files[i].kind == .staged || files[i].kind == .renamed {
                if let stat = stagedStats[path] {
                    files[i] = FileStatus(path: path, kind: files[i].kind, linesAdded: stat.0, linesRemoved: stat.1)
                }
            } else if files[i].kind == .modified {
                if let stat = unstagedStats[path] {
                    files[i] = FileStatus(path: path, kind: files[i].kind, linesAdded: stat.0, linesRemoved: stat.1)
                }
            }
        }

        return StatusInfo(branch: branch, trackingBranch: trackingBranch, ahead: ahead, behind: behind, files: files)
    }

    private static func parseDiffNumstat(_ output: String?) -> [String: (Int, Int)] {
        guard let output = output else { return [:] }
        var result: [String: (Int, Int)] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let added = Int(parts[0]) ?? 0
            let removed = Int(parts[1]) ?? 0
            result[parts[2]] = (added, removed)
        }
        return result
    }
```

**Step 4: Build and verify**

Run: `swift build 2>&1`
Expected: Build succeeds (new file, no dependents yet)

**Step 5: Commit**

```bash
git add Sources/amux/Helpers/GitHelper.swift
git commit -m "feat: add GitHelper utility for worktree and status commands"
```

---

### Task 2: Create WorktreeView

**Files:**
- Create: `Sources/amux/Views/WorktreeView.swift`

**Step 1: Create WorktreeView with table view and header**

Model the view after `FileTreeView` -- a header label, a table view inside a scroll view, and a "+" button. Uses `GitHelper.listWorktrees(from:)` to populate. Each row shows branch name (bold if current worktree) and path underneath in tertiary text. Right-click context menu for "Remove Worktree" on non-main entries.

The view exposes:
- `var onOpenWorktree: ((String) -> Void)?` -- called when a row is clicked
- `var onCreateWorktree: ((String) -> Void)?` -- called after the "+" dialog succeeds (passes the new worktree path)
- `func refresh(cwd: String?)` -- re-runs git worktree list

Observe `Theme.didChangeNotification` for theme updates, and a new `GitHelper.commandDidFinishNotification` for auto-refresh.

**Step 2: Build and verify**

Run: `swift build 2>&1`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/amux/Views/WorktreeView.swift
git commit -m "feat: add WorktreeView sidebar tab"
```

---

### Task 3: Create GitStatusView

**Files:**
- Create: `Sources/amux/Views/GitStatusView.swift`

**Step 1: Create GitStatusView with outline view and header**

Model after `FileTreeView` -- header with branch name + ahead/behind badges + refresh button. An `NSOutlineView` with three section headers (Staged, Modified, Untracked) as root items, files as children. Each file row shows a colored status dot, path, and `+N -M` stats right-aligned.

The view exposes:
- `func refresh(cwd: String?)` -- re-runs `GitHelper.status(from:)` on a background queue, updates UI on main thread

Section headers are simple string-keyed items. Sections with zero files are hidden. If no files at all, show "Working tree clean" centered label.

Observe `Theme.didChangeNotification` and `GitHelper.commandDidFinishNotification`.

**Step 2: Build and verify**

Run: `swift build 2>&1`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/amux/Views/GitStatusView.swift
git commit -m "feat: add GitStatusView sidebar tab"
```

---

### Task 4: Extend SidebarView with 2 new tabs

**Files:**
- Modify: `Sources/amux/Views/SidebarView.swift`

**Step 1: Extend SidebarMode enum (line 11-14)**

Add `.worktrees` and `.gitStatus` cases.

**Step 2: Add new icon bar buttons and content views**

In `SidebarView` class properties (after line 28-32), add:
- `private var worktreeButton: NSButton!`
- `private var gitStatusButton: NSButton!`
- `private var worktreeView: WorktreeView!`
- `private var gitStatusView: GitStatusView!`

**Step 3: Update setupIconBar() (line 80-110)**

Add the two new buttons after `fileTreeButton`, chaining constraints:
- `worktreeButton` with SF Symbol `arrow.triangle.branch`, action `worktreeButtonClicked`
- `gitStatusButton` with SF Symbol `chart.bar.doc.horizontal`, action `gitStatusButtonClicked`

Update constraints to chain: sessions -> fileTree -> worktree -> gitStatus.

**Step 4: Add setup methods for new views**

Add `setupWorktreeView()` and `setupGitStatusView()` called from `setupUI()`. Both views start hidden, same constraint region as fileTreeView (pinned to `iconBarSeparator.bottomAnchor` through `bottomAnchor`, leading to trailing of contentTrailing).

Wire `worktreeView.onOpenWorktree` and `worktreeView.onCreateWorktree` to delegate calls.

**Step 5: Update setMode() (line 247-260)**

Update tint colors for all 4 buttons. Hide/show all 4 content views (plus the sessions header/scrollView). When switching to `.worktrees` or `.gitStatus`, call the respective view's `refresh(cwd:)` with `delegate?.sidebarCurrentDirectory()`.

**Step 6: Add public refresh method**

```swift
func updateGitViews(cwd: String?) {
    if mode == .worktrees { worktreeView.refresh(cwd: cwd) }
    if mode == .gitStatus { gitStatusView.refresh(cwd: cwd) }
}
```

**Step 7: Update themeDidChange() (line 52-59)**

Add tint color updates for the two new buttons.

**Step 8: Extend SidebarViewDelegate (line 2-9)**

Add `func sidebarDidRequestOpenWorktree(path: String)`.

**Step 9: Build and verify**

Run: `swift build 2>&1`
Expected: Build succeeds

**Step 10: Commit**

```bash
git add Sources/amux/Views/SidebarView.swift
git commit -m "feat: extend sidebar with worktree and git status tabs"
```

---

### Task 5: Wire AppDelegate and MainWindowController

**Files:**
- Modify: `Sources/amux/App/AppDelegate.swift`
- Modify: `Sources/amux/Views/MainWindowController.swift`

**Step 1: Add commandDidFinish notification to GitHelper**

In `GitHelper.swift`, add a static notification name:

```swift
static let commandDidFinishNotification = Notification.Name("GitCommandDidFinish")
```

**Step 2: Post notification from AppDelegate.surfaceCommandFinished (line 676-707)**

After the existing `pane.commandFinished(...)` call (line 680), add:

```swift
NotificationCenter.default.post(name: GitHelper.commandDidFinishNotification, object: nil)
```

**Step 3: Update paneFocused delegate (line 580-584)**

After `windowController.updateSidebarFileTree(path:)`, add:

```swift
windowController.updateSidebarGitViews(cwd: pane.queryShellCwd())
```

**Step 4: Update surfaceDidSetPwd (line 623-631)**

After `windowController.updateSidebarFileTree(path: pwd)`, add:

```swift
windowController.updateSidebarGitViews(cwd: pwd)
```

**Step 5: Implement sidebarDidRequestOpenWorktree in MainWindowController**

In the `SidebarViewDelegate` extension of `MainWindowController.swift`, add:

```swift
func sidebarDidRequestOpenWorktree(path: String) {
    let session = sessionManager.createSession(name: URL(fileURLWithPath: path).lastPathComponent)
    displaySession(session)
    // The new session's initial pane will start in the default directory.
    // Update its cwd to the worktree path after a brief delay for surface creation.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self = self,
              let focusedID = session.focusedPaneID,
              let pane = self.splitContainerView.pane(for: focusedID),
              let tv = pane.terminalView,
              let surface = tv.surface else { return }
        // Send a cd command to the shell
        let cmd = "cd \(path.replacingOccurrences(of: " ", with: "\\ "))\n"
        cmd.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(cmd.utf8.count))
        }
    }
    if windowController.isSidebarVisible {
        sidebarView.reloadSessions()
    }
}
```

Note: This requires accessing `sidebarView` -- check if it needs to become internal or if this method should live elsewhere. The existing `MainWindowController` has `sidebarView` as private. Either make it `private(set)` or add a forwarding method like `updateSidebarGitViews(cwd:)`.

**Step 6: Add updateSidebarGitViews to MainWindowController**

```swift
func updateSidebarGitViews(cwd: String?) {
    guard isSidebarVisible else { return }
    sidebarView.updateGitViews(cwd: cwd)
}
```

**Step 7: Build and verify**

Run: `swift build 2>&1`
Expected: Build succeeds

**Step 8: Commit**

```bash
git add Sources/amux/Helpers/GitHelper.swift Sources/amux/App/AppDelegate.swift Sources/amux/Views/MainWindowController.swift
git commit -m "feat: wire worktree and git status tabs to app lifecycle"
```

---

### Task 6: Final integration and verification

**Step 1: Full build**

Run: `swift build 2>&1`
Expected: Clean build with no errors

**Step 2: Manual verification checklist**

- App launches, sidebar shows 4 icon buttons
- Sessions tab works as before
- File tree tab works as before
- Worktrees tab: shows worktrees when in a git repo, empty state when not
- Worktrees tab: clicking "+" opens dialog, creates worktree, opens new session
- Worktrees tab: clicking a worktree opens session in that directory
- Worktrees tab: right-click "Remove" works on non-main worktrees
- Git Status tab: shows branch, ahead/behind, file list grouped by status
- Git Status tab: shows diff stats per file
- Git Status tab: "Working tree clean" when no changes
- Git Status tab: refresh button works
- Git Status tab: auto-refreshes after commands finish
- Theme switching updates all new views correctly

**Step 3: Commit**

```bash
git commit -m "feat: sidebar worktree and git status tabs complete"
```
