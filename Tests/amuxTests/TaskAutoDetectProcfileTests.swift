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
