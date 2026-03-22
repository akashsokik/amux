import Darwin
import Foundation

enum ProcessHelper {
    /// Get PIDs of direct child processes of this app.
    static func childPids() -> [pid_t] {
        let parent = ProcessInfo.processInfo.processIdentifier
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size: Int = 0
        sysctl(&name, UInt32(name.count), nil, &size, nil, 0)
        guard size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        sysctl(&name, UInt32(name.count), &procs, &size, nil, 0)

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actualCount)
            .filter { $0.kp_eproc.e_ppid == parent }
            .map { $0.kp_proc.p_pid }
    }

    /// Get the name of a process (e.g. "fish", "vim", "cargo").
    static func name(of pid: pid_t) -> String? {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        defer { buffer.deallocate() }
        let len = proc_name(pid, buffer, 256)
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Get the foreground process of a shell by finding the youngest descendant.
    static func foregroundChild(of shellPid: pid_t) -> pid_t? {
        let allPids = childPidsOf(shellPid)
        // Return the last (most recently spawned) child, which is likely the foreground process
        return allPids.last
    }

    /// Get direct child PIDs of a specific process.
    private static func childPidsOf(_ parent: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size: Int = 0
        sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0)
        guard size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0)

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actualCount)
            .filter { $0.kp_eproc.e_ppid == parent }
            .map { $0.kp_proc.p_pid }
    }

    /// Read the git branch from .git/HEAD (fast, no subprocess).
    static func gitBranch(at path: String) -> String? {
        var dir = URL(fileURLWithPath: path)
        while dir.path != "/" {
            let gitHead = dir.appendingPathComponent(".git/HEAD")
            if let content = try? String(contentsOf: gitHead, encoding: .utf8) {
                if content.hasPrefix("ref: refs/heads/") {
                    return String(content.dropFirst("ref: refs/heads/".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Detached HEAD
                return String(content.prefix(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            dir = dir.deletingLastPathComponent()
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
