import Foundation

class AgentManager {
    static let didChangeNotification = Notification.Name("AgentManagerDidChange")
    static let attentionCountDidChangeNotification = Notification.Name("AgentManagerAttentionCountDidChange")

    private var agents: [UUID: AgentInstance] = [:]
    private var agentsByPane: [UUID: UUID] = [:]
    private var pollTimer: Timer?
    private weak var sessionManager: SessionManager?

    /// Map of paneID -> shellPid, updated externally via replaceAllPaneMappings.
    private var paneShellPids: [UUID: pid_t] = [:]
    /// Map of paneID -> sessionID.
    private var paneSessionMap: [UUID: UUID] = [:]

    /// Cache of known agent PIDs to avoid repeated KERN_PROCARGS2 lookups.
    /// Maps pid -> (agentType, lastSeen). Entries older than 10s are evicted.
    private var knownAgentPids: [pid_t: (type: AgentType, lastSeen: Date)] = [:]

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

    // MARK: - Pane Mapping (called externally)

    /// Replace ALL pane mappings atomically. This ensures closed panes are removed.
    func replaceAllPaneMappings(_ mappings: [(paneID: UUID, shellPid: pid_t, sessionID: UUID)]) {
        paneShellPids.removeAll()
        paneSessionMap.removeAll()
        for m in mappings {
            paneShellPids[m.paneID] = m.shellPid
            paneSessionMap[m.paneID] = m.sessionID
        }
    }

    // MARK: - Public Accessors

    var allAgents: [AgentInstance] {
        agents.values.filter { $0.state != .exited }.sorted { $0.startedAt < $1.startedAt }
    }

    var attentionCount: Int {
        agents.values.filter { $0.state.isAttentionRequired }.count
    }

    func agents(forSession sessionID: UUID) -> [AgentInstance] {
        agents.values
            .filter { $0.sessionID == sessionID && $0.state != .exited }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func agent(forPane paneID: UUID) -> AgentInstance? {
        guard let agentID = agentsByPane[paneID] else { return nil }
        return agents[agentID]
    }

    // MARK: - Process Scanning

    private func scanForAgents() {
        let previousAttentionCount = attentionCount
        var activePaneAgents: Set<UUID> = []

        // Prune stale pane entries where the shell process is dead
        for (paneID, shellPid) in paneShellPids {
            if ProcessHelper.name(of: shellPid) == nil {
                paneShellPids.removeValue(forKey: paneID)
                paneSessionMap.removeValue(forKey: paneID)
            }
        }

        for (paneID, shellPid) in paneShellPids {
            if let (agentPid, agentType) = findAgentProcess(under: shellPid) {
                activePaneAgents.insert(paneID)

                if let existingAgentID = agentsByPane[paneID],
                   let existingAgent = agents[existingAgentID],
                   existingAgent.pid == agentPid {
                    // Already tracked -- update cwd
                    if let cwd = ProcessHelper.cwd(of: agentPid) {
                        existingAgent.workingDirectory = cwd
                    }
                } else {
                    // New agent -- remove old agent for this pane first (prevents orphans)
                    if let oldAgentID = agentsByPane[paneID] {
                        agents.removeValue(forKey: oldAgentID)
                    }

                    guard let sessionID = paneSessionMap[paneID] else { continue }
                    let instance = AgentInstance(
                        agentType: agentType,
                        paneID: paneID,
                        sessionID: sessionID,
                        pid: agentPid
                    )
                    instance.updateState(.working)
                    instance.workingDirectory = ProcessHelper.cwd(of: agentPid)
                    agents[instance.id] = instance
                    agentsByPane[paneID] = instance.id
                }
            }
        }

        // Remove agents whose pane no longer has the agent process -- immediate removal
        for (paneID, agentID) in agentsByPane {
            if !activePaneAgents.contains(paneID) {
                agents.removeValue(forKey: agentID)
                agentsByPane.removeValue(forKey: paneID)
            }
        }

        // Evict stale entries from the known-agent PID cache
        let now = Date()
        knownAgentPids = knownAgentPids.filter { now.timeIntervalSince($0.value.lastSeen) < 10 }

        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        if attentionCount != previousAttentionCount {
            NotificationCenter.default.post(name: Self.attentionCountDidChangeNotification, object: self)
        }
    }

    private func findAgentProcess(under shellPid: pid_t) -> (pid_t, AgentType)? {
        // Only check DIRECT children of the shell. Agents (claude, codex) are
        // direct children of the shell process. Walking deeper finds their
        // sub-processes (MCP servers, workers) which can cause false duplicates.
        let children = ProcessHelper.childPidsOf(shellPid)

        for child in children {
            // Check PID cache first (avoids expensive KERN_PROCARGS2 calls)
            if let cached = knownAgentPids[child] {
                knownAgentPids[child] = (cached.type, Date())
                return (child, cached.type)
            }

            let procName = ProcessHelper.name(of: child)
            if let name = procName, let agentType = Self.knownAgents[name] {
                knownAgentPids[child] = (agentType, Date())
                return (child, agentType)
            }
            // Node.js CLI tools: proc_name is "node" but argv[0] is "claude"/"codex"
            if procName == "node" || procName == "bun" || procName == "deno",
               let cmdName = ProcessHelper.commandName(of: child),
               let agentType = Self.knownAgents[cmdName] {
                knownAgentPids[child] = (agentType, Date())
                return (child, agentType)
            }
        }
        return nil
    }

    // MARK: - Hook Event Handling

    func handleHookEvent(paneID: UUID, event: String, data: [String: Any]) {
        guard let agentID = agentsByPane[paneID],
              let agent = agents[agentID] else { return }

        let previousAttentionCount = attentionCount

        switch event {
        case "session-start":
            agent.updateState(.working)
        case "stop":
            agent.updateState(.idle)
        case "pre-tool-use", "post-tool-use":
            agent.updateState(.working)
        case "notification":
            if let message = data["message"] as? String {
                if message.lowercased().contains("permission") {
                    agent.updateState(.needsPermission, message: message)
                } else {
                    agent.updateState(.needsInput, message: message)
                }
            }
        default:
            break
        }

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
