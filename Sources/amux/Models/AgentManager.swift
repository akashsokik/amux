import Foundation

class AgentManager {
    static let didChangeNotification = Notification.Name("AgentManagerDidChange")
    static let attentionCountDidChangeNotification = Notification.Name("AgentManagerAttentionCountDidChange")

    private var agents: [UUID: AgentInstance] = [:]
    private var agentsByPane: [UUID: UUID] = [:]
    private var pollTimer: Timer?
    private weak var sessionManager: SessionManager?

    /// Map of paneID -> shellPid, updated externally.
    var paneShellPids: [UUID: pid_t] = [:]
    /// Map of paneID -> sessionID, updated externally.
    var paneSessionMap: [UUID: UUID] = [:]

    static let knownAgents: [String: AgentType] = ["claude": .claudeCode, "codex": .codex]

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    // MARK: - Polling

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
        guard let agentID = agentsByPane[paneID] else { return nil }
        return agents[agentID]
    }

    // MARK: - Process Scanning

    private func scanForAgents() {
        let previousAttentionCount = attentionCount
        var activePaneAgents: Set<UUID> = []

        for (paneID, shellPid) in paneShellPids {
            if let (agentPid, agentType) = findAgentProcess(under: shellPid) {
                activePaneAgents.insert(paneID)

                if let existingAgentID = agentsByPane[paneID],
                   let existingAgent = agents[existingAgentID],
                   existingAgent.pid == agentPid {
                    // Already tracked with same pid -- update inferred state if no hook support
                    if !hasHookSupport(existingAgent) {
                        let inferred = inferState(agentPid: agentPid)
                        if existingAgent.state != inferred {
                            existingAgent.updateState(inferred)
                        }
                    }
                } else {
                    // New agent process found
                    let sessionID = paneSessionMap[paneID] ?? UUID()
                    let instance = AgentInstance(
                        agentType: agentType,
                        paneID: paneID,
                        sessionID: sessionID,
                        pid: agentPid
                    )
                    instance.workingDirectory = ProcessHelper.cwd(of: agentPid)
                    agents[instance.id] = instance
                    agentsByPane[paneID] = instance.id
                }
            }
        }

        // Mark agents as exited if their pane no longer has the agent process
        for (paneID, agentID) in agentsByPane {
            if !activePaneAgents.contains(paneID),
               let agent = agents[agentID],
               agent.state != .exited {
                agent.updateState(.exited)
            }
        }

        // Remove exited agents after 30 seconds
        let now = Date()
        let toRemove = agents.filter { (_, agent) in
            agent.state == .exited && now.timeIntervalSince(agent.lastStateChange) > 30
        }
        for (id, agent) in toRemove {
            agents.removeValue(forKey: id)
            agentsByPane.removeValue(forKey: agent.paneID)
        }

        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        if attentionCount != previousAttentionCount {
            NotificationCenter.default.post(name: Self.attentionCountDidChangeNotification, object: self)
        }
    }

    private func findAgentProcess(under shellPid: pid_t) -> (pid_t, AgentType)? {
        // Depth-first walk using ProcessHelper.childPidsOf
        let children = ProcessHelper.childPidsOf(shellPid)
        for child in children {
            if let name = ProcessHelper.name(of: child),
               let agentType = Self.knownAgents[name] {
                return (child, agentType)
            }
            // Recurse into children
            if let found = findAgentProcess(under: child) {
                return found
            }
        }
        return nil
    }

    private func inferState(agentPid: pid_t) -> AgentState {
        let children = ProcessHelper.childPidsOf(agentPid)
        return children.isEmpty ? .idle : .working
    }

    private func hasHookSupport(_ agent: AgentInstance) -> Bool {
        return agent.agentType == .claudeCode && agent.state != .starting
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
