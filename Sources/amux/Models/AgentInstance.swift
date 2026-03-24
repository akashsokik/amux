import Foundation

enum AgentType: String, Codable {
    case claudeCode
    case codex

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
