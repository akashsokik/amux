# Runner Tab Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a third right-sidebar tab ("Runner") that lists auto-detected project tasks (npm scripts, Makefile targets, Procfile entries) plus user-pinned custom commands, lets the user start/stop them, streams their logs inline, and supports promoting any running task into a full Ghostty pane.

**Architecture:** New AppKit view `RunnerPanelView` hosted inside `RightSidebarView` alongside `GitPanelView` and `EditorSidebarView`. A `RunnerTaskStore` (per-worktree) produces a unioned task list from parsers over `package.json` / `Makefile` / `Procfile` merged with `.amux/tasks.json`. A `TaskRunner` spawns `/bin/sh -lc <cmd>` via `Foundation.Process`, captures stdout/stderr into a per-task ring buffer, and broadcasts coalesced updates to the view. Stop uses `SIGTERM` to the process group then escalates to `SIGKILL`. Promote-to-pane stops the inline run and opens a Ghostty pane preloaded with the command.

**Tech Stack:** Swift 6 / Swift 5 mode, AppKit, Foundation `Process` + `Pipe`, `DispatchSource` for file watching, Swift Testing framework (`@Test`, `#expect`) for unit tests.

**Design doc:** `docs/plans/2026-04-22-runner-tab-design.md` — read this first.

**Conventions already present (follow them):**
- `NSView` subclasses with glass background; see `Sources/amux/Views/GitPanelView.swift` for the full chrome + split-view pattern.
- Icon-bar buttons are `DimIconButton` with SF Symbols at `pointSize: 11, weight: .medium` (see `RightSidebarView.makeIconBarButton`).
- Theme colors via `Theme.*` plus a `themeDidChange` notification observer.
- Helpers are plain enums with `static` methods (`ProcessHelper`, `GitHelper`).
- Models under `Sources/amux/Models/`, views under `Sources/amux/Views/`, helpers under `Sources/amux/Helpers/`.
- Delegate protocols on views, not closures, for cross-view requests (see `GitPanelViewDelegate`).

---

## Phase 1 — Foundation: test target + pure parsers

### Task 1: Add a Swift Testing target for unit tests

**Files:**
- Modify: `Package.swift` — add a `.testTarget` named `amuxTests` that depends on `"amux"`.
- Create: `Tests/amuxTests/PlaceholderTests.swift`

**Step 1: Write a placeholder failing test**

```swift
// Tests/amuxTests/PlaceholderTests.swift
import Testing
@testable import amux

@Suite("Placeholder")
struct PlaceholderTests {
    @Test("smoke")
    func smoke() {
        #expect(1 + 1 == 2)
    }
}
```

**Step 2: Modify `Package.swift` to add the test target**

In the `targets:` array, append (keep the existing executable target unchanged):

```swift
.testTarget(
    name: "amuxTests",
    dependencies: ["amux"],
    path: "Tests/amuxTests"
),
```

**Step 3: Run it**

```bash
swift test --filter Placeholder
```

Expected: one test passes.

**Step 4: Commit**

```bash
git add Package.swift Tests/amuxTests/PlaceholderTests.swift
git commit -m "test: add amuxTests target with smoke test"
```

---

### Task 2: `RunnerTask` model + `.amux/tasks.json` schema

**Files:**
- Create: `Sources/amux/Models/RunnerTask.swift`
- Create: `Tests/amuxTests/RunnerTaskTests.swift`

**Step 1: Write failing tests**

```swift
// Tests/amuxTests/RunnerTaskTests.swift
import Testing
import Foundation
@testable import amux

@Suite("RunnerTask")
struct RunnerTaskTests {
    @Test("decodes v1 pinned file")
    func decodesV1() throws {
        let json = """
        {"version":1,"tasks":[
          {"id":"backend","name":"Backend","command":"./run.sh api"},
          {"id":"worker","name":"Worker","command":"cargo run","cwd":"crates/worker"}
        ]}
        """.data(using: .utf8)!
        let file = try JSONDecoder().decode(PinnedTasksFile.self, from: json)
        #expect(file.version == 1)
        #expect(file.tasks.count == 2)
        #expect(file.tasks[0].command == "./run.sh api")
        #expect(file.tasks[1].cwd == "crates/worker")
    }

    @Test("rejects unknown version")
    func rejectsUnknownVersion() {
        let json = #"{"version":99,"tasks":[]}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PinnedTasksFile.self, from: json)
        }
    }
}
```

**Step 2: Run — expect compile failure (types missing)**

```bash
swift test --filter RunnerTask
```

**Step 3: Implement the model**

```swift
// Sources/amux/Models/RunnerTask.swift
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
```

**Step 4: Run tests — expect pass**

```bash
swift test --filter RunnerTask
```

**Step 5: Commit**

```bash
git add Sources/amux/Models/RunnerTask.swift Tests/amuxTests/RunnerTaskTests.swift
git commit -m "feat(runner): add RunnerTask model and pinned file schema"
```

---

### Task 3: `ANSIStripper` helper

**Why:** Dev servers print ANSI color sequences that look like gibberish in plain `NSTextView`. Strip CSI escapes before writing into the inline log buffer. Promote-to-pane path bypasses this.

**Files:**
- Create: `Sources/amux/Helpers/ANSIStripper.swift`
- Create: `Tests/amuxTests/ANSIStripperTests.swift`

**Step 1: Write failing tests**

