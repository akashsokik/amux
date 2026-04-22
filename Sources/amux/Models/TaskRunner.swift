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
    let startedAt: Date
    let buffer: LogRingBuffer
    fileprivate(set) var status: TaskStatus = .running
    fileprivate(set) var pid: pid_t?
    fileprivate let process: Process

    init(taskId: String, worktreePath: String, buffer: LogRingBuffer, process: Process) {
        self.taskId = taskId
        self.worktreePath = worktreePath
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

    private var sessions: [TaskSessionKey: TaskRunSession] = [:]
    private let queue = DispatchQueue(label: "amux.TaskRunner")

    func session(for id: String, worktreePath: String) -> TaskRunSession? {
        let key = TaskSessionKey(worktreePath: worktreePath, taskId: id)
        return queue.sync { sessions[key] }
    }

    func start(_ task: RunnerTask, worktreePath: String) {
        let key = TaskSessionKey(worktreePath: worktreePath, taskId: task.id)
        queue.sync {
            if let existing = sessions[key], existing.status == .running {
                _stopLocked(key: key)
            }
            guard let session = _spawnLocked(task: task, worktreePath: worktreePath) else { return }
            sessions[key] = session
        }
        postUpdate(taskId: task.id, worktreePath: worktreePath)
    }

    func restart(_ task: RunnerTask, worktreePath: String) {
        stop(id: task.id, worktreePath: worktreePath)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            self?.start(task, worktreePath: worktreePath)
        }
    }

    func stop(id: String, worktreePath: String) {
        let key = TaskSessionKey(worktreePath: worktreePath, taskId: id)
        queue.sync { _stopLocked(key: key) }
        postUpdate(taskId: id, worktreePath: worktreePath)
    }

    private func _stopLocked(key: TaskSessionKey) {
        guard let session = sessions[key], session.status == .running,
              session.pid != nil else { return }
        // Fallback path: Process.startsNewProcessGroupWhenSet isn't available in this
        // Swift toolchain, so the child shares our process group. Send SIGTERM via
        // Process.terminate() then escalate to SIGKILL on the child's pid.
        // Known limitation: grandchildren (e.g. a script spawned by /bin/sh) may leak.
        session.process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            self.queue.sync {
                if let s = self.sessions[key], s.status == .running, let p = s.pid {
                    kill(p, SIGKILL)
                }
            }
        }
    }

    private func _spawnLocked(task: RunnerTask, worktreePath: String) -> TaskRunSession? {
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
        // escalation in _stopLocked. Grandchildren may leak; acceptable for v1.

        let buffer = LogRingBuffer()
        let session = TaskRunSession(
            taskId: task.id, worktreePath: worktreePath,
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
                    userInfo: ["taskId": capturedTaskId, "worktreePath": capturedWorktreePath]
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
                    userInfo: ["taskId": capturedTaskId, "worktreePath": capturedWorktreePath]
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
                NotificationCenter.default.post(
                    name: TaskRunner.didUpdateNotification, object: nil,
                    userInfo: [
                        "taskId": capturedSession.taskId,
                        "worktreePath": capturedSession.worktreePath,
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
            buffer.append("failed to start: \(error.localizedDescription)\n")
            return session
        }
    }

    private func postUpdate(taskId: String, worktreePath: String) {
        NotificationCenter.default.post(
            name: Self.didUpdateNotification, object: nil,
            userInfo: ["taskId": taskId, "worktreePath": worktreePath]
        )
    }
}
