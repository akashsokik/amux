# Sidebar Session Status Indicators Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the random-color dot on sidebar session rows with a meaningful status indicator showing the focused pane's process state (idle, running, success, error).

**Architecture:** Add a `PaneStatus` enum to Session. Polling (3s timer in MainWindowController) detects idle/running via `ProcessHelper.foregroundChild`. Ghostty's `COMMAND_FINISHED` callback sets success/error. The sidebar's `SessionCellView` maps status to color.

**Tech Stack:** Swift, AppKit, Ghostty C bridge (existing), NotificationCenter

---

### Task 1: Add PaneStatus enum and property to Session

**Files:**
- Modify: `Sources/amux/Models/Session.swift:1-22`

**Step 1: Add enum and replace `hasActivity` with `paneStatus`**

Add `PaneStatus` enum before the class. Replace `@Published var hasActivity: Bool` with `@Published var paneStatus: PaneStatus`. Add a `statusColor` computed property. Keep `colorHex` and `color` for backward compat but they won't drive the dot anymore.

```swift
enum PaneStatus {
    case idle
    case running
    case success
    case error
}
```

Properties to add to Session:
- `@Published var paneStatus: PaneStatus` (replaces `hasActivity`)
- `var statusColor: NSColor` computed property mapping:
  - `.idle` -> `Theme.quaternaryText`
  - `.running` -> `Theme.primary`
  - `.success` -> green `NSColor(srgbRed: 0.596, green: 0.765, blue: 0.475, alpha: 1.0)` (#98c379)
  - `.error` -> red `NSColor(srgbRed: 0.878, green: 0.424, blue: 0.459, alpha: 1.0)` (#e06c75)

Init both constructors: `self.paneStatus = .idle` (replaces `self.hasActivity = false`)

**Step 2: Expose shell PID from TerminalPane**

Add `var shellProcessID: pid_t?` public read-only accessor to TerminalPane that returns `shellPid`.

### Task 2: Add status polling in MainWindowController

**Files:**
- Modify: `Sources/amux/Views/MainWindowController.swift:10-46`

**Step 1: Add a 3-second polling timer**

Add `private var statusPollTimer: Timer?` property. Start it in `init` after `setupViews()`. Invalidate in `deinit`.

```swift
private var statusPollTimer: Timer?
```

In init, after the NotificationCenter observer:
```swift
statusPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
    self?.pollSessionStatuses()
}
```

In deinit:
```swift
statusPollTimer?.invalidate()
```

**Step 2: Implement `pollSessionStatuses()`**

For each session, get the focused pane ID, look up the TerminalPane from splitContainerView (using cached panes for non-active sessions), check `ProcessHelper.foregroundChild(of:)`. If a foreground child exists, set `.running`. If no foreground child and current status is `.running`, set `.idle`. Don't overwrite `.success`/`.error` -- those get cleared when polling sees no foreground child (meaning the user is back at the prompt).

```swift
private func pollSessionStatuses() {
    for session in sessionManager.sessions {
        guard let focusedID = session.focusedPaneID,
              let pane = splitContainerView.pane(for: focusedID),
              let shellPid = pane.shellProcessID else { continue }

        let hasForeground = ProcessHelper.foregroundChild(of: shellPid) != nil

        if hasForeground {
            if session.paneStatus != .running {
                session.paneStatus = .running
            }
        } else {
            // Back at prompt -- clear any previous status
            if session.paneStatus != .idle {
                session.paneStatus = .idle
            }
        }
    }
    if isSidebarVisible {
        sidebarView.reloadSessions()
    }
}
```

### Task 3: Set success/error from COMMAND_FINISHED callback

**Files:**
- Modify: `Sources/amux/App/AppDelegate.swift:716-747`

**Step 1: Find the owning session and set status**

In `surfaceCommandFinished`, after finding the pane, find which session's `focusedPaneID` matches that pane. Set `session.paneStatus` to `.success` or `.error` based on exit code. This runs BEFORE the early return for short commands.

Add after the `guard let pane = findPane(...)` line, before the git notification:

```swift
// Update session status indicator
if let session = sessionManager.sessions.first(where: { $0.focusedPaneID == pane.paneID }) {
    session.paneStatus = (exitCode == 0 || exitCode == -1) ? .success : .error
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        if self.windowController.isSidebarVisible {
            self.windowController.sidebarView.reloadSessions()
        }
    }
}
```

### Task 4: Update SessionCellView to use statusColor

**Files:**
- Modify: `Sources/amux/Views/SidebarView.swift:520-524`

**Step 1: Change colorDot to use session.statusColor**

In `SessionCellView.configure()`, replace:
```swift
colorDot.layer?.backgroundColor = session.color.cgColor
```
with:
```swift
colorDot.layer?.backgroundColor = session.statusColor.cgColor
```

### Task 5: Make sidebarView accessible for reload

**Files:**
- Modify: `Sources/amux/Views/MainWindowController.swift:11`

Change `private var sidebarView: SidebarView!` to `private(set) var sidebarView: SidebarView!` so AppDelegate can trigger sidebar reload.
