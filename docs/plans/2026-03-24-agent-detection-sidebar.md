# Agent Detection & Sidebar Tab Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a 5th sidebar tab that detects AI agents (Claude Code, Codex) running in terminal panes, shows their state with input-required signalling, and provides rich actions.

**Architecture:** Hybrid detection -- process-tree scanning as baseline, Claude Code hooks via wrapper script injection for rich state. Unix socket server in-process for hook communication. AgentManager model owns agent state, publishes via NotificationCenter. AgentListView (NSOutlineView) in sidebar grouped by session then agent type.

**Tech Stack:** Swift/AppKit, Unix domain sockets, shell wrapper scripts, Claude Code `--settings` hook injection

---

### Task 1: AgentState and AgentInstance models

**Files:**
- Create: `Sources/amux/Models/AgentInstance.swift`

**Step 1: Create the model file**

```swift
import Foundation

enum AgentType: String, Codable {
    case claudeCode = "claude_code"
    case codex = "codex"

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var processName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }
}

enum AgentState: Equatable {
    case starting
    case working
    case idle
    case needsInput
    case needsPermission
    case exited

    var isAttentionRequired: Bool {
        self == .needsInput || self == .needsPermission
    }
}

class AgentInstance: Identifiable {
    let id: UUID
    let agentType: AgentType
    let paneID: UUID
    let sessionID: UUID
    let pid: pid_t
    var state: AgentState
    let startedAt: Date
    var lastStateChange: Date
    var notificationMessage: String?
    var workingDirectory: String?

    init(agentType: AgentType, paneID: UUID, sessionID: UUID, pid: pid_t) {
        self.id = UUID()
        self.agentType = agentType
        self.paneID = paneID
        self.sessionID = sessionID
        self.pid = pid
        self.state = .starting
        self.startedAt = Date()
        self.lastStateChange = Date()
    }

    func updateState(_ newState: AgentState, message: String? = nil) {
        state = newState
        lastStateChange = Date()
        notificationMessage = message
    }

    var durationString: String {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3600)h\((elapsed % 3600) / 60)m"
    }
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/amux/Models/AgentInstance.swift
git commit -m "feat: add AgentInstance and AgentState models"
```

---

### Task 2: AgentManager with process scanning

**Files:**
- Create: `Sources/amux/Models/AgentManager.swift`
- Reference: `Sources/amux/Helpers/ProcessHelper.swift`
- Reference: `Sources/amux/Models/SessionManager.swift`

**Step 1: Create AgentManager with polling-based detection**

