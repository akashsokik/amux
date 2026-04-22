import Foundation

enum TaskStatus: Equatable {
    case running
    case exited(Int32)
    case terminated
    case failedToStart(String)
}

final class TaskRunSession {
    let taskId: String
    let worktreePath: String
    let runNumber: Int
    let startedAt: Date
    let buffer: LogRingBuffer
    fileprivate(set) var status: TaskStatus = .running
    fileprivate(set) var pid: pid_t?
    fileprivate(set) var endedAt: Date?
    fileprivate let process: Process

    init(taskId: String, worktreePath: String, runNumber: Int,
         buffer: LogRingBuffer, process: Process) {
        self.taskId = taskId
        self.worktreePath = worktreePath
        self.runNumber = runNumber
        self.startedAt = Date()
        self.buffer = buffer
        self.process = process
    }
}

/// Composite key scoping a task session to a specific worktree. Auto-detected
/// task ids like "npm:dev" are NOT unique across worktrees, so keying sessions
/// on taskId alone caused worktree A's running task to appear running in
/// worktree B. The worktreePath disambiguates.
struct TaskSessionKey: Hashable {
    let worktreePath: String
    let taskId: String
}

final class TaskRunner {
    static let didUpdateNotification = Notification.Name("TaskRunnerDidUpdate")

    /// Ordered history of runs per task, oldest first. Only the last run can
    /// ever be running — `start` stops the previous active run (if any)
    /// before appending, keeping the terminated history alongside.
    private var runs: [TaskSessionKey: [TaskRunSession]] = [:]
    private var nextRunNumber: [TaskSessionKey: Int] = [:]
    private let queue = DispatchQueue(label: "amux.TaskRunner")

    /// Cap history so a chatty restart loop doesn't accumulate forever.
    private let maxRunsPerTask = 8

    /// Latest run for the task (nil if none yet). Back-compat with earlier
    /// single-session API.
    func session(for id: String, worktreePath: String) -> TaskRunSession? {
        let key = TaskSessionKey(worktreePath: worktreePath, taskId: id)
        return queue.sync { runs[key]?.last }
    }

    /// All runs for the task, oldest first.
    func runs(for id: String, worktreePath: String) -> [TaskRunSession] {
        let key = TaskSessionKey(worktreePath: worktreePath, taskId: id)
        return queue.sync { runs[key] ?? [] }
    }

    /// Specific run by its per-task run number.
    func run(for id: String, worktreePath: String, runNumber: Int) -> TaskRunSession? {
        let key = TaskSessionKey(worktreePath: worktreePath, taskId: id)
        return queue.sync { runs[key]?.first(where: { $0.runNumber == runNumber }) }
    }

    func start(_ task: RunnerTask, worktreePath: String) {
        let key = TaskSessionKey(worktreePath: worktreePath, taskId: task.id)
        var newRunNumber: Int = 0
        queue.sync {
            // Stop the latest run if it's still running. Keep it in history —
            // its termination handler flips status to .terminated.
            if let existing = runs[key]?.last, existing.status == .running {
                _stopSessionLocked(existing)
            }
            let n = (nextRunNumber[key] ?? 0) + 1
            nextRunNumber[key] = n
            newRunNumber = n
            guard let session = _spawnLocked(task: task, worktreePath: worktreePath, runNumber: n) else { return }
            var list = runs[key] ?? []
            list.append(session)
            // Drop oldest so memory stays bounded. Only terminated runs are
            // dropped — the running one is always at the tail.
            if list.count > maxRunsPerTask {
                list.removeFirst(list.count - maxRunsPerTask)
            }
            runs[key] = list
        }
        postUpdate(taskId: task.id, worktreePath: worktreePath, runNumber: newRunNumber)
    }

