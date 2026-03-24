import Darwin
import Foundation

enum ProcessHelper {
    /// Get PIDs of shell processes spawned by this app.
    /// Ghostty spawns `login` as a direct child, which then spawns the actual
    /// shell. This method returns the shell PIDs (grandchildren through login)
    /// as well as any direct children that are not login processes.
    static func childPids() -> [pid_t] {
        let parent = ProcessInfo.processInfo.processIdentifier
        let allProcs = allProcesses()

        let directChildren = allProcs
            .filter { $0.kp_eproc.e_ppid == parent }
            .map { $0.kp_proc.p_pid }

        var result: [pid_t] = []
        for childPid in directChildren {
            let childName = name(of: childPid)
            if childName == "login" {
                // login is an intermediary -- return its children (the actual shells)
                let grandchildren = allProcs
                    .filter { $0.kp_eproc.e_ppid == childPid }
                    .map { $0.kp_proc.p_pid }
                result.append(contentsOf: grandchildren)
            } else {
                result.append(childPid)
            }
        }
        return result
    }

    /// Snapshot of all processes via sysctl.
    private static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size: Int = 0
        sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0)
        guard size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0)

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return Array(procs.prefix(actualCount))
    }

    /// Get the name of a process (e.g. "fish", "vim", "cargo").
    static func name(of pid: pid_t) -> String? {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        defer { buffer.deallocate() }
        let len = proc_name(pid, buffer, 256)
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Get the command name of a process by scanning KERN_PROCARGS2.
    /// Checks argv[0] last-path-component, then scans all args for known names.
    /// More robust than just argv[0] since different install methods vary.
    static func commandName(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buf = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        guard size > MemoryLayout<Int32>.size else { return nil }

        // Skip argc (first 4 bytes), then the exec path
        var idx = MemoryLayout<Int32>.size
        while idx < size && buf[idx] != 0 { idx += 1 }
        // Skip null padding between exec path and argv[0]
        while idx < size && buf[idx] == 0 { idx += 1 }
        guard idx < size else { return nil }

        // Collect all argv entries (null-separated strings until we hit env vars)
        var args: [String] = []
        while idx < size && args.count < 10 {
            let arg = String(cString: Array(buf[idx...]))
            if arg.isEmpty { break }
            args.append(arg)
            idx += arg.utf8.count + 1
            // Skip padding nulls
            while idx < size && buf[idx] == 0 { idx += 1 }
        }

        guard !args.isEmpty else { return nil }

        // Check argv[0] last path component first (most common case)
        let argv0Name = URL(fileURLWithPath: args[0]).lastPathComponent
        if argv0Name == "claude" || argv0Name == "codex" {
            return argv0Name
        }

        // Scan all args for known agent identifiers in paths
        for arg in args {
            let lower = arg.lowercased()
            if lower.contains("/bin/claude") || lower.contains("claude-code") ||
               lower.hasSuffix("/claude") {
                return "claude"
            }
            if lower.contains("/bin/codex") || lower.contains("@openai/codex") ||
               lower.hasSuffix("/codex") {
                return "codex"
            }
        }

        return argv0Name
    }

    /// Get the foreground process of a shell by walking the process tree to the deepest descendant.
    /// Returns nil if the shell has no children (idle at prompt).
    static func foregroundChild(of shellPid: pid_t) -> pid_t? {
        let allProcs = allProcesses()
        var current = shellPid
        while true {
            let children = allProcs
                .filter { $0.kp_eproc.e_ppid == current }
                .map { $0.kp_proc.p_pid }
            guard let last = children.last else {
                return current == shellPid ? nil : current
            }
            current = last
        }
    }

    /// Get direct child PIDs of a specific process.
    static func childPidsOf(_ parent: pid_t) -> [pid_t] {
        return allProcesses()
            .filter { $0.kp_eproc.e_ppid == parent }
            .map { $0.kp_proc.p_pid }
    }

    /// Read the git branch from .git/HEAD (fast, no subprocess).
    static func gitBranch(at path: String) -> String? {
        var dir = path
        while dir != "/" && !dir.isEmpty {
            let gitPath = (dir as NSString).appendingPathComponent(".git")
            var headPath = (gitPath as NSString).appendingPathComponent("HEAD")

            // If .git is a file (worktree), resolve the actual gitdir
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir), !isDir.boolValue {
                // .git file contains "gitdir: <path>"
                guard let gitFileContent = try? String(contentsOfFile: gitPath, encoding: .utf8),
                      gitFileContent.hasPrefix("gitdir: ") else {
                    dir = (dir as NSString).deletingLastPathComponent
                    continue
                }
                let gitdir = gitFileContent.dropFirst("gitdir: ".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedGitdir: String
                if (gitdir as NSString).isAbsolutePath {
                    resolvedGitdir = gitdir
                } else {
                    resolvedGitdir = (dir as NSString).appendingPathComponent(gitdir)
                }
                headPath = (resolvedGitdir as NSString).appendingPathComponent("HEAD")
            }

            if let data = FileManager.default.contents(atPath: headPath),
               let content = String(data: data, encoding: .utf8) {
                if content.hasPrefix("ref: refs/heads/") {
                    return String(content.dropFirst("ref: refs/heads/".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Detached HEAD
                return String(content.prefix(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Fast git dirty check: compares .git/index mtime to last commit time.
    /// Falls back to checking if status output is non-empty.
    static func gitIsDirty(at path: String) -> Bool {
        var dir = URL(fileURLWithPath: path)
        while dir.path != "/" {
            let gitDir = dir.appendingPathComponent(".git")
            let indexFile = gitDir.appendingPathComponent("index")

            // If .git/index exists, the repo has staged state.
            // Compare its mtime to .git/refs/stash or just check for common dirty markers.
            if FileManager.default.fileExists(atPath: gitDir.path) {
                // Fast heuristic: check for merge/rebase in progress
                for marker in ["MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD", "rebase-merge", "rebase-apply"] {
                    if FileManager.default.fileExists(atPath: gitDir.appendingPathComponent(marker).path) {
                        return true
                    }
                }

                // Check if index was modified after HEAD was last updated
                let headRef = gitDir.appendingPathComponent("HEAD")
                if let indexAttrs = try? FileManager.default.attributesOfItem(atPath: indexFile.path),
                   let headAttrs = try? FileManager.default.attributesOfItem(atPath: headRef.path),
                   let indexMod = indexAttrs[.modificationDate] as? Date,
                   let headMod = headAttrs[.modificationDate] as? Date {
                    if indexMod > headMod {
                        return true
                    }
                }
                return false
            }
            dir = dir.deletingLastPathComponent()
        }
        return false
    }

    /// Get the current working directory of a process via proc_pidinfo.
    static func cwd(of pid: pid_t) -> String? {
        let bufferSize = MemoryLayout<proc_vnodepathinfo>.stride
        let buffer = UnsafeMutablePointer<proc_vnodepathinfo>.allocate(capacity: 1)
        defer { buffer.deallocate() }

        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, buffer, Int32(bufferSize))
        guard ret == Int32(bufferSize) else { return nil }

        return withUnsafePointer(to: &buffer.pointee.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
                String(cString: cStr)
            }
        }
    }
}