```swift
import Testing
@testable import amux

@Suite("ANSIStripper")
struct ANSIStripperTests {
    @Test("strips color sequences")
    func color() {
        #expect(ANSIStripper.strip("\u{1B}[31mhello\u{1B}[0m") == "hello")
        #expect(ANSIStripper.strip("\u{1B}[1;32mOK\u{1B}[m rest") == "OK rest")
    }

    @Test("strips cursor + erase sequences")
    func cursor() {
        #expect(ANSIStripper.strip("a\u{1B}[2Kb\u{1B}[3Ac") == "abc")
    }

    @Test("leaves plain text untouched")
    func plain() {
        #expect(ANSIStripper.strip("hello world\n") == "hello world\n")
    }

    @Test("drops bare escape char")
    func bareEsc() {
        #expect(ANSIStripper.strip("a\u{1B}b") == "ab")
    }
}
```

**Step 2: Implement**

```swift
// Sources/amux/Helpers/ANSIStripper.swift
import Foundation

enum ANSIStripper {
    /// Strip ANSI CSI sequences (ESC [ … final-byte) and drop bare ESC characters.
    /// Intentionally narrow: we only handle CSI, not OSC / DCS / other modes.
    static func strip(_ input: String) -> String {
        var out = String()
        out.reserveCapacity(input.count)
        var it = input.unicodeScalars.makeIterator()
        while let scalar = it.next() {
            if scalar == "\u{1B}" {
                // Expect '[' to start CSI; otherwise drop the bare ESC.
                guard let next = it.next() else { break }
                if next == "[" {
                    // Consume parameter + intermediate bytes, stop at final (0x40-0x7E).
                    while let s = it.next() {
                        let v = s.value
                        if v >= 0x40 && v <= 0x7E { break }
                    }
                }
                // else: swallowed the non-CSI char too.
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
```

**Step 3: Run tests — expect pass**

```bash
swift test --filter ANSIStripper
```

**Step 4: Commit**

```bash
git add Sources/amux/Helpers/ANSIStripper.swift Tests/amuxTests/ANSIStripperTests.swift
git commit -m "feat(runner): add ANSIStripper for inline log rendering"
```

---

### Task 4: Auto-detect `package.json` scripts

**Files:**
- Create: `Sources/amux/Helpers/TaskAutoDetect.swift`
- Create: `Tests/amuxTests/TaskAutoDetectPackageJSONTests.swift`
- Create: `Tests/amuxTests/Fixtures/` (directory for test fixtures)

**Step 1: Write failing tests**

```swift
// Tests/amuxTests/TaskAutoDetectPackageJSONTests.swift
import Testing
import Foundation
@testable import amux

@Suite("TaskAutoDetect.packageJSON")
struct TaskAutoDetectPackageJSONTests {
    private func tmpDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("amux-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("returns empty when package.json missing")
    func missing() {
        let dir = tmpDir()
        #expect(TaskAutoDetect.packageJSON(at: dir.path).isEmpty)
    }

    @Test("emits npm run for each script")
    func npm() throws {
        let dir = tmpDir()
        let json = #"{"scripts":{"dev":"vite","build":"vite build"}}"#
        try json.write(to: dir.appendingPathComponent("package.json"),
                       atomically: true, encoding: .utf8)
        let tasks = TaskAutoDetect.packageJSON(at: dir.path)
        #expect(tasks.count == 2)
        let byName = Dictionary(uniqueKeysWithValues: tasks.map { ($0.name, $0.command) })
        #expect(byName["dev"] == "npm run dev")
        #expect(byName["build"] == "npm run build")
    }

    @Test("picks pnpm when pnpm-lock.yaml exists")
    func pnpm() throws {
        let dir = tmpDir()
        try #"{"scripts":{"dev":"vite"}}"#.write(
            to: dir.appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("pnpm-lock.yaml"),
                     atomically: true, encoding: .utf8)
        #expect(TaskAutoDetect.packageJSON(at: dir.path).first?.command == "pnpm run dev")
    }

    @Test("picks bun for bun.lock or bun.lockb")
    func bun() throws {
        let dir = tmpDir()
        try #"{"scripts":{"dev":"vite"}}"#.write(
            to: dir.appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("bun.lockb"),
                     atomically: true, encoding: .utf8)
        #expect(TaskAutoDetect.packageJSON(at: dir.path).first?.command == "bun run dev")
    }

    @Test("invalid JSON yields empty list, not throw")
    func invalid() throws {
        let dir = tmpDir()
        try "not json".write(to: dir.appendingPathComponent("package.json"),
                             atomically: true, encoding: .utf8)
        #expect(TaskAutoDetect.packageJSON(at: dir.path).isEmpty)
    }
}
```

**Step 2: Implement the `packageJSON` branch**

```swift
// Sources/amux/Helpers/TaskAutoDetect.swift
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
```

**Step 3: Run tests — expect pass**

```bash
swift test --filter TaskAutoDetectPackageJSON
```

**Step 4: Commit**

```bash
git add Sources/amux/Helpers/TaskAutoDetect.swift Tests/amuxTests/TaskAutoDetectPackageJSONTests.swift
git commit -m "feat(runner): auto-detect npm/yarn/pnpm/bun scripts from package.json"
```

---

### Task 5: Auto-detect `Makefile` targets

**Files:**
- Modify: `Sources/amux/Helpers/TaskAutoDetect.swift` (replace `makefile` stub)
- Create: `Tests/amuxTests/TaskAutoDetectMakefileTests.swift`

**Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import amux