```swift
import Foundation

class AgentManager {
    static let didChangeNotification = Notification.Name("AgentManagerDidChange")
    static let attentionCountDidChangeNotification = Notification.Name("AgentManagerAttentionCountDidChange")

    private var agents: [UUID: AgentInstance] = [:]  // keyed by AgentInstance.id
    private var agentsByPane: [UUID: UUID] = [:]      // paneID -> agentID (latest per pane)
    private var pollTimer: Timer?
    private weak var sessionManager: SessionManager?

    /// Map of paneID -> shellPid, updated externally by SplitContainerView.
    var paneShellPids: [UUID: pid_t] = [:]

    /// Map of paneID -> sessionID, updated externally.
    var paneSessionMap: [UUID: UUID] = [:]

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.scanForAgents()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Public accessors

    var allAgents: [AgentInstance] {
        Array(agents.values).sorted { $0.startedAt < $1.startedAt }
    }

    var attentionCount: Int {
        agents.values.filter { $0.state.isAttentionRequired }.count
    }

    func agents(forSession sessionID: UUID) -> [AgentInstance] {
        agents.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func agent(forPane paneID: UUID) -> AgentInstance? {
        guard let agentID = agentsByPane[paneID] else { return nil }
        return agents[agentID]
    }

    // MARK: - Process scanning

    private static let knownAgents: [String: AgentType] = [
        "claude": .claudeCode,
        "codex": .codex,
    ]

    private func scanForAgents() {
        var seenPaneIDs = Set<UUID>()

        for (paneID, shellPid) in paneShellPids {
            guard let sessionID = paneSessionMap[paneID] else { continue }

            // Walk process tree from shell to find agent processes
            if let agentInfo = findAgentProcess(under: shellPid) {
                seenPaneIDs.insert(paneID)

                if let existingID = agentsByPane[paneID],
                   let existing = agents[existingID],
                   existing.pid == agentInfo.pid {
                    // Agent already tracked -- update state from process tree if no hooks
                    if existing.state == .starting || !hasHookSupport(existing) {
                        let inferredState = inferState(agentPid: agentInfo.pid)
                        if existing.state != inferredState {
                            existing.updateState(inferredState)
                        }
                    }
                } else {
                    // New agent detected
                    let instance = AgentInstance(
                        agentType: agentInfo.type,
                        paneID: paneID,
                        sessionID: sessionID,
                        pid: agentInfo.pid
                    )
                    instance.workingDirectory = ProcessHelper.cwd(of: agentInfo.pid)
                    agents[instance.id] = instance
                    agentsByPane[paneID] = instance.id
                }
            }
        }

        // Mark agents as exited if their pane no longer has the agent process
        for (paneID, agentID) in agentsByPane {
            if !seenPaneIDs.contains(paneID),
               let agent = agents[agentID],
               agent.state != .exited {
                agent.updateState(.exited)
            }
        }

        // Remove exited agents after 30 seconds
        let cutoff = Date().addingTimeInterval(-30)
        let toRemove = agents.values.filter {
            $0.state == .exited && $0.lastStateChange < cutoff
        }
        for agent in toRemove {
            agents.removeValue(forKey: agent.id)
            agentsByPane.removeValue(forKey: agent.paneID)
        }

        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        NotificationCenter.default.post(name: Self.attentionCountDidChangeNotification, object: self)
    }

    private struct AgentProcessInfo {
        let pid: pid_t
        let type: AgentType
    }

    private func findAgentProcess(under shellPid: pid_t) -> AgentProcessInfo? {
        // Walk the process tree depth-first looking for known agent names
        var stack: [pid_t] = [shellPid]
        var visited = Set<pid_t>()

        while let current = stack.popLast() {
            guard !visited.contains(current) else { continue }
            visited.insert(current)

            if current != shellPid,
               let name = ProcessHelper.name(of: current),
               let agentType = Self.knownAgents[name] {
                return AgentProcessInfo(pid: current, type: agentType)
            }

            // Add children to stack
            let children = ProcessHelper.childPidsOf(current)
            stack.append(contentsOf: children)
        }
        return nil
    }

    private func inferState(agentPid: pid_t) -> AgentState {
        // If agent has child processes, it's working; otherwise idle
        let children = ProcessHelper.childPidsOf(agentPid)
        return children.isEmpty ? .idle : .working
    }

    private func hasHookSupport(_ agent: AgentInstance) -> Bool {
        // Only Claude Code has hook support via our wrapper
        return agent.agentType == .claudeCode && agent.state != .starting
    }

    // MARK: - Hook event handling

    func handleHookEvent(paneID: UUID, event: String, data: [String: Any]) {
        guard let agentID = agentsByPane[paneID],
              let agent = agents[agentID] else { return }

        switch event {
        case "session-start":
            agent.updateState(.working)
        case "stop":
            agent.updateState(.idle)
        case "pre-tool-use", "post-tool-use":
            agent.updateState(.working)
        case "notification":
            let message = data["message"] as? String ?? ""
            if message.lowercased().contains("permission") {
                agent.updateState(.needsPermission, message: message)
            } else {
                agent.updateState(.needsInput, message: message)
            }
        default:
            break
        }

        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        NotificationCenter.default.post(name: Self.attentionCountDidChangeNotification, object: self)
    }

    // MARK: - Actions

    func sendInterrupt(to agent: AgentInstance) {
        kill(agent.pid, SIGINT)
    }

    func killAgent(_ agent: AgentInstance) {
        kill(agent.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            kill(agent.pid, SIGKILL)
        }
    }
}
```

Note: `ProcessHelper.childPidsOf` is currently private. We need to make it internal.

**Step 2: Make ProcessHelper.childPidsOf accessible**

