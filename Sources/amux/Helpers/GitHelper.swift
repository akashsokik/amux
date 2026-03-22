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
}