@Suite("TaskAutoDetect.makefile")
struct TaskAutoDetectMakefileTests {
    private func tmpDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("amux-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("extracts top-level targets")
    func targets() throws {
        let dir = tmpDir()
        let mk = """
        .PHONY: test build
        test:
        \t@echo running
        build: src/main.c
        \tgcc src/main.c
        # a comment
        clean:
        \trm -rf build
        """
        try mk.write(to: dir.appendingPathComponent("Makefile"),
                     atomically: true, encoding: .utf8)
        let names = TaskAutoDetect.makefile(at: dir.path).map(\.name).sorted()
        #expect(names == ["build", "clean", "test"])
        let t = TaskAutoDetect.makefile(at: dir.path).first { $0.name == "build" }!
        #expect(t.command == "make build")
    }

    @Test("skips dotted pseudo-targets")
    func dotted() throws {
        let dir = tmpDir()
        try ".PHONY: test\ntest:\n\techo\n".write(
            to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let names = TaskAutoDetect.makefile(at: dir.path).map(\.name)
        #expect(names == ["test"])
    }

    @Test("returns empty when no Makefile")
    func missing() {
        #expect(TaskAutoDetect.makefile(at: tmpDir().path).isEmpty)
    }
}
```

**Step 2: Replace the `makefile` stub**

```swift
static func makefile(at worktreePath: String) -> [RunnerTask] {
    let url = URL(fileURLWithPath: worktreePath).appendingPathComponent("Makefile")
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

    // Regex: start-of-line, name = [A-Za-z0-9_-]+, colon, not followed by '='
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
```

**Step 3: Run**

```bash
swift test --filter TaskAutoDetectMakefile
```

**Step 4: Commit**

```bash
git add Sources/amux/Helpers/TaskAutoDetect.swift Tests/amuxTests/TaskAutoDetectMakefileTests.swift
git commit -m "feat(runner): auto-detect Makefile top-level targets"
```

---

### Task 6: Auto-detect `Procfile` entries

**Files:**
- Modify: `Sources/amux/Helpers/TaskAutoDetect.swift` (replace `procfile` stub)
- Create: `Tests/amuxTests/TaskAutoDetectProcfileTests.swift`

**Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import amux

@Suite("TaskAutoDetect.procfile")
struct TaskAutoDetectProcfileTests {
    private func tmpDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("amux-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("parses name: cmd lines")
    func happy() throws {
        let dir = tmpDir()
        let proc = """
        web: bundle exec rails s -p 3000
        worker: bundle exec sidekiq

        # comment
        release: bin/migrate
        """
        try proc.write(to: dir.appendingPathComponent("Procfile"),
                       atomically: true, encoding: .utf8)
        let tasks = TaskAutoDetect.procfile(at: dir.path)
        let byName = Dictionary(uniqueKeysWithValues: tasks.map { ($0.name, $0.command) })
        #expect(tasks.count == 3)
        #expect(byName["web"] == "bundle exec rails s -p 3000")
        #expect(byName["worker"] == "bundle exec sidekiq")
        #expect(byName["release"] == "bin/migrate")
    }

    @Test("missing Procfile yields empty")
    func missing() {
        #expect(TaskAutoDetect.procfile(at: tmpDir().path).isEmpty)
    }
}
```

**Step 2: Replace the `procfile` stub**

```swift
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
```

**Step 3: Run**

```bash
swift test --filter TaskAutoDetectProcfile
```

**Step 4: Commit**

```bash
git add Sources/amux/Helpers/TaskAutoDetect.swift Tests/amuxTests/TaskAutoDetectProcfileTests.swift
git commit -m "feat(runner): auto-detect Procfile entries"
```

---

### Task 7: `RunnerTaskStore` — merge pinned + detected, save pinned

**Files:**
- Create: `Sources/amux/Models/RunnerTaskStore.swift`
- Create: `Tests/amuxTests/RunnerTaskStoreTests.swift`

**Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import amux

@Suite("RunnerTaskStore")
struct RunnerTaskStoreTests {
    private func tmpDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("amux-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("detected-only when no pinned file")
    func detectedOnly() throws {
        let dir = tmpDir()
        try #"{"scripts":{"dev":"vite"}}"#.write(
            to: dir.appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8)
        let store = RunnerTaskStore(worktreePath: dir.path)
        store.reload()
        #expect(store.tasks.count == 1)
        #expect(store.tasks[0].source == .npm)
        #expect(store.loadError == nil)
    }

    @Test("pinned id overrides detected id")
    func override() throws {
        let dir = tmpDir()
        try #"{"scripts":{"dev":"vite"}}"#.write(
            to: dir.appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8)
        let amuxDir = dir.appendingPathComponent(".amux")
        try FileManager.default.createDirectory(at: amuxDir, withIntermediateDirectories: true)
        let pinned = #"{"version":1,"tasks":[{"id":"npm:dev","name":"Dev (custom)","command":"vite --port=4000"}]}"#
        try pinned.write(to: amuxDir.appendingPathComponent("tasks.json"),
                         atomically: true, encoding: .utf8)

        let store = RunnerTaskStore(worktreePath: dir.path)
        store.reload()
        #expect(store.tasks.count == 1)
        let t = store.tasks[0]
        #expect(t.source == .pinned)
        #expect(t.isOverridden == true)
        #expect(t.command == "vite --port=4000")
    }

    @Test("invalid pinned JSON sets loadError but keeps detected")
    func invalidPinned() throws {
        let dir = tmpDir()
        try #"{"scripts":{"dev":"vite"}}"#.write(
            to: dir.appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8)
        let amuxDir = dir.appendingPathComponent(".amux")
        try FileManager.default.createDirectory(at: amuxDir, withIntermediateDirectories: true)
        try "not json".write(to: amuxDir.appendingPathComponent("tasks.json"),
                             atomically: true, encoding: .utf8)
        let store = RunnerTaskStore(worktreePath: dir.path)
        store.reload()
        #expect(store.tasks.count == 1)
        #expect(store.loadError != nil)
    }

    @Test("save round-trips")
    func save() throws {
        let dir = tmpDir()
        let store = RunnerTaskStore(worktreePath: dir.path)
        try store.addPinned(PinnedTask(id: "backend", name: "Backend",
                                       command: "./run.sh", cwd: nil))
        let reloaded = RunnerTaskStore(worktreePath: dir.path)
        reloaded.reload()
        #expect(reloaded.tasks.contains { $0.id == "backend" && $0.source == .pinned })
    }
}
```

**Step 2: Implement**

```swift
// Sources/amux/Models/RunnerTaskStore.swift
import Foundation

/// Publishes the merged list of detected + pinned tasks for a single worktree.
/// Not thread-safe: use from the main thread.
final class RunnerTaskStore {
    let worktreePath: String
    private(set) var tasks: [RunnerTask] = []
    private(set) var loadError: String?