In `Sources/amux/Helpers/ProcessHelper.swift:74`, change `private static func childPidsOf` to `static func childPidsOf`.

**Step 3: Verify it compiles**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/amux/Models/AgentManager.swift Sources/amux/Helpers/ProcessHelper.swift
git commit -m "feat: add AgentManager with process-tree scanning and hook event handling"
```

---

### Task 3: Unix socket server for hook communication

**Files:**
- Create: `Sources/amux/Helpers/AgentSocketServer.swift`

**Step 1: Create the socket server**

```swift
import Foundation

class AgentSocketServer {
    private let socketPath: String
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var clientSources: [DispatchSourceRead] = []

    var onEvent: ((UUID, String, [String: Any]) -> Void)?

    init() {
        socketPath = "/tmp/amux-\(ProcessInfo.processInfo.processIdentifier).sock"
    }

    var path: String { socketPath }

    func start() {
        // Clean up stale socket
        unlink(socketPath)

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            print("[AgentSocketServer] Failed to create socket")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }

        guard bindResult == 0 else {
            print("[AgentSocketServer] Failed to bind: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return
        }

        listen(socketFD, 5)

        let src = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        src.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
            }
        }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        for cs in clientSources {
            cs.cancel()
        }
        clientSources.removeAll()
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        unlink(socketPath)
    }

    private func acceptClient() {
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { return }

        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .main)
        clientSource.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFD)
        }
        clientSource.setCancelHandler {
            close(clientFD)
        }
        clientSource.resume()
        clientSources.append(clientSource)
    }

    private func readFromClient(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)

        guard bytesRead > 0 else {
            // Client disconnected -- clean up
            clientSources.removeAll { source in
                if let fdSource = source as? DispatchSourceRead,
                   fdSource.handle == UInt(fd) {
                    fdSource.cancel()
                    return true
                }
                return false
            }
            return
        }

        guard let jsonString = String(bytes: buffer.prefix(bytesRead), encoding: .utf8),
              let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let paneIDString = json["paneId"] as? String,
              let paneID = UUID(uuidString: paneIDString),
              let event = json["event"] as? String else {
            return
        }

        let data = json["data"] as? [String: Any] ?? [:]
        onEvent?(paneID, event, data)
    }

    deinit {
        stop()
    }
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/amux/Helpers/AgentSocketServer.swift
git commit -m "feat: add Unix socket server for agent hook communication"
```

---

### Task 4: Claude Code wrapper script and hook helper

**Files:**
- Create: `Resources/agent-hooks/claude-wrapper.sh`
- Create: `Resources/agent-hooks/amux-agent-hook.sh`

**Step 1: Create the claude wrapper script**

```bash
#!/bin/bash
# amux wrapper for claude -- injects hooks when running inside amux
# Falls through to real claude binary when AMUX_PANE_ID is not set

if [ -z "$AMUX_PANE_ID" ] || [ -z "$AMUX_SOCKET_PATH" ]; then
    # Not inside amux, find and exec the real claude
    SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
    REAL_CLAUDE=""
    IFS=: read -ra PATH_DIRS <<< "$PATH"
    for dir in "${PATH_DIRS[@]}"; do
        resolved="$(cd "$dir" 2>/dev/null && pwd)"
        [ "$resolved" = "$SELF_DIR" ] && continue
        if [ -x "$dir/claude" ]; then
            REAL_CLAUDE="$dir/claude"
            break
        fi
    done
    if [ -z "$REAL_CLAUDE" ]; then
        echo "amux: could not find real claude binary" >&2
        exit 1
    fi
    exec "$REAL_CLAUDE" "$@"
fi

# Inside amux -- find real claude
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_CLAUDE=""
IFS=: read -ra PATH_DIRS <<< "$PATH"
for dir in "${PATH_DIRS[@]}"; do
    resolved="$(cd "$dir" 2>/dev/null && pwd)"
    [ "$resolved" = "$SELF_DIR" ] && continue
    if [ -x "$dir/claude" ]; then
        REAL_CLAUDE="$dir/claude"
        break
    fi
done

if [ -z "$REAL_CLAUDE" ]; then
    echo "amux: could not find real claude binary" >&2
    exit 1
