import Foundation

enum AgentType: String, Codable {
    case claudeCode = "claude_code"
    case codex = "codex"

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        }
    }

    var processName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex:      return "codex"
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

    var displayName: String {
        switch self {
        case .starting: return "starting"
        case .working: return "working"
        case .idle: return "idle"
        case .needsInput: return "needs input"
        case .needsPermission: return "needs permission"
        case .exited: return "exited"
        }
    }

    var isAttentionRequired: Bool {
        switch self {
        case .needsInput, .needsPermission:
            return true
        default:
            return false
        }
    }
}

class AgentInstance: Identifiable {
    let id: UUID
    let agentType: AgentType
    let paneID: UUID
    let tabID: UUID?
    let sessionID: UUID
    let pid: pid_t
    var state: AgentState
    var stateSetByHook: Bool = false
    let startedAt: Date
    var lastStateChange: Date
    var notificationMessage: String?
    var workingDirectory: String?
    var currentToolName: String?

    init(agentType: AgentType, paneID: UUID, tabID: UUID? = nil, sessionID: UUID, pid: pid_t) {
        self.id = UUID()
        self.agentType = agentType
        self.paneID = paneID
        self.tabID = tabID
        self.sessionID = sessionID
        self.pid = pid
        self.state = .starting
        self.startedAt = Date()
        self.lastStateChange = Date()
    }

    func updateState(_ newState: AgentState, message: String? = nil, fromHook: Bool = false) {
        state = newState
        stateSetByHook = fromHook
        lastStateChange = Date()
        notificationMessage = message
    }

    var durationString: String {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        if elapsed < 60 {
            return "\(elapsed)s"
        } else if elapsed < 3600 {
            return "\(elapsed / 60)m"
        } else {
            let hours = elapsed / 3600
            let minutes = (elapsed % 3600) / 60
            return "\(hours)h\(minutes)m"
        }
    }
}
