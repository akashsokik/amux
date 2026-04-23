import AppKit

/// Converts a string containing ANSI escape sequences into an
/// `NSAttributedString`, applying SGR color/style attributes. Non-SGR CSI
/// sequences (cursor movement, erase) are stripped silently. OSC / DCS
/// sequences are dropped up to their terminator so they don't bleed into
/// visible text.
enum ANSIRenderer {
    struct Style {
        var fg: NSColor
        var bg: NSColor?
        var bold: Bool
        var italic: Bool
        var underline: Bool
    }

    static func render(
        _ input: String,
        defaultColor: NSColor,
        font: NSFont
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var style = Style(fg: defaultColor, bg: nil, bold: false, italic: false, underline: false)

        let scalars = input.unicodeScalars
        var i = scalars.startIndex

        // Running buffer of plain scalars to flush with current style.
        var pending = String.UnicodeScalarView()

        func flushPending() {
            guard !pending.isEmpty else { return }
            let s = String(pending)
            pending.removeAll(keepingCapacity: true)
            out.append(NSAttributedString(
                string: s,
                attributes: attributes(style, defaultColor: defaultColor, font: font)
            ))
        }

        while i < scalars.endIndex {
            let sc = scalars[i]
            if sc == "\u{1B}" {
                flushPending()
                let next = scalars.index(after: i)
                if next >= scalars.endIndex { break }
                let kind = scalars[next]
                if kind == "[" {
                    // CSI: params + intermediate until a final byte (0x40..0x7E)
                    var cursor = scalars.index(after: next)
                    var params = String.UnicodeScalarView()
                    var finalByte: Unicode.Scalar = "m"
                    while cursor < scalars.endIndex {
                        let c = scalars[cursor]
                        if c.value >= 0x40 && c.value <= 0x7E {
                            finalByte = c
                            cursor = scalars.index(after: cursor)
                            break
                        }
                        params.append(c)
                        cursor = scalars.index(after: cursor)
                    }
                    if finalByte == "m" {
                        applySGR(params: String(params), style: &style, defaultColor: defaultColor)
                    }
                    // Non-SGR CSI is silently dropped.
                    i = cursor
                } else if kind == "]" {
                    // OSC — skip until BEL (0x07) or ST (ESC \).
                    var cursor = scalars.index(after: next)
                    while cursor < scalars.endIndex {
                        let c = scalars[cursor]
                        if c == "\u{07}" {
                            cursor = scalars.index(after: cursor)
                            break
                        }
                        if c == "\u{1B}" {
                            let n = scalars.index(after: cursor)
                            if n < scalars.endIndex && scalars[n] == "\\" {
                                cursor = scalars.index(after: n)
                                break
                            }
                        }
                        cursor = scalars.index(after: cursor)
                    }
                    i = cursor
                } else {
                    // Bare ESC + unknown — drop both bytes to avoid noise.
                    i = scalars.index(after: next)
                }
            } else {
                pending.append(sc)
                i = scalars.index(after: i)
            }
        }

        flushPending()
        return out
    }

    // MARK: - SGR

    private static func applySGR(
        params: String,
        style: inout Style,
        defaultColor: NSColor
    ) {
        let codes: [Int] = params.isEmpty
            ? [0]
            : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }

        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0:
                style = Style(fg: defaultColor, bg: nil, bold: false, italic: false, underline: false)
            case 1: style.bold = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.fg = ansi16(code - 30, bright: false)
            case 90...97: style.fg = ansi16(code - 90, bright: true)
            case 40...47: style.bg = ansi16(code - 40, bright: false)
            case 100...107: style.bg = ansi16(code - 100, bright: true)
            case 39: style.fg = defaultColor
            case 49: style.bg = nil
            case 38:
                // 38;5;N  or  38;2;R;G;B
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    style.fg = xterm256(codes[i + 2])
                    i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    style.fg = NSColor(
                        srgbRed: CGFloat(codes[i + 2]) / 255.0,
                        green: CGFloat(codes[i + 3]) / 255.0,
                        blue: CGFloat(codes[i + 4]) / 255.0,
                        alpha: 1.0
                    )
                    i += 4
                }
            case 48:
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    style.bg = xterm256(codes[i + 2])
                    i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    style.bg = NSColor(
                        srgbRed: CGFloat(codes[i + 2]) / 255.0,
                        green: CGFloat(codes[i + 3]) / 255.0,
                        blue: CGFloat(codes[i + 4]) / 255.0,
                        alpha: 1.0
                    )
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    // MARK: - Attributes

    private static func attributes(
        _ style: Style,
        defaultColor: NSColor,
        font: NSFont
    ) -> [NSAttributedString.Key: Any] {
        let size = font.pointSize
        let resolved: NSFont
        if style.bold && style.italic {
            resolved = NSFontManager.shared
                .font(withFamily: font.familyName ?? "Menlo",
                      traits: [.boldFontMask, .italicFontMask],
                      weight: 5, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        } else if style.bold {
            resolved = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        } else if style.italic {
            resolved = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        } else {
            resolved = font
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: style.fg,
            .font: resolved,
        ]
        if let bg = style.bg { attrs[.backgroundColor] = bg }
        if style.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    // MARK: - Color tables

    private static func ansi16(_ n: Int, bright: Bool) -> NSColor {
        // Tuned for a dark log surface — roughly matches Ghostty's default
        // palette so the runner log "looks like" the terminal tab next to it.
        let normal: [NSColor] = [
            NSColor(srgbRed: 0.15, green: 0.15, blue: 0.15, alpha: 1),  // black
            NSColor(srgbRed: 0.88, green: 0.40, blue: 0.38, alpha: 1),  // red
            NSColor(srgbRed: 0.51, green: 0.79, blue: 0.38, alpha: 1),  // green
            NSColor(srgbRed: 0.90, green: 0.75, blue: 0.35, alpha: 1),  // yellow
            NSColor(srgbRed: 0.38, green: 0.62, blue: 0.95, alpha: 1),  // blue
            NSColor(srgbRed: 0.82, green: 0.50, blue: 0.86, alpha: 1),  // magenta
            NSColor(srgbRed: 0.38, green: 0.78, blue: 0.82, alpha: 1),  // cyan
            NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1),  // white
        ]
        let brightColors: [NSColor] = [
            NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.97, green: 0.55, blue: 0.53, alpha: 1),
            NSColor(srgbRed: 0.66, green: 0.90, blue: 0.50, alpha: 1),
            NSColor(srgbRed: 0.98, green: 0.85, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.52, green: 0.76, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 0.95, green: 0.65, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.52, green: 0.92, blue: 0.94, alpha: 1),
            NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        ]
        let table = bright ? brightColors : normal
        return n >= 0 && n < table.count ? table[n] : .gray
    }

    private static func xterm256(_ n: Int) -> NSColor {
        if n < 8 { return ansi16(n, bright: false) }
        if n < 16 { return ansi16(n - 8, bright: true) }
        if n < 232 {
            // 6x6x6 cube
            let idx = n - 16
            let r = idx / 36
            let g = (idx % 36) / 6
            let b = idx % 6
            let levels: [CGFloat] = [0.0, 0.37, 0.53, 0.69, 0.85, 1.0]
            return NSColor(srgbRed: levels[r], green: levels[g], blue: levels[b], alpha: 1)
        }
        // 232..255 — grayscale ramp
        let step = CGFloat(n - 232) / 23.0
        let level = 0.03 + step * 0.92
        return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
    }
}
