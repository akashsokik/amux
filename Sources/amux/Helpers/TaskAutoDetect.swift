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

    // Stubs — filled by later tasks.
    static func makefile(at worktreePath: String) -> [RunnerTask] { [] }
    static func procfile(at worktreePath: String) -> [RunnerTask] { [] }
}
