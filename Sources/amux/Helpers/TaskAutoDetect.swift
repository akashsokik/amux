import Foundation

enum TaskAutoDetect {
    /// Scan all supported sources in `worktreePath`, return a merged list.
    /// Individual parsers silently return [] on missing/invalid input.
    static func all(at worktreePath: String) -> [RunnerTask] {
        return packageJSON(at: worktreePath)
             + makefile(at: worktreePath)
             + procfile(at: worktreePath)
    }

    // MARK: - package.json

    static func packageJSON(at worktreePath: String) -> [RunnerTask] {
        let pkgURL = URL(fileURLWithPath: worktreePath).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = root["scripts"] as? [String: Any] else {
            return []
        }
        let pm = detectPackageManager(at: worktreePath)
        return scripts.keys.sorted().map { name in
            RunnerTask(
                id: "npm:\(name)",
                name: name,
                command: "\(pm) run \(name)",
                cwd: nil,
                source: .npm,
                isOverridden: false
            )
        }
    }

    private static func detectPackageManager(at dir: String) -> String {
        let fm = FileManager.default
        let has = { (name: String) -> Bool in
            fm.fileExists(atPath: (dir as NSString).appendingPathComponent(name))
        }
        if has("bun.lock") || has("bun.lockb") { return "bun" }
        if has("pnpm-lock.yaml") { return "pnpm" }
        if has("yarn.lock") { return "yarn" }
        return "npm"
    }

    // MARK: - Makefile

    static func makefile(at worktreePath: String) -> [RunnerTask] {
        let url = URL(fileURLWithPath: worktreePath).appendingPathComponent("Makefile")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        // Match start-of-line, name = [A-Za-z0-9_-]+, colon, not followed by '='
        // (avoid matching ':=' assignment lines).
        let pattern = #"^([A-Za-z0-9_-]+):(?!=)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        var seen = Set<String>()
        var out: [RunnerTask] = []
        let ns = content as NSString
        re.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let name = ns.substring(with: m.range(at: 1))
            guard !name.hasPrefix("."), seen.insert(name).inserted else { return }
            out.append(RunnerTask(
                id: "make:\(name)",
                name: name,
                command: "make \(name)",
                cwd: nil,
                source: .make,
                isOverridden: false
            ))
        }
        return out
    }

    // MARK: - Procfile

    static func procfile(at worktreePath: String) -> [RunnerTask] {
        let url = URL(fileURLWithPath: worktreePath).appendingPathComponent("Procfile")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [RunnerTask] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let cmd  = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !cmd.isEmpty else { continue }
            out.append(RunnerTask(
                id: "procfile:\(name)",
                name: name,
                command: cmd,
                cwd: nil,
                source: .procfile,
                isOverridden: false
            ))
        }
        return out
    }
}
