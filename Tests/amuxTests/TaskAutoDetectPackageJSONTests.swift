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
