import Foundation

class AgentManager {
    static let didChangeNotification = Notification.Name("AgentManagerDidChange")
    static let attentionCountDidChangeNotification = Notification.Name("AgentManagerAttentionCountDidChange")

    private var agents: [UUID: AgentInstance] = [:]
    private var agentsByKey: [String: UUID] = [:]  // "paneID:tabID" -> agentID
    private var pollTimer: Timer?
    private weak var sessionManager: SessionManager?

    struct ShellEntry {
        let paneID: UUID
        let tabID: UUID?
        let sessionID: UUID
        let shellPid: pid_t
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
        "\(entry.paneID.uuidString):\(entry.tabID?.uuidString ?? "main")"
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
        for (id, agent) in toRemove {
            agents.removeValue(forKey: id)
            let keyToRemove = agentsByKey.first { $0.value == id }?.key
            if let k = keyToRemove {
                agentsByKey.removeValue(forKey: k)
            }
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

        // Only check direct children and one level deep -- agents are
        // direct children of the shell (or one hop via env/npx)
        let directChildren = ProcessHelper.childPidsOf(shellPid)
        for child in directChildren {
            let procName = ProcessHelper.name(of: child)
            // Direct match (native binary or renamed process)
            if let name = procName, let agentType = Self.knownAgents[name] {
                return (child, agentType)
            }
            // Runtime process -- scan args for agent identity
            if isRuntime(procName),
               let cmdName = ProcessHelper.commandName(of: child),
               let agentType = Self.knownAgents[cmdName] {
                return (child, agentType)
            }
            // One level deeper (e.g. env -> node, npx -> node)
            for grandchild in ProcessHelper.childPidsOf(child) {
                let gcName = ProcessHelper.name(of: grandchild)
                if let name = gcName, let agentType = Self.knownAgents[name] {
                    return (grandchild, agentType)
                }
                if isRuntime(gcName),
                   let cmdName = ProcessHelper.commandName(of: grandchild),
                   let agentType = Self.knownAgents[cmdName] {
                    return (grandchild, agentType)
                }
            }
        }
        return nil
    }

    private func hasHookSupport(_ agent: AgentInstance) -> Bool {
        return agent.agentType == .claudeCode && agent.state != .starting
    }

    // MARK: - Hook Event Handling

    func handleHookEvent(paneID: UUID, event: String, data: [String: Any]) {
        // Find agent by pane ID (hooks fire with pane ID, not tab ID)
        guard let agent = agents.values.first(where: { $0.paneID == paneID }) else { return }

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
