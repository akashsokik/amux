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
