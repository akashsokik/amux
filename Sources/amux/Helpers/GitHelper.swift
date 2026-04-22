import Foundation

enum GitHelper {
    struct GitError: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { self.description = message }
    }

    static let commandDidFinishNotification = Notification.Name("GitCommandDidFinish")

    /// Run a git command synchronously and return stdout. Returns nil if command fails.
    static func run(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Get the git repository root for a given directory.
    static func repoRoot(from cwd: String) -> String? {
        return run(["rev-parse", "--show-toplevel"], in: cwd)
    }

    // MARK: - Worktrees

    struct WorktreeInfo {
        let path: String
        let branch: String?
        let isMain: Bool
        let isCurrent: Bool
    }

    static func listWorktrees(from cwd: String) -> [WorktreeInfo] {
        guard let output = run(["worktree", "list", "--porcelain"], in: cwd) else { return [] }
        let currentRoot = repoRoot(from: cwd)

        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        var isBare = false

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                if let path = currentPath {
                    worktrees.append(WorktreeInfo(
                        path: path,
                        branch: currentBranch,
                        isMain: isBare || worktrees.isEmpty,
                        isCurrent: path == currentRoot
                    ))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
                isBare = false
            } else if line.hasPrefix("branch refs/heads/") {
                currentBranch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "bare" {
                isBare = true
            } else if line.hasPrefix("detached") {
                currentBranch = nil
            }
        }
        if let path = currentPath {
            worktrees.append(WorktreeInfo(
                path: path,
                branch: currentBranch,
                isMain: isBare || worktrees.isEmpty,
                isCurrent: path == currentRoot
            ))
        }

        return worktrees
    }

    static func addWorktree(from cwd: String, branch: String) -> Result<String, GitError> {
        guard let root = repoRoot(from: cwd) else {
            return .failure(GitError("Not a git repository"))
        }
        let repoName = URL(fileURLWithPath: root).lastPathComponent
        let parentDir = URL(fileURLWithPath: root).deletingLastPathComponent().path
        let worktreePath = "\(parentDir)/\(repoName)-\(branch)"

        if let _ = run(["worktree", "add", worktreePath, "-b", branch], in: root) {
            return .success(worktreePath)
        }
        if let _ = run(["worktree", "add", worktreePath, branch], in: root) {
            return .success(worktreePath)
        }
        return .failure(GitError("Failed to create worktree"))
    }

    static func removeWorktree(from cwd: String, path: String) -> Result<Void, GitError> {
        if let _ = run(["worktree", "remove", path], in: cwd) {
            return .success(())
        }
        return .failure(GitError("Failed to remove worktree"))
    }

    // MARK: - Git Status

    struct StatusInfo {
        let branch: String
        let trackingBranch: String?
        let ahead: Int
        let behind: Int
        let files: [FileStatus]
    }

    struct FileStatus {
        enum Kind: String {
            case staged, modified, untracked, deleted, renamed
        }
        let path: String
        let kind: Kind
        let linesAdded: Int
        let linesRemoved: Int
    }

    static func status(from cwd: String) -> StatusInfo? {
        guard let statusOutput = run(["status", "--porcelain=v2", "--branch"], in: cwd) else { return nil }

        var branch = "HEAD"
        var trackingBranch: String?
        var ahead = 0
        var behind = 0
        var files: [FileStatus] = []

        for line in statusOutput.components(separatedBy: "\n") {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                trackingBranch = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).components(separatedBy: " ")
                if parts.count >= 2 {
                    ahead = abs(Int(parts[0]) ?? 0)
                    behind = abs(Int(parts[1]) ?? 0)
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 9 else { continue }
                let xy = parts[1]
                let indexChar = xy.first ?? "."
                let workChar = xy.count > 1 ? xy[xy.index(after: xy.startIndex)] : Character(".")
                let path = parts.dropFirst(8).joined(separator: " ").components(separatedBy: "\t").first ?? ""

                if indexChar != "." && indexChar != "?" {
                    let kind: FileStatus.Kind = indexChar == "D" ? .deleted : (indexChar == "R" ? .renamed : .staged)
                    files.append(FileStatus(path: path, kind: kind, linesAdded: 0, linesRemoved: 0))
                }
                if workChar != "." && workChar != "?" {
                    let kind: FileStatus.Kind = workChar == "D" ? .deleted : .modified
                    if !files.contains(where: { $0.path == path && $0.kind == kind }) {
                        files.append(FileStatus(path: path, kind: kind, linesAdded: 0, linesRemoved: 0))
                    }
                }
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst("? ".count))
                files.append(FileStatus(path: path, kind: .untracked, linesAdded: 0, linesRemoved: 0))
            }
        }

        let stagedStats = parseDiffNumstat(run(["diff", "--cached", "--numstat"], in: cwd))
        let unstagedStats = parseDiffNumstat(run(["diff", "--numstat"], in: cwd))

        for i in files.indices {
            let path = files[i].path
            if files[i].kind == .staged || files[i].kind == .renamed {
                if let stat = stagedStats[path] {
                    files[i] = FileStatus(path: path, kind: files[i].kind, linesAdded: stat.0, linesRemoved: stat.1)
                }
            } else if files[i].kind == .modified {
                if let stat = unstagedStats[path] {
                    files[i] = FileStatus(path: path, kind: files[i].kind, linesAdded: stat.0, linesRemoved: stat.1)
                }
            }
        }

        return StatusInfo(branch: branch, trackingBranch: trackingBranch, ahead: ahead, behind: behind, files: files)
    }

    private static func parseDiffNumstat(_ output: String?) -> [String: (Int, Int)] {
        guard let output = output else { return [:] }
        var result: [String: (Int, Int)] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let added = Int(parts[0]) ?? 0
            let removed = Int(parts[1]) ?? 0
            result[parts[2]] = (added, removed)
        }
        return result
    }

    // MARK: - Detailed command runner (returns stdout + stderr + exit)

    struct CommandResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var succeeded: Bool { exitCode == 0 }
    }

    /// Run any git command and capture stdout/stderr plus the exit code.
    static func runDetailed(_ args: [String], in directory: String) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(stdout: "", stderr: "\(error)", exitCode: -1)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Broadcast that a write operation finished so any open views can refresh.
    private static func broadcastFinish() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: commandDidFinishNotification, object: nil)
        }
    }

    // MARK: - Branches

    struct BranchInfo {
        let name: String
        let isCurrent: Bool
        let isRemote: Bool
        let upstream: String?
    }

    static func listBranches(from cwd: String) -> [BranchInfo] {
        var result: [BranchInfo] = []

        // Local branches
        let localFormat = "%(refname:short)\t%(HEAD)\t%(upstream:short)"
        if let out = run(["for-each-ref", "--format=\(localFormat)", "refs/heads"], in: cwd) {
            for line in out.components(separatedBy: "\n") where !line.isEmpty {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2 else { continue }
                let name = parts[0]
                let isCurrent = parts[1] == "*"
                let upstream = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
                result.append(BranchInfo(name: name, isCurrent: isCurrent, isRemote: false, upstream: upstream))
            }
        }

        // Remote branches (skip HEAD aliases)
        if let out = run(["for-each-ref", "--format=%(refname:short)", "refs/remotes"], in: cwd) {
            for line in out.components(separatedBy: "\n") where !line.isEmpty {
                if line.hasSuffix("/HEAD") { continue }
                result.append(BranchInfo(name: line, isCurrent: false, isRemote: true, upstream: nil))
            }
        }

        return result
    }

    static func checkoutBranch(from cwd: String, branch: String) -> Result<Void, GitError> {
        let res = runDetailed(["checkout", branch], in: cwd)
        broadcastFinish()
        if res.succeeded { return .success(()) }
        return .failure(GitError(res.stderr.isEmpty ? "Checkout failed" : res.stderr))
    }

    static func createBranch(from cwd: String, name: String, checkout: Bool) -> Result<Void, GitError> {
        let args: [String] = checkout ? ["checkout", "-b", name] : ["branch", name]
        let res = runDetailed(args, in: cwd)
        broadcastFinish()
        if res.succeeded { return .success(()) }
        return .failure(GitError(res.stderr.isEmpty ? "Branch create failed" : res.stderr))
    }

    // MARK: - Staging

    static func stage(from cwd: String, paths: [String]) -> Result<Void, GitError> {
        guard !paths.isEmpty else { return .success(()) }
        let res = runDetailed(["add", "--"] + paths, in: cwd)
        broadcastFinish()
        if res.succeeded { return .success(()) }
        return .failure(GitError(res.stderr.isEmpty ? "Stage failed" : res.stderr))
    }

    static func stageAll(from cwd: String) -> Result<Void, GitError> {
        let res = runDetailed(["add", "-A"], in: cwd)
        broadcastFinish()
        if res.succeeded { return .success(()) }
        return .failure(GitError(res.stderr.isEmpty ? "Stage all failed" : res.stderr))
    }

    static func unstage(from cwd: String, paths: [String]) -> Result<Void, GitError> {
        guard !paths.isEmpty else { return .success(()) }
        let res = runDetailed(["restore", "--staged", "--"] + paths, in: cwd)
        broadcastFinish()
        if res.succeeded { return .success(()) }
        return .failure(GitError(res.stderr.isEmpty ? "Unstage failed" : res.stderr))
    }

    /// Discard working-tree changes. For untracked files this removes them from disk.
    static func discard(from cwd: String, paths: [String], includeUntracked: Bool) -> Result<Void, GitError> {
        guard !paths.isEmpty else { return .success(()) }
        let restore = runDetailed(["checkout", "--"] + paths, in: cwd)
        if !restore.succeeded && !includeUntracked {
            broadcastFinish()
            return .failure(GitError(restore.stderr.isEmpty ? "Discard failed" : restore.stderr))
        }
        if includeUntracked {
            _ = runDetailed(["clean", "-f", "--"] + paths, in: cwd)
        }
        broadcastFinish()
        return .success(())
    }

    // MARK: - Commit / sync

    static func commit(from cwd: String, message: String) -> Result<Void, GitError> {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(GitError("Commit message is empty")) }
        let res = runDetailed(["commit", "-m", trimmed], in: cwd)
        broadcastFinish()
        if res.succeeded { return .success(()) }
        let msg = res.stderr.isEmpty ? res.stdout : res.stderr
        return .failure(GitError(msg.isEmpty ? "Commit failed" : msg))
    }

    static func pull(from cwd: String) -> Result<String, GitError> {
        let res = runDetailed(["pull", "--ff-only"], in: cwd)
        broadcastFinish()
        if res.succeeded { return .success(res.stdout) }
        return .failure(GitError(res.stderr.isEmpty ? "Pull failed" : res.stderr))
    }

    static func push(from cwd: String) -> Result<String, GitError> {
        let res = runDetailed(["push"], in: cwd)
        broadcastFinish()
        if res.succeeded { return .success(res.stdout.isEmpty ? res.stderr : res.stdout) }
        return .failure(GitError(res.stderr.isEmpty ? "Push failed" : res.stderr))
    }

    static func pushSetUpstream(from cwd: String, branch: String) -> Result<String, GitError> {
        let res = runDetailed(["push", "-u", "origin", branch], in: cwd)
        broadcastFinish()
        if res.succeeded { return .success(res.stdout.isEmpty ? res.stderr : res.stdout) }
        return .failure(GitError(res.stderr.isEmpty ? "Push failed" : res.stderr))
    }

    // MARK: - History

    struct CommitInfo {
        let hash: String
        let shortHash: String
        let subject: String
        let authorName: String
        let relativeDate: String
        let refs: [String]
    }

    static func log(from cwd: String, limit: Int = 100) -> [CommitInfo] {
        // Separator sequences chosen to be extremely unlikely to appear in commit data.
        let fieldSep = "\u{1F}"
        let recordSep = "\u{1E}"
        let format = ["%H", "%h", "%s", "%an", "%ar", "%D"].joined(separator: fieldSep) + recordSep

        guard let out = run(
            ["log", "--all", "-n", "\(limit)", "--pretty=format:\(format)"],
            in: cwd
        ) else { return [] }

        var commits: [CommitInfo] = []
        for record in out.components(separatedBy: recordSep) {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fields = trimmed.components(separatedBy: fieldSep)
            guard fields.count >= 6 else { continue }
            let refs = fields[5]
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            commits.append(CommitInfo(
                hash: fields[0],
                shortHash: fields[1],
                subject: fields[2],
                authorName: fields[3],
                relativeDate: fields[4],
                refs: refs
            ))
        }
        return commits
    }

    // MARK: - Pull request (via gh CLI)

    /// Open a PR creation flow in the browser using `gh pr create --web`.
    /// Returns .failure if gh is not installed or the command fails.
    static func openPullRequestInBrowser(from cwd: String) -> Result<Void, GitError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "pr", "create", "--web"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .failure(GitError("Unable to launch gh: \(error)"))
        }

        process.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 { return .success(()) }
        if err.contains("command not found") || err.contains("No such file") {
            return .failure(GitError("The GitHub CLI ('gh') is not installed. Install it from https://cli.github.com"))
        }
        return .failure(GitError(err.isEmpty ? "gh pr create failed" : err))
    }
}