    /// Notified whenever `tasks` changes.
    static let didChangeNotification = Notification.Name("RunnerTaskStoreDidChange")

    init(worktreePath: String) {
        self.worktreePath = worktreePath
    }

    /// Re-scan disk and rebuild `tasks`. Idempotent.
    func reload() {
        let detected = TaskAutoDetect.all(at: worktreePath)
        let (pinned, error) = loadPinned()
        self.loadError = error

        // Merge: pinned wins on id collision; non-colliding detected retained.
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

    /// Add a pinned task (or update in-place if `id` already exists) and persist.
    func addPinned(_ task: PinnedTask) throws {
        let (current, _) = loadPinned()
        var next = current.filter { $0.id != task.id }
        next.append(task)
        let file = PinnedTasksFile(version: 1, tasks: next)

        let fm = FileManager.default
        try fm.createDirectory(
            at: pinnedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: pinnedFileURL, options: .atomic)
        reload()
    }

    /// Remove a pinned task by id and persist.
    func removePinned(id: String) throws {
        let (current, _) = loadPinned()
        let next = current.filter { $0.id != id }
        if next.count == current.count { return }
        let file = PinnedTasksFile(version: 1, tasks: next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: pinnedFileURL, options: .atomic)
        reload()
    }
}
```

**Step 3: Run tests**

```bash
swift test --filter RunnerTaskStore
```

**Step 4: Commit**

```bash
git add Sources/amux/Models/RunnerTaskStore.swift Tests/amuxTests/RunnerTaskStoreTests.swift
git commit -m "feat(runner): task store merges pinned over auto-detected"
```

---

## Phase 2 — Runtime: ring buffer + process supervisor

### Task 8: `LogRingBuffer` — bounded, line-oriented log storage

**Files:**
- Create: `Sources/amux/Models/LogRingBuffer.swift`
- Create: `Tests/amuxTests/LogRingBufferTests.swift`

**Step 1: Write failing tests**

```swift
import Testing
@testable import amux

@Suite("LogRingBuffer")
struct LogRingBufferTests {
    @Test("retains lines within cap")
    func withinCap() {
        let b = LogRingBuffer(maxLines: 3)
        b.append("a\nb\n")
        #expect(b.snapshot() == "a\nb\n")
    }

    @Test("drops oldest past cap")
    func overflow() {
        let b = LogRingBuffer(maxLines: 3)
        b.append("a\nb\nc\nd\n")
        #expect(b.snapshot() == "b\nc\nd\n")
    }

    @Test("handles partial final line")
    func partial() {
        let b = LogRingBuffer(maxLines: 5)
        b.append("hello")
        b.append(" world\nmore")
        #expect(b.snapshot() == "hello world\nmore")
    }

    @Test("clear empties buffer")
    func clear() {
        let b = LogRingBuffer(maxLines: 3)
        b.append("a\nb\n")
        b.clear()
        #expect(b.snapshot().isEmpty)
    }
}
```

**Step 2: Implement**

```swift
// Sources/amux/Models/LogRingBuffer.swift
import Foundation

/// Thread-safe, line-oriented ring buffer for task log output.
/// Stores up to `maxLines` terminated lines plus an in-progress partial tail.
final class LogRingBuffer: @unchecked Sendable {
    private let maxLines: Int
    private let queue = DispatchQueue(label: "amux.LogRingBuffer")
    private var lines: [String] = []
    private var partial: String = ""

    init(maxLines: Int = 10_000) {
        self.maxLines = maxLines
    }

    func append(_ chunk: String) {
        queue.sync {
            var text = partial + chunk
            partial = ""
            while let nl = text.firstIndex(of: "\n") {
                lines.append(String(text[..<nl]))
                text = String(text[text.index(after: nl)...])
                if lines.count > maxLines {
                    lines.removeFirst(lines.count - maxLines)
                }
            }
            partial = text
        }
    }

    func snapshot() -> String {
        queue.sync {
            var out = lines.map { $0 + "\n" }.joined()
            out.append(partial)
            return out
        }
    }

    func clear() {
        queue.sync {
            lines.removeAll(keepingCapacity: true)
            partial = ""
        }
    }
}
```

**Step 3: Run tests**

```bash
swift test --filter LogRingBuffer
```

**Step 4: Commit**

```bash
git add Sources/amux/Models/LogRingBuffer.swift Tests/amuxTests/LogRingBufferTests.swift
git commit -m "feat(runner): bounded ring buffer for task log output"
```

---

### Task 9: `TaskRunner` — spawn, capture, stop, restart

**Files:**
- Create: `Sources/amux/Models/TaskRunner.swift`
- Create: `Tests/amuxTests/TaskRunnerTests.swift`

**Step 1: Write failing tests (integration smoke — runs real processes)**

```swift
import Testing
import Foundation
@testable import amux

@Suite("TaskRunner")
struct TaskRunnerTests {
    @Test("captures stdout of echo + reports exit 0")
    func echo() async throws {
        let runner = TaskRunner()
        let task = RunnerTask(id: "t", name: "t", command: "echo hi",
                              cwd: nil, source: .pinned, isOverridden: false)
        runner.start(task, worktreePath: NSTemporaryDirectory())
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
        let session = runner.session(for: task.id)
        #expect(session != nil)
        #expect(session!.buffer.snapshot().contains("hi"))
        #expect(session!.status == .exited(0))
    }