fi

# Find the hook helper script (sibling to this wrapper)
HOOK_SCRIPT="$SELF_DIR/amux-agent-hook.sh"

# Check if user already specified --resume, --session-id, or --continue
HAS_SESSION=false
for arg in "$@"; do
    case "$arg" in
        --resume|--session-id|--continue) HAS_SESSION=true ;;
    esac
done

# Build hook settings JSON
HOOK_SETTINGS=$(cat <<ENDJSON
{
  "hooks": {
    "SessionStart": [{"type": "command", "command": "$HOOK_SCRIPT session-start"}],
    "Stop": [{"type": "command", "command": "$HOOK_SCRIPT stop"}],
    "Notification": [{"type": "command", "command": "$HOOK_SCRIPT notification"}],
    "PreToolUse": [{"type": "command", "command": "$HOOK_SCRIPT pre-tool-use"}],
    "PostToolUse": [{"type": "command", "command": "$HOOK_SCRIPT post-tool-use"}]
  }
}
ENDJSON
)

exec "$REAL_CLAUDE" --settings "$HOOK_SETTINGS" "$@"
```

**Step 2: Create the hook helper script**

```bash
#!/bin/bash
# amux-agent-hook.sh -- forwards Claude Code hook events to amux via Unix socket
# Called by Claude Code hooks with event name as $1, hook data on stdin

EVENT="$1"
PANE_ID="$AMUX_PANE_ID"
SOCKET="$AMUX_SOCKET_PATH"

[ -z "$PANE_ID" ] || [ -z "$SOCKET" ] || [ -z "$EVENT" ] && exit 0
[ ! -S "$SOCKET" ] && exit 0

# Read stdin (hook JSON data) if available
STDIN_DATA=""
if [ ! -t 0 ]; then
    STDIN_DATA=$(cat)
fi

# Extract message from notification events
MESSAGE=""
if [ "$EVENT" = "notification" ] && [ -n "$STDIN_DATA" ]; then
    # Try to extract message field from JSON
    MESSAGE=$(echo "$STDIN_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null || echo "")
fi

# Build JSON payload
PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'paneId': '$PANE_ID',
    'event': '$EVENT',
    'data': {'message': '''$MESSAGE'''}
}))
" 2>/dev/null)

[ -z "$PAYLOAD" ] && exit 0

# Send via Unix socket using python (available on macOS)
python3 -c "
import socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect('$SOCKET')
    sock.sendall(b'$PAYLOAD')
except:
    pass
finally:
    sock.close()
" 2>/dev/null

exit 0
```

**Step 3: Make both scripts executable**

Run: `chmod +x Resources/agent-hooks/claude-wrapper.sh Resources/agent-hooks/amux-agent-hook.sh`

**Step 4: Commit**

```bash
git add Resources/agent-hooks/
git commit -m "feat: add Claude Code wrapper and hook helper scripts"
```

---

### Task 5: Set AMUX_PANE_ID and AMUX_SOCKET_PATH env vars per pane

**Files:**
- Modify: `Sources/amux/Views/TerminalPane.swift:110-125` (init and surface creation)
- Modify: `Sources/amux/App/AppDelegate.swift:97-154` (setupAmuxShellIntegration)

**Step 1: Add env vars to TerminalPane surface creation**

In `TerminalPane.swift`, the `statusFilePath` is already set per-pane in the status dir at `/tmp/amux-<pid>/`. We need to similarly set `AMUX_PANE_ID` and `AMUX_SESSION_ID` before surface creation.

Add a `sessionID` property to TerminalPane and set env vars before `createSurface()` calls. Find where `AMUX_STATUS_FILE` is set (search for it) and add the new env vars alongside it.

The pattern is: set env var before surface creation, unset after (since Ghostty forks the shell synchronously on main thread and inherits the env).

Add these lines wherever `AMUX_STATUS_FILE` is set:

```swift
setenv("AMUX_PANE_ID", paneID.uuidString, 1)
setenv("AMUX_SESSION_ID", sessionID?.uuidString ?? "", 1)
```

And after surface creation:
```swift
unsetenv("AMUX_PANE_ID")
unsetenv("AMUX_SESSION_ID")
```

**Step 2: Set AMUX_SOCKET_PATH in AppDelegate**

In `setupAmuxShellIntegration()` in AppDelegate, add the socket path env var. This is set once globally since it's the same for all panes:

```swift
// Set socket path for agent hook communication
setenv("AMUX_SOCKET_PATH", AgentSocketServer.defaultPath, 1)
```

Where `AgentSocketServer.defaultPath` is a static property returning `/tmp/amux-<pid>.sock`.

**Step 3: Set up agent-hooks wrapper on PATH**

In `setupAmuxShellIntegration()`, locate the agent-hooks directory in Resources and prepend it to PATH:

```swift
// Prepend agent-hooks dir to PATH for claude wrapper
let agentHooksDir = (resourcePath as NSString).appendingPathComponent("agent-hooks")
if FileManager.default.fileExists(atPath: agentHooksDir) {
    let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    setenv("PATH", "\(agentHooksDir):\(currentPath)", 1)
}
```

**Step 4: Verify it compiles**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Sources/amux/Views/TerminalPane.swift Sources/amux/App/AppDelegate.swift
git commit -m "feat: set AMUX_PANE_ID, AMUX_SOCKET_PATH env vars and prepend agent-hooks to PATH"
```

