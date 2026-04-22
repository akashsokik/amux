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