    func restart(_ task: RunnerTask, worktreePath: String) {
        stop(id: task.id, worktreePath: worktreePath)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            self?.start(task, worktreePath: worktreePath)
        }
    }

    func stop(id: String, worktreePath: String) {
        let key = TaskSessionKey(worktreePath: worktreePath, taskId: id)
        var runNumber: Int?
        queue.sync {
            if let latest = runs[key]?.last, latest.status == .running {
                _stopSessionLocked(latest)
                runNumber = latest.runNumber
            }
        }
        postUpdate(taskId: id, worktreePath: worktreePath, runNumber: runNumber)
    }

    private func _stopSessionLocked(_ session: TaskRunSession) {
        guard session.status == .running, session.pid != nil else { return }
        // Fallback path: Process.startsNewProcessGroupWhenSet isn't available in this
        // Swift toolchain, so the child shares our process group. Send SIGTERM via
        // Process.terminate() then escalate to SIGKILL on the child's pid.
        // Known limitation: grandchildren (e.g. a script spawned by /bin/sh) may leak.
        session.process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self, weak session] in
            guard let self, let session else { return }
            self.queue.sync {
                if session.status == .running, let p = session.pid {
                    kill(p, SIGKILL)
                }
            }
        }
    }

    private func _spawnLocked(task: RunnerTask, worktreePath: String, runNumber: Int) -> TaskRunSession? {
        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-lc", task.command]

        let cwd: String = {
            if let raw = task.cwd {
                return (raw as NSString).isAbsolutePath
                    ? raw
                    : (worktreePath as NSString).appendingPathComponent(raw)
            }
            return worktreePath
        }()
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Note: swift-corelibs-foundation's Process on macOS doesn't expose a way to
        // setpgid on the child. We rely on Process.terminate() + kill(pid, SIGKILL)
        // escalation in _stopSessionLocked. Grandchildren may leak; acceptable for v1.

        let buffer = LogRingBuffer()
        let session = TaskRunSession(
            taskId: task.id, worktreePath: worktreePath, runNumber: runNumber,
            buffer: buffer, process: process
        )

        let capturedTaskId = task.id
        let capturedWorktreePath = worktreePath

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                buffer.append(ANSIStripper.strip(s))
                NotificationCenter.default.post(
                    name: TaskRunner.didUpdateNotification, object: nil,
                    userInfo: [
                        "taskId": capturedTaskId,
                        "worktreePath": capturedWorktreePath,
                        "runNumber": runNumber,
                    ]
                )
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                buffer.append(ANSIStripper.strip(s))
                NotificationCenter.default.post(
                    name: TaskRunner.didUpdateNotification, object: nil,
                    userInfo: [
                        "taskId": capturedTaskId,
                        "worktreePath": capturedWorktreePath,
                        "runNumber": runNumber,
                    ]
                )
            }
        }

        let capturedSession = session
        process.terminationHandler = { [weak self] p in
            self?.queue.async {
                switch p.terminationReason {
                case .exit:        capturedSession.status = .exited(p.terminationStatus)
                case .uncaughtSignal: capturedSession.status = .terminated
                @unknown default:  capturedSession.status = .terminated
                }
                capturedSession.endedAt = Date()
                NotificationCenter.default.post(
                    name: TaskRunner.didUpdateNotification, object: nil,
                    userInfo: [
                        "taskId": capturedSession.taskId,
                        "worktreePath": capturedSession.worktreePath,
                        "runNumber": capturedSession.runNumber,
                    ]
                )
            }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try process.run()
            session.pid = process.processIdentifier
            return session
        } catch {
            session.status = .failedToStart(error.localizedDescription)
            session.endedAt = Date()
            buffer.append("failed to start: \(error.localizedDescription)\n")
            return session
        }
    }

    private func postUpdate(taskId: String, worktreePath: String, runNumber: Int?) {
        var info: [String: Any] = [
            "taskId": taskId,
            "worktreePath": worktreePath,
        ]
        if let runNumber { info["runNumber"] = runNumber }
        NotificationCenter.default.post(
            name: Self.didUpdateNotification, object: nil, userInfo: info
        )
    }
}