    @Test("stop terminates long-running process within escalation window")
    func stop() async throws {
        let runner = TaskRunner()
        let task = RunnerTask(id: "t2", name: "t2", command: "sleep 30",
                              cwd: nil, source: .pinned, isOverridden: false)
        runner.start(task, worktreePath: NSTemporaryDirectory())
        try await Task.sleep(nanoseconds: 300_000_000)
        runner.stop(id: task.id)
        try await Task.sleep(nanoseconds: 4_500_000_000) // 4.5s > 3s escalation
        let session = runner.session(for: task.id)
        guard case .terminated = session?.status else {
            Issue.record("expected terminated status, got \(String(describing: session?.status))")
            return
        }
    }

    @Test("restart replaces running session")
    func restart() async throws {
        let runner = TaskRunner()
        let task = RunnerTask(id: "t3", name: "t3", command: "sleep 30",
                              cwd: nil, source: .pinned, isOverridden: false)
        runner.start(task, worktreePath: NSTemporaryDirectory())
        try await Task.sleep(nanoseconds: 300_000_000)
        let firstPid = runner.session(for: task.id)?.pid
        runner.restart(task, worktreePath: NSTemporaryDirectory())
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let secondPid = runner.session(for: task.id)?.pid
        #expect(firstPid != nil && secondPid != nil && firstPid != secondPid)
        runner.stop(id: task.id)
    }
}
```

**Step 2: Implement**

```swift
// Sources/amux/Models/TaskRunner.swift
import Foundation

enum TaskStatus: Equatable {
    case running
    case exited(Int32)
    case terminated
    case failedToStart(String)
}

/// One active run of a task. Owned by `TaskRunner`.
final class TaskRunSession {
    let taskId: String
    let startedAt: Date
    let buffer: LogRingBuffer
    fileprivate(set) var status: TaskStatus = .running
    fileprivate(set) var pid: pid_t?
    fileprivate let process: Process

    init(taskId: String, buffer: LogRingBuffer, process: Process) {
        self.taskId = taskId
        self.startedAt = Date()
        self.buffer = buffer
        self.process = process
    }
}

/// Supervisor for task runs. One session per task id; re-running a live task restarts it.
final class TaskRunner {
    static let didUpdateNotification = Notification.Name("TaskRunnerDidUpdate")

    private var sessions: [String: TaskRunSession] = [:]
    private let queue = DispatchQueue(label: "amux.TaskRunner")

    func session(for id: String) -> TaskRunSession? {
        queue.sync { sessions[id] }
    }

    func start(_ task: RunnerTask, worktreePath: String) {
        queue.sync {
            if let existing = sessions[task.id], existing.status == .running {
                _stopLocked(id: task.id)
            }
            guard let session = _spawnLocked(task: task, worktreePath: worktreePath) else { return }
            sessions[task.id] = session
        }
        postUpdate(id: task.id)
    }

    func restart(_ task: RunnerTask, worktreePath: String) {
        stop(id: task.id)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            self?.start(task, worktreePath: worktreePath)
        }
    }

    func stop(id: String) {
        queue.sync { _stopLocked(id: id) }
        postUpdate(id: id)
    }

