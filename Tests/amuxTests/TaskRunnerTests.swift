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
        try await Task.sleep(nanoseconds: 1_500_000_000)
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
        try await Task.sleep(nanoseconds: 4_500_000_000)
        let session = runner.session(for: task.id)
        switch session?.status {
        case .terminated, .exited:
            break
        default:
            Issue.record("expected terminated or exited, got \(String(describing: session?.status))")
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
