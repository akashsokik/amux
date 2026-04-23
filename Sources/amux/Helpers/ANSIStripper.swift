import Foundation

enum ANSIStripper {
    /// Strip ANSI CSI sequences (ESC [ … final-byte) and drop bare ESC characters.
    /// Intentionally narrow: we only handle CSI, not OSC / DCS / other modes.
    static func strip(_ input: String) -> String {
        var out = String()
        out.reserveCapacity(input.count)
        var it = input.unicodeScalars.makeIterator()
        while let scalar = it.next() {
            if scalar == "\u{1B}" {
                // Expect '[' to start CSI; otherwise drop the bare ESC.
                guard let next = it.next() else { break }
                if next == "[" {
                    // Consume parameter + intermediate bytes, stop at final (0x40-0x7E).
                    while let s = it.next() {
                        let v = s.value
                        if v >= 0x40 && v <= 0x7E { break }
                    }
                } else {
                    // Bare ESC: drop it but keep the following scalar.
                    out.unicodeScalars.append(next)
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
