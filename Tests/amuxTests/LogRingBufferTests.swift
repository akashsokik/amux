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
