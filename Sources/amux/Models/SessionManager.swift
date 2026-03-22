import Foundation
import Combine

class SessionManager: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var activeSessionIndex: Int = 0

    /// The currently active session, or nil if no sessions exist.
    var activeSession: Session? {
        guard !sessions.isEmpty,
              activeSessionIndex >= 0,
              activeSessionIndex < sessions.count
        else {
            return nil
        }
        return sessions[activeSessionIndex]
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        createSession()
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        let sessions: [Session.CodableRepresentation]
        let activeSessionIndex: Int
    }

    private static var persistenceURL: URL {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amux")
        return configDir.appendingPathComponent("sessions.json")
    }

    func save() {
        let state = PersistedState(
            sessions: sessions.map { Session.CodableRepresentation(from: $0) },
            activeSessionIndex: activeSessionIndex
        )
        do {
            let configDir = Self.persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: Self.persistenceURL, options: .atomic)
        } catch {
            print("[SessionManager] Failed to save state: \(error)")
        }
    }

    static func restore() -> SessionManager? {
        guard let data = try? Data(contentsOf: persistenceURL) else { return nil }
        guard let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return nil }
        guard !state.sessions.isEmpty else { return nil }

        let manager = SessionManager(restored: true)
        for codableSession in state.sessions {
            let session = codableSession.toSession()
            session.objectWillChange
                .sink { [weak manager] _ in
                    manager?.objectWillChange.send()
                }
                .store(in: &manager.cancellables)
            manager.sessions.append(session)
        }
        manager.activeSessionIndex = min(state.activeSessionIndex, manager.sessions.count - 1)
        return manager
    }

    /// Private init that skips creating a default session (used by restore).
    private init(restored: Bool) {
        // No default session created
    }

    // MARK: - Create

    @discardableResult
    func createSession(name: String? = nil) -> Session {
        let sessionName = name ?? nextSessionName()
        let session = Session(name: sessionName)

        // Forward child objectWillChange so the manager's subscribers
        // are notified when any session changes.
        session.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        sessions.append(session)
        activeSessionIndex = sessions.count - 1
        return session
    }

    // MARK: - Delete

    func deleteSession(at index: Int) {
        guard index >= 0, index < sessions.count else { return }
        sessions.remove(at: index)

        if sessions.isEmpty {
            activeSessionIndex = 0
        } else if activeSessionIndex >= sessions.count {
            activeSessionIndex = sessions.count - 1
        } else if activeSessionIndex > index {
            activeSessionIndex -= 1
        }
        // If activeSessionIndex == index and index is still valid, we now
        // point at the session that slid into this slot, which is fine.
    }

    func deleteSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }
        deleteSession(at: index)
    }

    // MARK: - Switch

    func switchToSession(at index: Int) {
        guard index >= 0, index < sessions.count else { return }
        activeSessionIndex = index
    }

    func switchToSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }
        activeSessionIndex = index
    }

    func nextSession() {
        guard !sessions.isEmpty else { return }
        activeSessionIndex = (activeSessionIndex + 1) % sessions.count
    }

    func previousSession() {
        guard !sessions.isEmpty else { return }
        activeSessionIndex = (activeSessionIndex - 1 + sessions.count) % sessions.count
    }

    // MARK: - Rename

    func renameSession(id: UUID, name: String) {
        guard let session = sessions.first(where: { $0.id == id }) else {
            return
        }
        session.name = name
    }

    // MARK: - Reorder

    func moveSession(from source: Int, to destination: Int) {
        guard source >= 0, source < sessions.count,
              destination >= 0, destination < sessions.count,
              source != destination
        else {
            return
        }

        let movingSession = sessions[source]
        let wasActive = (activeSessionIndex == source)

        sessions.remove(at: source)
        sessions.insert(movingSession, at: destination)

        if wasActive {
            activeSessionIndex = destination
        } else {
            // Recompute the active index by finding the session that was active.
            if let currentActive = sessions.firstIndex(where: {
                $0.id == activeSession?.id
            }) {
                activeSessionIndex = currentActive
            }
        }
    }

    // MARK: - Auto-naming

    private static let sessionNames = [
        "aurora", "breeze", "cascade", "drift", "ember",
        "flare", "glacier", "harbor", "iris", "jade",
        "kindle", "lunar", "mesa", "nova", "orbit",
        "prism", "quartz", "ridge", "spark", "tide",
        "umbra", "vortex", "wisp", "zenith", "apex",
        "bloom", "crest", "dusk", "echo", "frost",
        "grain", "haze", "inlet", "jetty", "knoll",
        "loom", "marsh", "nexus", "opal", "pulse",
        "reef", "shade", "trace", "vale", "wren",
    ]

    private func nextSessionName() -> String {
        let usedNames = Set(sessions.map { $0.name })
        let available = Self.sessionNames.filter { !usedNames.contains($0) }
        return available.randomElement() ?? "session-\(sessions.count + 1)"
    }
}
