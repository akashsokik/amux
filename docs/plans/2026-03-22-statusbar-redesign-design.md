# Status Bar Redesign

## Goal

Replace the current hardcoded status bar with a pluggable, segment-based system where every item is toggleable via the command palette and configurable via a JSON file.

## Layout

Single row, 22pt height, three zones: left | center | right. Each zone holds zero or more segments rendered in registration order.

## Core Abstraction

```swift
protocol StatusBarSegment {
    var id: String { get }
    var label: String { get }
    var icon: String { get }
    var position: SegmentPosition { get }
    var refreshInterval: TimeInterval { get }
    func render() -> NSView
    func update()
}

enum SegmentPosition { case left, center, right }
```

All segments -- built-in and custom -- conform to this protocol.

## Built-in Segments (all off by default)

| ID | Label | Position | Source |
|----|-------|----------|--------|
| process | Process | left | ProcessHelper.foregroundChild |
| cwd | Working Directory | center | ProcessHelper.cwd |
| git | Git Branch | right | ProcessHelper.gitBranch + gitIsDirty |
| cpu | CPU Usage | right | host_statistics (Mach API) |
| memory | Memory Usage | right | host_statistics (Mach API) |
| battery | Battery | right | IOKit / IOPSCopyPowerSourcesInfo |
| pane-count | Pane Count | left | Session.panes.count |
| uptime | Session Uptime | left | Date interval from session start |
| exit-code | Exit Code | left | Last command exit code, hidden when 0 |

## Custom Segments (Shell-based)

Users define custom segments in `~/.config/amux/statusbar.json`:

```json
{
  "enabled": ["process", "cwd"],
  "custom": [
    {
      "id": "docker",
      "label": "Docker",
      "icon": "shippingbox",
      "position": "right",
      "command": "docker ps -q | wc -l | tr -d ' '",
      "format": "{} containers",
      "interval": 10
    }
  ]
}
```

Custom segments run a shell command on a configurable interval and display stdout. The `format` field is optional; `{}` is replaced with the command output.

## Toggle Mechanism

- Command palette lists all registered segments under a "Status Bar" category
- Each entry shows a checkmark if enabled
- Selecting a segment toggles it on/off
- Toggling updates `~/.config/amux/statusbar.json` so state persists across launches
- On first launch with no config file, no segments are enabled

## StatusBarConfig

Singleton that:
- Reads/writes `~/.config/amux/statusbar.json`
- Provides `isEnabled(_ id: String) -> Bool`
- Provides `toggle(_ id: String)`
- Registers custom `ShellSegment` instances from the `custom` array
- Posts a notification when config changes so the bar can rebuild

## StatusBarManager

Owns the segment registry and coordinates rendering:
- Maintains `[StatusBarSegment]` for all registered segments
- On config change, rebuilds the visible segments in `PaneStatusBar`
- Manages per-segment timers based on `refreshInterval`

## PaneStatusBar Changes

- Remove all hardcoded labels/buttons/git views
- Replace with three `NSStackView`s (left, center, right)
- On rebuild, iterate enabled segments, call `render()`, add to appropriate stack
- Segments manage their own view content via `update()`
