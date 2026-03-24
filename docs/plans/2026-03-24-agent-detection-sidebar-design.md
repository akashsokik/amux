# Agent Detection & Listing Sidebar Tab

## Overview

Add a 5th sidebar tab ("Agents") that detects, lists, and provides actions for AI coding agents (Claude Code, Codex) running in terminal panes. Uses a hybrid approach: process-tree scanning as baseline detection, with Claude Code hook injection for rich state reporting.

## Detection Layer (Hybrid)

### Baseline -- Process Scanning
- Polling timer (every 2-3s) walks process trees for each pane's shell PID via `ProcessHelper`
- Looks for known agent process names: `claude`, `codex`
- Creates `AgentInstance` when agent process appears, removes when gone

### Rich State -- Hook Injection
- amux sets env vars in every shell: `AMUX_PANE_ID`, `AMUX_SESSION_ID`, `AMUX_SOCKET_PATH`
- Wrapper script at `~/.config/amux/bin/claude` placed on PATH ahead of real binary
- Wrapper detects `AMUX_PANE_ID`, injects Claude Code hooks via `--settings` (SessionStart, Stop, Notification, PreToolUse, PostToolUse), then execs real binary
- Hooks call bundled `amux-agent-hook` helper which forwards JSON over Unix socket
- For Codex (no hook support), falls back to process-tree inference only

### State Model
```
enum AgentState {
    case starting        // Process detected, no hook fired yet
    case working         // Hook: tool use in progress / generating
    case idle            // Hook: stop event (finished responding)
    case needsInput      // Hook: notification "waiting for input"
    case needsPermission // Hook: notification "needs permission"
    case exited          // Process gone
}
```

## Data Model

### AgentInstance
```
struct AgentInstance {
    let id: UUID
    let agentType: AgentType       // .claudeCode, .codex
    let paneID: UUID
    let sessionID: UUID
    let pid: pid_t
    var state: AgentState
    var startedAt: Date
    var lastStateChange: Date
    var notificationMessage: String?
    var workingDirectory: String?
}
```

### AgentManager
- Owns `[UUID: AgentInstance]` dictionary
- Runs polling timer for process scanning
- Listens on Unix socket for hook events
- Publishes changes via NotificationCenter
- Maps hook events (keyed by AMUX_PANE_ID) to correct AgentInstance

## Sidebar UI -- Agents Tab

### Tab
- 5th icon button using `cpu` SF Symbol
- New `SidebarMode.agents` case
- Badge on icon when any agent has `.needsInput` or `.needsPermission` (count of agents needing attention)

### List Structure (NSOutlineView)
- Grouped by session (collapsible section headers)
- Within each session, grouped by agent type (subheader: "Claude Code", "Codex")

### Agent List Item
```
[State Dot]  Claude Code          [12m]
             ~/project-name       [...]
```

- State dot: green (working), gray (idle), orange pulsing (needs input), red pulsing (needs permission), dim (exited)
- When needsInput/needsPermission: notification message replaces cwd line, item background tinted warning color

### Actions (context menu + inline button)
- Focus Pane -- switch to session, focus pane
- Send Interrupt (Ctrl+C) -- SIGINT
- Kill Agent -- SIGTERM/SIGKILL
- Restart Agent -- kill + re-run
- Send Input... -- text field, sends to pane PTY

## Hook Infrastructure

### Unix Socket Server
- Path: `/tmp/amux-<pid>.sock`
- Set via `AMUX_SOCKET_PATH` env var
- Accepts JSON: `{"event": "...", "paneId": "...", "data": {...}}`

### Wrapper Script (`~/.config/amux/bin/claude`)
- Detects `AMUX_PANE_ID` -- if absent, passthrough
- Finds real `claude` by scanning PATH (skipping own dir)
- Injects `--settings` with hook definitions
- Execs real binary

### Event Mapping
| Claude Code Hook       | AgentState        |
|------------------------|-------------------|
| SessionStart           | .working          |
| PreToolUse             | .working          |
| PostToolUse            | .working          |
| Stop                   | .idle             |
| Notification (input)   | .needsInput       |
| Notification (perm)    | .needsPermission  |

### Fallback (no hooks)
- Process alive + has children = .working
- Process alive + no children = .idle
- Process gone = .exited
