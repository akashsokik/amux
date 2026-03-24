import Foundation

class AgentManager {
    static let didChangeNotification = Notification.Name("AgentManagerDidChange")
    static let attentionCountDidChangeNotification = Notification.Name("AgentManagerAttentionCountDidChange")

    private var agents: [UUID: AgentInstance] = [:]
    private var agentsByKey: [String: UUID] = [:]  // "paneID:tabID" -> agentID
    private var pendingHookEvents: [String: [PendingHookEvent]] = [:]
    private var pollTimer: Timer?
    private weak var sessionManager: SessionManager?

    struct ShellEntry {
        let paneID: UUID
        let tabID: UUID?
        let sessionID: UUID
        let shellPid: pid_t
    }

    private struct PendingHookEvent {
        let event: String
        let data: [String: Any]
        let receivedAt: Date
    }

    /// All tracked shells, updated externally each poll cycle.
    var shellEntries: [ShellEntry] = []

    private static let knownAgents: [String: AgentType] = ["claude": .claudeCode, "codex": .codex]

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.scanForAgents()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Public Accessors

    var allAgents: [AgentInstance] {
        agents.values.sorted { $0.startedAt < $1.startedAt }
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
        agents.values.first { $0.paneID == paneID }
    }

    private func entryKey(_ entry: ShellEntry) -> String {
        key(forPaneID: entry.paneID, tabID: entry.tabID)
    }

    private func key(forPaneID paneID: UUID, tabID: UUID?) -> String {
        "\(paneID.uuidString):\(tabID?.uuidString ?? "main")"
    }

    private func agent(forPaneID paneID: UUID, tabID: UUID?) -> AgentInstance? {
        if let agentID = agentsByKey[key(forPaneID: paneID, tabID: tabID)] {
            return agents[agentID]
        }
        if tabID == nil {
            let paneAgents = agents.values.filter { $0.paneID == paneID }
            if paneAgents.count == 1 {
                return paneAgents[0]
            }
        }
        return nil
    }

    private func applyHookEvent(_ event: String, data: [String: Any], to agent: AgentInstance) {
        let toolName = data["toolName"] as? String
        let toolCommand = data["toolCommand"] as? String

        switch event {
        // Claude Code PascalCase events
        case "SessionStart":
            agent.updateState(.working, fromHook: true)
        case "Stop":
            agent.updateState(.idle, fromHook: true)
            agent.currentToolName = nil
        case "PreToolUse":
            agent.updateState(.working, fromHook: true)
            // Track what tool is being used for richer UI context
            if let tool = toolName {
                agent.currentToolName = tool
                if tool == "Bash", let cmd = toolCommand, !cmd.isEmpty {
                    let short = String(cmd.prefix(60))
                    agent.currentToolName = "Bash: \(short)"
                }
            }
        case "PostToolUse":
            agent.updateState(.working, fromHook: true)
            agent.currentToolName = nil
        case "Notification":
            if let message = data["message"] as? String, !message.isEmpty {
                if message.lowercased().contains("permission") {
                    agent.updateState(.needsPermission, message: message, fromHook: true)
                } else {
                    agent.updateState(.needsInput, message: message, fromHook: true)
                }
            }
        case "PermissionRequest":
            let tool = toolName ?? "tool"
            agent.updateState(.needsPermission, message: "Allow \(tool)?", fromHook: true)
            agent.currentToolName = nil
        case "UserPromptSubmit":
            // User submitted input, agent is about to start working
            agent.updateState(.working, fromHook: true)
            agent.currentToolName = nil
        // Codex events (lowercase/camelCase)
        case "AfterAgent", "stop":
            agent.updateState(.idle, fromHook: true)
            agent.currentToolName = nil
        case "AfterToolUse", "pre_tool_use", "post_tool_use":
            agent.updateState(.working, fromHook: true)
        case "session-start":
            agent.updateState(.working, fromHook: true)
        default:
            break
        }
    }

    /// If a hook set .working but no follow-up hook arrived within this window,
    /// fall back to process-based inference. Prevents stale "working" if Stop hook fails.
    private static let hookStalenessInterval: TimeInterval = 10

    private func refreshProcessDerivedState(for agent: AgentInstance, agentPid: pid_t) {
        // Hook-driven states are more precise than coarse process-tree inference.
        // But if the last hook is stale (e.g. Stop event was lost), fall back.
        if agent.stateSetByHook {
            let age = Date().timeIntervalSince(agent.lastStateChange)
            let isStale = age > Self.hookStalenessInterval && agent.state == .working
            if !isStale { return }
            // Hook state is stale -- clear the flag and fall through to inference
            agent.stateSetByHook = false
        }

        let inferredState = inferState(agentPid: agentPid)
        if agent.state != inferredState {
            agent.updateState(inferredState)
        }
    }

