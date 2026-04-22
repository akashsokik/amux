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
