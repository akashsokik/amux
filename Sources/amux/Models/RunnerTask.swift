import Foundation

enum RunnerTaskSource: String, Equatable, Hashable {
    case npm
    case make
    case procfile
    case pinned
}

struct RunnerTask: Equatable, Hashable, Identifiable {
    let id: String          // stable key: "<source>:<name>" for detected, raw id for pinned
    let name: String
    let command: String
    let cwd: String?        // nil = worktree root; relative resolves against worktree root
    let source: RunnerTaskSource
    let isOverridden: Bool  // true when a pinned task shadows an auto-detected one
}

/// On-disk shape of `.amux/tasks.json`.
struct PinnedTasksFile: Codable, Equatable {
    let version: Int
    let tasks: [PinnedTask]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .version)
        guard v == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c,
                debugDescription: "Unsupported pinned tasks file version: \(v)"
            )
        }
        self.version = v
        self.tasks = try c.decode([PinnedTask].self, forKey: .tasks)
    }

    init(version: Int, tasks: [PinnedTask]) {
        self.version = version
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey { case version, tasks }
}

struct PinnedTask: Codable, Equatable, Hashable {
    let id: String
    let name: String
    let command: String
    let cwd: String?
}