---

### Task 6: Wire AgentManager into AppDelegate

**Files:**
- Modify: `Sources/amux/App/AppDelegate.swift:5-59`

**Step 1: Add AgentManager and socket server to AppDelegate**

Add properties:
```swift
private var agentManager: AgentManager!
private var agentSocketServer: AgentSocketServer!
```

In `applicationDidFinishLaunching`, after sessionManager is created:
```swift
agentManager = AgentManager(sessionManager: sessionManager)

agentSocketServer = AgentSocketServer()
agentSocketServer.onEvent = { [weak self] paneID, event, data in
    self?.agentManager.handleHookEvent(paneID: paneID, event: event, data: data)
}
agentSocketServer.start()
agentManager.startPolling()
```

Pass `agentManager` to `MainWindowController` init (will need to update its init signature).

**Step 2: Update MainWindowController to accept AgentManager**

Pass through to SidebarView.

**Step 3: Verify it compiles**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/amux/App/AppDelegate.swift Sources/amux/Views/MainWindowController.swift
git commit -m "feat: wire AgentManager and socket server into app lifecycle"
```

---

### Task 7: Feed pane shell PIDs to AgentManager

**Files:**
- Modify: `Sources/amux/Views/SplitContainerView.swift`

**Step 1: Update pane registration to feed PIDs to AgentManager**

SplitContainerView already creates TerminalPanes and knows their shellPid. Add a reference to AgentManager and update `paneShellPids` whenever a pane's shell PID is discovered or a pane is created/destroyed.

The existing polling in SplitContainerView (or wherever CWD is polled) should also update `agentManager.paneShellPids[paneID] = shellPid` and `agentManager.paneSessionMap[paneID] = sessionID`.

**Step 2: Verify it compiles**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/amux/Views/SplitContainerView.swift
git commit -m "feat: feed pane shell PIDs and session mapping to AgentManager"
```

---

### Task 8: AgentListView (sidebar content)

**Files:**
- Create: `Sources/amux/Views/AgentListView.swift`

**Step 1: Create the agent list view with NSOutlineView**

```swift
import AppKit

protocol AgentListViewDelegate: AnyObject {
    func agentListDidRequestFocusPane(paneID: UUID, sessionID: UUID)
    func agentListDidRequestSendInterrupt(agent: AgentInstance)
    func agentListDidRequestKillAgent(agent: AgentInstance)
    func agentListDidRequestSendInput(agent: AgentInstance)
}

class AgentListView: NSView {
    weak var delegate: AgentListViewDelegate?
    private var agentManager: AgentManager!

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!

    // Data model for outline: session groups -> agent type groups -> agents
    private var sessionGroups: [SessionGroup] = []

    struct SessionGroup {
        let sessionID: UUID
        let sessionName: String
        var typeGroups: [TypeGroup]
    }

    struct TypeGroup {
        let type: AgentType
        var agents: [AgentInstance]
    }

    init(agentManager: AgentManager) {
        self.agentManager = agentManager
        super.init(frame: .zero)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(agentsDidChange),
            name: AgentManager.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // ... setup outline view, data source, delegate, cell views, context menu
    // Follow the same patterns as WorktreeView and GitStatusView
}
```

