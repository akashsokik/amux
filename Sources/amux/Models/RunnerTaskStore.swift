import Foundation

/// Publishes the merged list of detected + pinned tasks for a single worktree.
/// Not thread-safe: use from the main thread.
final class RunnerTaskStore {
    let worktreePath: String
    private(set) var tasks: [RunnerTask] = []
    private(set) var loadError: String?

    /// Notified whenever `tasks` changes.
    static let didChangeNotification = Notification.Name("RunnerTaskStoreDidChange")

    init(worktreePath: String) {
        self.worktreePath = worktreePath
    }

    /// Re-scan disk and rebuild `tasks`. Idempotent.
    func reload() {
        let detected = TaskAutoDetect.all(at: worktreePath)
        let (pinned, error) = loadPinned()
        self.loadError = error

        let pinnedIDs = Set(pinned.map(\.id))
        var merged: [RunnerTask] = []
        merged.append(contentsOf: pinned.map { p in
            RunnerTask(
                id: p.id,
                name: p.name,
                command: p.command,
                cwd: p.cwd,
                source: .pinned,
                isOverridden: detected.contains { $0.id == p.id }
            )
        })
        for d in detected where !pinnedIDs.contains(d.id) {
            merged.append(d)
        }
        self.tasks = merged
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private var pinnedFileURL: URL {
        URL(fileURLWithPath: worktreePath)
            .appendingPathComponent(".amux")
            .appendingPathComponent("tasks.json")
    }

    private func loadPinned() -> ([PinnedTask], String?) {
        guard let data = try? Data(contentsOf: pinnedFileURL) else { return ([], nil) }
        do {
            let file = try JSONDecoder().decode(PinnedTasksFile.self, from: data)
            return (file.tasks, nil)
        } catch {
            return ([], "Failed to read .amux/tasks.json: \(error.localizedDescription)")
        }
    }

    /// Add (or update) a pinned task and persist.
    func addPinned(_ task: PinnedTask) throws {
        let (current, _) = loadPinned()
        var next = current.filter { $0.id != task.id }
        next.append(task)
        let file = PinnedTasksFile(version: 1, tasks: next)
        try writePinned(file)
        reload()
    }

    /// Remove a pinned task by id and persist.
    func removePinned(id: String) throws {
        let (current, _) = loadPinned()
        let next = current.filter { $0.id != id }
        if next.count == current.count { return }
        try writePinned(PinnedTasksFile(version: 1, tasks: next))
        reload()
    }

    private func writePinned(_ file: PinnedTasksFile) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: pinnedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: pinnedFileURL, options: .atomic)
    }
}
