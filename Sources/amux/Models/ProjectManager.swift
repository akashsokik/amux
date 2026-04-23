import Combine
import Foundation

class ProjectManager: ObservableObject {
    @Published var projects: [Project] = []
    @Published var activeProjectIndex: Int = -1  // -1 means no project selected

    var activeProject: Project? {
        guard activeProjectIndex >= 0,
            activeProjectIndex < projects.count
        else { return nil }
        return projects[activeProjectIndex]
    }

    private var cancellables = Set<AnyCancellable>()

    init() {}

    // MARK: - Persistence

    private struct PersistedState: Codable {
        let projects: [Project.CodableRepresentation]
        let activeProjectIndex: Int
    }

    private static var persistenceURL: URL {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amux")
        return configDir.appendingPathComponent("projects.json")
    }

    func save() {
        let state = PersistedState(
            projects: projects.map { Project.CodableRepresentation(from: $0) },
            activeProjectIndex: activeProjectIndex
        )
        do {
            let configDir = Self.persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: configDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: Self.persistenceURL, options: .atomic)
        } catch {
            print("[ProjectManager] Failed to save state: \(error)")
        }
    }

    static func restore() -> ProjectManager? {
        guard let data = try? Data(contentsOf: persistenceURL) else { return nil }
        guard let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return nil
        }

        let manager = ProjectManager()
        for codable in state.projects {
            let project = codable.toProject()
            manager.observe(project)
            manager.projects.append(project)
        }
        // Clamp index; -1 is valid (no active project)
        if state.projects.isEmpty {
            manager.activeProjectIndex = -1
        } else {
            manager.activeProjectIndex = max(
                -1, min(state.activeProjectIndex, manager.projects.count - 1))
        }
        return manager
    }

    // MARK: - Observe

    private func observe(_ project: Project) {
        project.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Create

    @discardableResult
    func addProject(rootPath: String, name: String? = nil) -> Project {
        let project = Project(name: name, rootPath: rootPath)
        observe(project)
        projects.append(project)
        activeProjectIndex = projects.count - 1
        save()
        return project
    }

    // MARK: - Delete

    func deleteProject(at index: Int) {
        guard index >= 0, index < projects.count else { return }
        projects.remove(at: index)

        if projects.isEmpty {
            activeProjectIndex = -1
        } else if activeProjectIndex >= projects.count {
            activeProjectIndex = projects.count - 1
        } else if activeProjectIndex > index {
            activeProjectIndex -= 1
        }
        // If activeProjectIndex == index and still valid, we now point at the
        // project that slid into the slot — that's fine.
        save()
    }

    func deleteProject(id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        deleteProject(at: index)
    }

    // MARK: - Switch / Select

    func selectProject(at index: Int) {
        guard index >= -1, index < projects.count else { return }
        activeProjectIndex = index
        save()
    }

    func selectProject(id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        selectProject(at: index)
    }

    /// Deselect any active project (go back to un-scoped mode).
    func clearActiveProject() {
        activeProjectIndex = -1
        save()
    }

    // MARK: - Rename

    func renameProject(id: UUID, name: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        project.name = name
        save()
    }

    // MARK: - Reorder

    func moveProject(from source: Int, to destination: Int) {
        guard source >= 0, source < projects.count,
            destination >= 0, destination < projects.count,
            source != destination
        else { return }

        let movingProject = projects[source]
        let wasActive = (activeProjectIndex == source)

        projects.remove(at: source)
        projects.insert(movingProject, at: destination)

        if wasActive {
            activeProjectIndex = destination
        } else if let newIdx = projects.firstIndex(where: { $0.id == activeProject?.id }) {
            activeProjectIndex = newIdx
        }
        save()
    }

    // MARK: - Helpers

    /// Returns true if a project with the given root path already exists.
    func hasProject(withRootPath path: String) -> Bool {
        projects.contains { $0.rootPath == path }
    }
}