    private func _stopLocked(id: String) {
        guard let session = sessions[id], session.status == .running,
              let pid = session.pid else { return }
        // Send SIGTERM to the entire process group. setpgid on spawn means pgid == pid.
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            self.queue.sync {
                if let s = self.sessions[id], s.status == .running, let p = s.pid {
                    kill(-p, SIGKILL)
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
        env["TERM"] = "dumb"   // suppress TUI sequences in the inline view
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // New process group so kill(-pgid) reaches the whole subtree.
        process.startsNewProcessGroupWhenSet = true  // Swift >=5.9
        // Fallback for older toolchains uses a posix_spawn attr; the flag above is the
        // Foundation-supported way on macOS 14+.

        let buffer = LogRingBuffer()
        let session = TaskRunSession(taskId: task.id, buffer: buffer, process: process)

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                buffer.append(ANSIStripper.strip(s))
                NotificationCenter.default.post(
                    name: TaskRunner.didUpdateNotification, object: nil,
                    userInfo: ["taskId": task.id]
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
                    userInfo: ["taskId": task.id]
                )
            }
        }

        process.terminationHandler = { [weak self] p in
            self?.queue.async {
                guard let self, let s = self.sessions[task.id] else { return }
                switch p.terminationReason {
                case .exit:        s.status = .exited(p.terminationStatus)
                case .uncaughtSignal: s.status = .terminated
                @unknown default:  s.status = .terminated
                }
                NotificationCenter.default.post(
                    name: TaskRunner.didUpdateNotification, object: nil,
                    userInfo: ["taskId": task.id]
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

    private func postUpdate(id: String) {
        NotificationCenter.default.post(
            name: Self.didUpdateNotification, object: nil,
            userInfo: ["taskId": id]
        )
    }
}
```

**Step 3: Run tests — expect pass**

```bash
swift test --filter TaskRunner
```

> If `process.startsNewProcessGroupWhenSet` is unavailable on the installed Swift toolchain, replace that line with the following lower-level replacement that calls `posix_spawnattr_setflags` — the engineer will need to factor a C-level `Process` subclass out; first try the property and only fall back if it won't compile.

**Step 4: Commit**

```bash
git add Sources/amux/Models/TaskRunner.swift Tests/amuxTests/TaskRunnerTests.swift
git commit -m "feat(runner): process supervisor with stdout/stderr capture and signal-group stop"
```

---

## Phase 3 — UI

### Task 10: `RunnerPanelView` skeleton (empty state, glass chrome)

**Files:**
- Create: `Sources/amux/Views/RunnerPanelView.swift`

Use `Sources/amux/Views/GitPanelView.swift` as a template for glass, separator, `topContentInset`, `chromeHidden`, and `themeDidChange`. This task stops short of the list; it establishes the container so later tasks can slot content in.

**Step 1: Implement the skeleton**

```swift
import AppKit

protocol RunnerPanelViewDelegate: AnyObject {
    /// Called when the user taps "Open in pane" for a running task.
    func runnerPanelDidRequestOpenInPane(command: String, cwd: String)
}

final class RunnerPanelView: NSView {
    weak var delegate: RunnerPanelViewDelegate?

    var topContentInset: CGFloat = 10 {
        didSet { topInsetConstraint?.constant = topContentInset }
    }
    var chromeHidden: Bool = false { didSet { applyGlassOrSolid() } }

    private var glassView: GlassBackgroundView?
    private var emptyLabel: NSTextField!
    private var topInsetConstraint: NSLayoutConstraint?

    private(set) var store: RunnerTaskStore?
    private let runner = TaskRunner()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    func setGlassHidden(_ hidden: Bool) {
        glassView?.isHidden = hidden
        if hidden {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
        } else {
            applyGlassOrSolid()
        }
    }

    /// Bind to a worktree; nil means "no worktree open".
    func setWorktree(_ path: String?) {
        if let p = path {
            if store?.worktreePath != p {
                store = RunnerTaskStore(worktreePath: p)
                store?.reload()
            }
        } else {
            store = nil
        }
        refreshEmptyState()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        emptyLabel = NSTextField(labelWithString: "Open a worktree to run tasks.")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.alignment = .center
        addSubview(emptyLabel)

        topInsetConstraint = emptyLabel.topAnchor.constraint(equalTo: topAnchor,
                                                             constant: topContentInset)
        NSLayoutConstraint.activate([
            topInsetConstraint!,
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        applyGlassOrSolid()
    }

    private func applyGlassOrSolid() {
        if Theme.useVibrancy && !chromeHidden {
            layer?.backgroundColor = NSColor.clear.cgColor
            if glassView == nil {
                let gv = GlassBackgroundView()
                gv.translatesAutoresizingMaskIntoConstraints = false
                addSubview(gv, positioned: .below, relativeTo: subviews.first)
                NSLayoutConstraint.activate([
                    gv.topAnchor.constraint(equalTo: topAnchor),
                    gv.bottomAnchor.constraint(equalTo: bottomAnchor),
                    gv.leadingAnchor.constraint(equalTo: leadingAnchor),
                    gv.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                glassView = gv
            }
            glassView?.isHidden = false
            glassView?.setTint(Theme.sidebarBg)
        } else {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
            glassView?.isHidden = true
        }
    }

    @objc private func themeDidChange() { applyGlassOrSolid() }

    private func refreshEmptyState() {
        if store == nil {
            emptyLabel.stringValue = "Open a worktree to run tasks."
            emptyLabel.isHidden = false
        } else if store?.tasks.isEmpty == true {
            emptyLabel.stringValue = "No tasks detected. Tap + to add one, or create .amux/tasks.json."
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }
}
```

**Step 2: Build**

```bash
swift build
```

Expected: succeeds.

**Step 3: Commit**

```bash
git add Sources/amux/Views/RunnerPanelView.swift
git commit -m "feat(runner): RunnerPanelView skeleton (empty states, glass chrome)"
```

---

### Task 11: Task list with outline grouping, status dots, run toggle

**Files:**
- Modify: `Sources/amux/Views/RunnerPanelView.swift`

Adopt `NSOutlineView` to show tasks grouped by source, mirroring the patterns in `GitPanelView` (section headers, hover table, custom cell views). Each row: a play/stop toggle button on the left, the task name, a status dot on the right when running, a "custom" badge when `isOverridden`.

Observe `RunnerTaskStore.didChangeNotification` to reload rows; observe `TaskRunner.didUpdateNotification` to refresh row status without a full reload.

Selection sets the current log target for Task 12.

**Guidance for the engineer:**
- Groups: `.pinned`, `.npm`, `.make`, `.procfile` in that order; hide empty groups.
- Row heights: 22px, matching existing panels.
- For the play/stop toggle, reuse `DimIconButton` with SF Symbols `play.fill` / `stop.fill`.
- Double-clicking a row toggles run state (convenience).
- Keep this view logic-only: all process work stays in `TaskRunner`.

**Step 1: Wire the outline + cells, expose a `selectedTaskID` property.**

(Code omitted for brevity — the shape of the outline view is the same as `GitPanelView.changesOutline`. Copy that file's `NSOutlineViewDelegate` / `DataSource` section as a scaffold.)

**Step 2: Build and run the app**

```bash
swift build
./run.sh   # if a run.sh helper exists, else `swift run amux`
```

Manually verify: open a worktree with `package.json` scripts, the Runner tab shows them grouped under "npm".

**Step 3: Commit**

```bash
git add Sources/amux/Views/RunnerPanelView.swift
git commit -m "feat(runner): task list outline grouped by source"
```

---

### Task 12: Log panel + split-view + tailing the selected task

**Files:**
- Modify: `Sources/amux/Views/RunnerPanelView.swift`

- Use `NSSplitView` exactly like `GitPanelView.splitView` — two panes, draggable divider, persistent initial position.
- Bottom pane: a header row (task name, promote button, stop button, clear button) plus a `NSScrollView` wrapping an `NSTextView` that is non-editable, monospaced, word-wrapping off.
- On `TaskRunner.didUpdateNotification` whose `taskId` matches the selected id, coalesce updates via a `DispatchWorkItem` with a 16 ms debounce and re-set the text view's string from `session.buffer.snapshot()`.
- Auto-scroll to the bottom when the user is already at the bottom (check `documentVisibleRect.maxY`); do not auto-scroll if the user scrolled up.

Promote button action calls `delegate?.runnerPanelDidRequestOpenInPane(command:, cwd:)` with the effective cwd. Stop button calls `runner.stop(id:)`. Clear button calls `buffer.clear()` and refreshes the text view.

**Step 1: Implement the log pane.**

**Step 2: Build.**

**Step 3: Commit**

```bash
git add Sources/amux/Views/RunnerPanelView.swift
git commit -m "feat(runner): log panel with split view and coalesced tailing"
```

---

### Task 13: "Add custom task" sheet

**Files:**
- Modify: `Sources/amux/Views/RunnerPanelView.swift`

Add a header "+" button that presents a small modal `NSPanel` sheet with three fields: Name, Command, CWD (optional). On Save, call `store.addPinned(…)`. Validate: `id` derived from name via lowercased kebab-case; disallow empty Name/Command.

**Step 1: Implement the sheet.**

**Step 2: Build + manual verify**

Run the app, click "+", add `"Backend" / "./run.sh api"`, confirm it shows up under the "pinned" group and that `.amux/tasks.json` now exists.

**Step 3: Commit**

```bash
git add Sources/amux/Views/RunnerPanelView.swift
git commit -m "feat(runner): + sheet to pin custom tasks"
```

---

### Task 14: Error banner for invalid `.amux/tasks.json` + file watcher

**Files:**
- Modify: `Sources/amux/Views/RunnerPanelView.swift`
- Modify: `Sources/amux/Models/RunnerTaskStore.swift` (add `DispatchSource` file watcher)

**In `RunnerTaskStore`:** expose `startWatching()` / `stopWatching()`. Use `DispatchSource.makeFileSystemObjectSource(fileDescriptor:..., eventMask: [.write, .rename, .delete])` on `.amux/tasks.json`. On any event, call `reload()`. Re-open the file descriptor after a rename/delete by re-creating the source. Start watching from `init` if the file exists; also watch the parent `.amux` directory so creating the file later triggers a reload.

**In `RunnerPanelView`:** if `store.loadError != nil`, render a thin red banner above the list with the error string and an "Edit file" button that opens the file in the default editor (use `NSWorkspace.shared.open(url)`).

**Step 1 + 2: Implement, build, manually verify**

- Write bad JSON: banner appears, detected tasks still shown.
- Fix the JSON: banner disappears on its own (file watcher fires).

**Step 3: Commit**

```bash
git add Sources/amux/Models/RunnerTaskStore.swift Sources/amux/Views/RunnerPanelView.swift
git commit -m "feat(runner): file watcher + invalid-tasks.json error banner"
```

---

## Phase 4 — Integration

### Task 15: Add `.runner` mode to `RightSidebarView`

**Files:**
- Modify: `Sources/amux/Views/RightSidebarView.swift`

**Edits:**

1. Extend the enum:

```swift
enum RightSidebarMode {
    case editor
    case git
    case runner
}
```

2. Add the third icon button + view property. In `setupIconBar()` add after `editorButton`:

```swift
runnerButton = makeIconBarButton(symbol: "play.circle", action: #selector(runnerButtonClicked))
iconBar.addSubview(runnerButton)
```

Add a constraint in `setupConstraints()` anchoring `runnerButton` to the right of `editorButton` with the same 6pt gap.

3. Store `let runnerPanelView: RunnerPanelView` in the view; accept it via the initializer (parallels `editorSidebarView` / `gitPanelView`).

4. In `setupChildren()`, add the runner view with `topContentInset = 10`, `chromeHidden = true`.

5. In `applyMode()`:

```swift
editorButton.isActiveState = (mode == .editor)
gitButton.isActiveState    = (mode == .git)
runnerButton.isActiveState = (mode == .runner)
editorSidebarView.isHidden = (mode != .editor)
gitPanelView.isHidden      = (mode != .git)
runnerPanelView.isHidden   = (mode != .runner)
```

6. In `themeDidChange()` call `runnerButton.refreshDimState()`.

7. Add `@objc private func runnerButtonClicked() { setMode(.runner) }`.

8. Update `setGlassHidden` to also call `runnerPanelView.setGlassHidden(hidden)`.

**Step 1: Make edits**

**Step 2: Build**

```bash
swift build
```

**Step 3: Commit**

```bash
git add Sources/amux/Views/RightSidebarView.swift
git commit -m "feat(runner): right sidebar third tab (runner) wiring"
```

---

### Task 16: Wire `RunnerPanelView` in `MainWindowController`

**Files:**
- Modify: `Sources/amux/Views/MainWindowController.swift`

**Edits:**

1. Add a stored property: `private(set) var runnerPanelView: RunnerPanelView!`
2. In `setupViews()` (where `editorSidebarView` and `gitPanelView` are instantiated today), construct `runnerPanelView = RunnerPanelView()` and pass it into `RightSidebarView(editorSidebarView:gitPanelView:runnerPanelView:)`.
3. Set `runnerPanelView.delegate = self` and implement `RunnerPanelViewDelegate`:

   ```swift
   func runnerPanelDidRequestOpenInPane(command: String, cwd: String) {
       // Use existing pane-split machinery to open a new pane, then send the
       // command into the shell. Concrete API depends on SplitContainerView —
       // pick the existing "add new pane" path used by Cmd+T, then type the
       // command into the newly focused Ghostty terminal.
       // Investigation required — see Task 17.
   }
   ```

4. In `displaySession(_:)`, after the session is displayed, compute the active worktree path (best current proxy: the focused pane's `currentDirectory`, normalized to repo root via `GitHelper.repoRoot(from:)`) and call `runnerPanelView.setWorktree(path)`.
5. Observe `SessionManager` / focused-pane-change notifications and call `runnerPanelView.setWorktree(...)` on switch.

**Step 1: Make edits**

**Step 2: Build + launch the app**

```bash
swift build
./run.sh 2>/dev/null || swift run amux
```

Manually verify:
- Runner tab shows up in the right sidebar and switches correctly.
- With a worktree containing a `package.json`, tasks appear.
- Clicking Run on a short command (e.g. an `npm` script that `echo`s) shows output in the log pane.

**Step 3: Commit**

```bash
git add Sources/amux/Views/MainWindowController.swift
git commit -m "feat(runner): host RunnerPanelView and bind active worktree"
```

---

### Task 17: Promote-to-pane (investigation + minimum viable wiring)

This task is an investigation + an implementation; timebox the investigation at 30 minutes before falling back.

**Primary approach — pass `initial-command` to Ghostty config:**
- Search `Sources/amux/Bridge/GhosttyApp.swift` for how `ghostty_config_t` is constructed. Ghostty supports a `command` / `initial-command` config key — if the bridge passes config strings per-surface, plumb an `initialCommand: String?` through `TerminalPane.init` and through `SplitContainerView.createPane` to the Ghostty bridge.
- When the user taps Promote, stop the inline run, create a new pane with `initialCommand = task.command` in the appropriate cwd, and let Ghostty spawn it natively.

**Fallback approach — type into the new pane:**
- Open an empty pane via the existing split/tab path.
- After a short delay (500 ms to let the shell prompt appear), send the command text + `\n` using the existing Ghostty input bridge (`GhosttyInput.swift` / `sendText` or equivalent).
- Accept that this has a brief user-visible "typing" animation.

**Either way:**
- The inline `TaskRunSession` is stopped when promoted. The log view shows a one-line breadcrumb: `"Promoted to pane at HH:MM:SS"`.

**Step 1: Investigate `GhosttyApp.swift` + `TerminalPane.init`; pick primary or fallback.**

**Step 2: Implement the chosen path.**

**Step 3: Manual verify**

- Run `npm run dev` inline in a real project, click Promote, confirm Vite's TUI renders in the new pane with color.

**Step 4: Commit**

```bash
git add -A
git commit -m "feat(runner): promote running task into a Ghostty pane"
```

---

## Phase 5 — Polish

### Task 18: `Cmd+R` keybinding toggles the Runner tab

**Files:**
- Modify: `Sources/amux/Shortcuts/KeyboardShortcuts.swift`
- Modify: `Sources/amux/App/AppDelegate.swift` (if that's where menu items live — check how `Cmd+/` is wired for the right-sidebar toggle)

Mirror the existing `Cmd+/` toggle (commit `76aaab6 fix: cmd+/ for toggle r-bar`) — find its handler, add a sibling that sets `rightSidebarView.setMode(.runner)` and ensures the sidebar is visible.

Note: `Cmd+R` may collide with a pre-existing shortcut. If so, pick `Cmd+Shift+R` or `Cmd+Opt+R` and document the choice.

**Step 1: Implement.**

**Step 2: Commit**

```bash
git commit -am "feat(runner): add keybinding to toggle runner tab"
```

---

### Task 19: Full build + test run + manual QA checklist

**Step 1: Run the full test suite**

```bash
swift test
```

Expected: all tests green.

**Step 2: Build + run**

```bash
swift build
./run.sh 2>/dev/null || swift run amux
```

**Manual QA checklist (do all):**

- [ ] Open a worktree without `package.json` → empty state shows guidance.
- [ ] Open a worktree with `package.json` scripts → they appear under "npm".
- [ ] Add a `Makefile` with two targets → they appear under "make".
- [ ] Add a `Procfile` with one line → appears under "procfile".
- [ ] Run a short task (e.g. `echo hi; sleep 1`) → output streams, status dot goes green then to exit indicator.
- [ ] Run a long-running task (local dev server) → logs stream live.
- [ ] Stop the long-running task → process terminates within 3 s; status indicator updates.
- [ ] Clear logs → text view empties.
- [ ] Promote running task to pane → full TUI/color appears in the new pane.
- [ ] Add a custom task via "+" sheet → writes `.amux/tasks.json`, appears under "pinned".
- [ ] Make a pinned task override an auto-detected id → "custom" badge appears on that row.
- [ ] Invalidate `.amux/tasks.json` manually → red banner appears; fixing the file clears the banner without an explicit refresh.
- [ ] Switch worktrees (two open) → the tasks list swaps; running tasks in the inactive worktree remain alive (verify via `ps`).
- [ ] `Cmd+R` (or chosen key) toggles the Runner tab.

**Step 3: If anything fails, file follow-up tasks; otherwise move on.**

---

### Task 20: Final review + merge-ready commit

**Step 1: `git log --oneline main..HEAD` — confirm each task produced a meaningful commit.**

**Step 2: Open the PR via the existing workflow (see repo README or follow standard `gh pr create`).**

---

## Risks + open questions (flag to user before merge)

1. **`Process.startsNewProcessGroupWhenSet`** is a Foundation convenience; if it's unavailable on the building toolchain, Task 9 needs a small `posix_spawn_file_actions_t` helper to set `SPAWN_SETPGROUP`.
2. **Promote-to-pane** hinges on Ghostty's bridge supporting an initial command per-surface. Task 17 documents the fallback ("type the command into the new shell"), which is slightly worse UX but always works.
3. **Worktree binding** uses the focused pane's inferred cwd (normalized to repo root). If the user has `cd`'d deep inside a subdirectory, that's fine — repo root normalization stays at the worktree. Confirm the resolution in `MainWindowController` matches the cwd used by `GitPanelView`.
4. **`.amux/tasks.json`** is left for the team to commit or `.gitignore` — not automatic.