    // MARK: - Process Scanning

    private func scanForAgents() {
        let previousAttentionCount = attentionCount
        var activeKeys = Set<String>()

        for entry in shellEntries {
            let key = entryKey(entry)
            if let (agentPid, agentType) = findAgentProcess(under: entry.shellPid) {
                activeKeys.insert(key)

                if let existingAgentID = agentsByKey[key],
                   let existingAgent = agents[existingAgentID],
                   existingAgent.pid == agentPid {
                    if let cwd = ProcessHelper.cwd(of: agentPid) {
                        existingAgent.workingDirectory = cwd
                    }
                    if let pendingEvents = pendingHookEvents.removeValue(forKey: key) {
                        for pending in pendingEvents {
                            applyHookEvent(pending.event, data: pending.data, to: existingAgent)
                        }
                    }
                    refreshProcessDerivedState(for: existingAgent, agentPid: agentPid)
                } else {
                    let instance = AgentInstance(
                        agentType: agentType,
                        paneID: entry.paneID,
                        tabID: entry.tabID,
                        sessionID: entry.sessionID,
                        pid: agentPid
                    )
                    instance.updateState(.working)
                    instance.workingDirectory = ProcessHelper.cwd(of: agentPid)
                    if let pendingEvents = pendingHookEvents.removeValue(forKey: key) {
                        for pending in pendingEvents {
                            applyHookEvent(pending.event, data: pending.data, to: instance)
                        }
                    }
                    refreshProcessDerivedState(for: instance, agentPid: agentPid)
                    agents[instance.id] = instance
                    agentsByKey[key] = instance.id
                }
            }
        }

        // Mark agents as exited if their shell no longer has the agent process
        for (key, agentID) in agentsByKey {
            if !activeKeys.contains(key),
               let agent = agents[agentID],
               agent.state != .exited {
                agent.updateState(.exited)
            }
        }

        // Remove exited agents after 1 second
        let now = Date()
        let toRemove = agents.filter { (_, agent) in
            agent.state == .exited && now.timeIntervalSince(agent.lastStateChange) > 1
        }
        for (id, _) in toRemove {
            agents.removeValue(forKey: id)
            let keyToRemove = agentsByKey.first { $0.value == id }?.key
            if let k = keyToRemove {
                agentsByKey.removeValue(forKey: k)
            }
        }

        let staleCutoff = now.addingTimeInterval(-15)
        pendingHookEvents = pendingHookEvents.compactMapValues { events in
            let freshEvents = events.filter { $0.receivedAt >= staleCutoff }
            return freshEvents.isEmpty ? nil : freshEvents
        }

        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        if attentionCount != previousAttentionCount {
            NotificationCenter.default.post(name: Self.attentionCountDidChangeNotification, object: self)
        }
    }

    private func findAgentProcess(under shellPid: pid_t) -> (pid_t, AgentType)? {
        let isRuntime = { (name: String?) -> Bool in
            guard let n = name else { return false }
            return n == "node" || n == "bun" || n == "deno"
        }

        var stack = Array(ProcessHelper.childPidsOf(shellPid).reversed())
        var visited = Set<pid_t>()

        while let pid = stack.popLast() {
            if !visited.insert(pid).inserted { continue }

            let procName = ProcessHelper.name(of: pid)
            if let name = procName, let agentType = Self.knownAgents[name] {
                return (pid, agentType)
            }
            if isRuntime(procName),
               let cmdName = ProcessHelper.commandName(of: pid),
               let agentType = Self.knownAgents[cmdName] {
                return (pid, agentType)
            }

            stack.append(contentsOf: ProcessHelper.childPidsOf(pid).reversed())
        }
        return nil
    }

    private func inferState(agentPid: pid_t) -> AgentState {
        ProcessHelper.childPidsOf(agentPid).isEmpty ? .idle : .working
    }

    // MARK: - Hook Event Handling

    func handleHookEvent(paneID: UUID, tabID: UUID?, event: String, data: [String: Any]) {
        let key = key(forPaneID: paneID, tabID: tabID)
        guard let agent = agent(forPaneID: paneID, tabID: tabID) else {
            pendingHookEvents[key, default: []].append(
                PendingHookEvent(event: event, data: data, receivedAt: Date())
            )
            return
        }

        let previousAttentionCount = attentionCount
        applyHookEvent(event, data: data, to: agent)

        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        if attentionCount != previousAttentionCount {
            NotificationCenter.default.post(name: Self.attentionCountDidChangeNotification, object: self)
        }
    }

    // MARK: - Actions

    func sendInterrupt(to agent: AgentInstance) {
        kill(agent.pid, SIGINT)
    }

    func killAgent(_ agent: AgentInstance) {
        kill(agent.pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            kill(agent.pid, SIGKILL)
        }
    }
}