The view should:
- Use `NSOutlineView` with session group headers (collapsible) and type subheaders
- Custom cell view (`AgentCellView`) with: state dot, agent name, duration, cwd/notification message
- Pulsing animation on state dot for `.needsInput` / `.needsPermission`
- Tinted background for attention-required items
- Right-click context menu: Focus Pane, Send Interrupt, Kill Agent, Send Input...
- Empty state label: "No agents running"
- Refresh on `AgentManager.didChangeNotification`

**Step 2: Verify it compiles**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/amux/Views/AgentListView.swift
git commit -m "feat: add AgentListView with grouped outline and agent cells"
```

---

### Task 9: Add agents tab to SidebarView

**Files:**
- Modify: `Sources/amux/Views/SidebarView.swift:13-18` (SidebarMode enum)
- Modify: `Sources/amux/Views/SidebarView.swift:20-50` (properties)
- Modify: `Sources/amux/Views/SidebarView.swift:118-131` (setupUI)
- Modify: `Sources/amux/Views/SidebarView.swift:133-178` (setupIconBar)
- Modify: `Sources/amux/Views/SidebarView.swift:290-339` (setupConstraints)
- Modify: `Sources/amux/Views/SidebarView.swift:348-369` (setMode)
- Modify: `Sources/amux/Views/SidebarView.swift:66-75` (themeDidChange)

**Step 1: Add `.agents` to SidebarMode**

```swift
enum SidebarMode {
    case sessions
    case fileTree
    case worktrees
    case gitStatus
    case agents
}
```

**Step 2: Add agentsButton and agentListView properties**

```swift
private var agentsButton: DimIconButton!
private var agentListView: AgentListView!
private var agentsBadge: NSView!  // red dot badge
```

**Step 3: Add the button in setupIconBar**

After the gitStatusButton setup, add:
```swift
agentsButton = makeIconBarButton(symbolName: "cpu", action: #selector(agentsButtonClicked))
iconBar.addSubview(agentsButton)
```

Add constraints for the 5th button after gitStatusButton.

**Step 4: Add badge view on agentsButton**

Create a small red circle (8x8) positioned at top-right of agentsButton, hidden by default. Update visibility on `AgentManager.attentionCountDidChangeNotification`.

**Step 5: Setup agentListView in setupUI**

```swift
private func setupAgentListView() {
    agentListView = AgentListView(agentManager: agentManager)
    agentListView.translatesAutoresizingMaskIntoConstraints = false
    agentListView.isHidden = true
    agentListView.delegate = self
    addSubview(agentListView)
}
```

**Step 6: Update setMode to handle .agents**

```swift
agentsButton.isActiveState = mode == .agents
agentListView.isHidden = mode != .agents
```

**Step 7: Update constraints for agentListView**

Same constraint pattern as other views (top to iconBarSeparator, leading, trailing to contentTrailing, bottom).

**Step 8: Update themeDidChange**

Add `agentsButton.isActiveState = mode == .agents`.

**Step 9: Verify it compiles**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 10: Commit**

```bash
git add Sources/amux/Views/SidebarView.swift
git commit -m "feat: add agents tab to sidebar with badge for attention-required agents"
```

---

### Task 10: Wire agent actions through delegate chain

**Files:**
- Modify: `Sources/amux/Views/SidebarView.swift:3-11` (SidebarViewDelegate)
- Modify: `Sources/amux/Views/MainWindowController.swift` or `AppDelegate.swift`

**Step 1: Add agent action methods to SidebarViewDelegate**

```swift
func sidebarDidRequestFocusAgentPane(paneID: UUID, sessionID: UUID)
func sidebarDidRequestSendInterrupt(agent: AgentInstance)
func sidebarDidRequestKillAgent(agent: AgentInstance)
```

**Step 2: Implement in MainWindowController/AppDelegate**

- `focusAgentPane`: switch to session, set focusedPaneID, focus the pane
- `sendInterrupt`: call `agentManager.sendInterrupt(to:)`
- `killAgent`: call `agentManager.killAgent(_:)`

**Step 3: SidebarView conforms to AgentListViewDelegate, forwards to its own delegate**

**Step 4: Verify it compiles**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Sources/amux/Views/SidebarView.swift Sources/amux/Views/MainWindowController.swift Sources/amux/App/AppDelegate.swift
git commit -m "feat: wire agent actions through delegate chain for focus, interrupt, kill"
```

---

### Task 11: Pulsing animation for attention-required agents

**Files:**
- Modify: `Sources/amux/Views/AgentListView.swift` (AgentCellView)

**Step 1: Add pulsing CABasicAnimation to state dot**

When configuring a cell for `.needsInput` or `.needsPermission`:
```swift
let pulse = CABasicAnimation(keyPath: "opacity")
pulse.fromValue = 1.0
pulse.toValue = 0.3
pulse.duration = 0.8
pulse.autoreverses = true
pulse.repeatCount = .infinity
stateDot.layer?.add(pulse, forKey: "pulse")
```

Remove the animation for other states.

**Step 2: Add tinted background for attention cells**

Use a semi-transparent warning color (orange for needsInput, red for needsPermission) as cell background.

**Step 3: Verify it compiles and run visually**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/amux/Views/AgentListView.swift
git commit -m "feat: add pulsing animation and tinted background for attention-required agents"
```

---

### Task 12: Copy agent-hooks to build output

**Files:**
- Modify: `run.sh` (or build script)

**Step 1: Copy agent-hooks to Resources in build**

In `run.sh`, after the shell-integration copy, add:

```bash
AGENT_HOOKS_SRC="$SCRIPT_DIR/Resources/agent-hooks"
AGENT_HOOKS_DST="$RESOURCES_DIR/agent-hooks"
if [ -d "$AGENT_HOOKS_SRC" ]; then
    mkdir -p "$AGENT_HOOKS_DST"
    cp -R "$AGENT_HOOKS_SRC"/* "$AGENT_HOOKS_DST/"
    chmod +x "$AGENT_HOOKS_DST"/*.sh
fi
```

**Step 2: Rename wrapper to `claude` (no .sh extension)**

The wrapper must be named `claude` (not `claude-wrapper.sh`) for PATH-based interception to work. Rename `Resources/agent-hooks/claude-wrapper.sh` to `Resources/agent-hooks/claude` in the copy step, or rename the source file.

**Step 3: Verify build script works**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && bash run.sh 2>&1 | head -20`
Expected: Builds and copies agent-hooks to .build/amux.app/Contents/Resources/agent-hooks/

**Step 4: Commit**

```bash
git add run.sh Resources/agent-hooks/
git commit -m "feat: copy agent-hooks to app bundle and rename wrapper to 'claude'"
```

---

### Task 13: Integration testing -- manual verification

**Step 1: Build and launch amux**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && bash run.sh`

**Step 2: Verify the agents tab appears**

- Click the `cpu` icon in sidebar icon bar
- Should show "No agents running" empty state

**Step 3: Launch claude in a pane**

- Type `claude` in a terminal pane
- Within 3 seconds, it should appear in the agents list
- Grouped under the current session name, under "Claude Code" type header

**Step 4: Verify state transitions**

- When claude is working: green dot, "working" state
- When claude finishes: gray dot, "idle" state
- When claude asks for permission: red pulsing dot, message shown
- When claude exits: dim dot, then removed after 30s

**Step 5: Verify badge**

- When claude needs input/permission, red badge should appear on sidebar cpu icon
- Badge should clear when state changes

**Step 6: Verify actions**

- Right-click agent item: context menu with Focus Pane, Send Interrupt, Kill Agent
- Focus Pane should switch to the correct session and pane
- Send Interrupt should send Ctrl+C to the agent

**Step 7: Commit final adjustments**

```bash
git add -A
git commit -m "fix: integration adjustments from manual testing"
```
