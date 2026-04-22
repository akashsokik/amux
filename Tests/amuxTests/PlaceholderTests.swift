import Testing
@testable import amux

@Suite("Placeholder")
struct PlaceholderTests {
    @Test("smoke")
    func smoke() {
        #expect(1 + 1 == 2)
    }
}
