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
