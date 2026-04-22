import Foundation
import Darwin

/// Publishes the merged list of detected + pinned tasks for a single worktree.
/// Not thread-safe: use from the main thread.
final class RunnerTaskStore {
    let worktreePath: String
    private(set) var tasks: [RunnerTask] = []
    private(set) var loadError: String?

    /// Notified whenever `tasks` changes.
    static let didChangeNotification = Notification.Name("RunnerTaskStoreDidChange")

    // File-system watchers: we watch both `.amux/` (so create/delete/rename of
    // tasks.json reaches us) and `.amux/tasks.json` itself (for writes/extends).
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileFD: Int32 = -1
    private var dirFD: Int32 = -1

    init(worktreePath: String) {
        self.worktreePath = worktreePath
        startWatching()
    }

    deinit { stopWatching() }

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

    // MARK: - File watching

    /// Start (or restart) watching the `.amux/` directory and `tasks.json`
    /// file for external edits. Safe to call more than once.
    func startWatching() {
        stopWatching()

        // Watch the `.amux` directory so create/delete/rename of tasks.json
        // reaches us even when the file doesn't exist yet.
        let amuxDir = pinnedFileURL.deletingLastPathComponent().path
        var isDir: ObjCBool = false
        let dirExists = FileManager.default.fileExists(atPath: amuxDir, isDirectory: &isDir) && isDir.boolValue
        if dirExists {
            let fd = open(amuxDir, O_EVTONLY)
            if fd >= 0 {
                dirFD = fd
                let src = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .delete, .rename],
                    queue: .main
                )
                src.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.reload()
                    self.rearmFileWatch()
                }
                // Capture the fd locally so the cancel handler always closes
                // THIS source's fd, even after `self.dirFD` is reassigned by
                // a later startWatching/rearm cycle.
                let capturedFD = fd
                src.setCancelHandler {
                    Darwin.close(capturedFD)
                }
                dirSource = src
                src.resume()
            }
        }

        rearmFileWatch()
    }

    /// Stop watching. Called from deinit and before a restart.
    /// Cancelling the sources asynchronously runs their cancel handlers,
    /// which close the fds that were captured at source-creation time.
    func stopWatching() {
        fileSource?.cancel(); fileSource = nil
        dirSource?.cancel();  dirSource = nil
        fileFD = -1
        dirFD = -1
    }

    /// (Re-)open a watcher on `tasks.json`. We re-arm after any rename/delete
    /// because the original FD becomes useless once the inode is replaced
    /// (e.g. via atomic write).
    private func rearmFileWatch() {
        // Cancel the previous source; its cancel handler will asynchronously
        // close the old fd it captured at creation time. Don't close
        // `self.fileFD` here — that would be a double-close once the cancel
        // handler runs.
        fileSource?.cancel()
        fileSource = nil
        fileFD = -1
        let fd = open(pinnedFileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.reload()
            self.rearmFileWatch()
        }
        // Capture the fd locally so the cancel handler always closes THIS
        // source's fd, even after `self.fileFD` is reassigned by a later
        // rearm cycle.
        let capturedFD = fd
        src.setCancelHandler {
            Darwin.close(capturedFD)
        }
        fileSource = src
        src.resume()
    }
}
