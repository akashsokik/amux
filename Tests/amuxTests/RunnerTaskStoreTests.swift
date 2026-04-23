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
