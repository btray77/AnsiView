/// Translates BBS specific color code formats into ANSI escape sequences, so they play
/// (and animate) through `AnsiTerminal` like any ANSI file.
public enum BBSCodes {
    /// Upper bound on translated output, so repeat commands cannot expand without limit.
    public static let maxOutputBytes = 8_000_000

    private static let escape: [UInt8] = [0x1B, 0x5B]

    /// PCBoard: "@Xbf" sets background b and foreground f (hex); "@CLS@" clears the screen.
    public static func pcboardToANSI(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x40, i + 3 < bytes.count, bytes[i + 1] == 0x58,
               let bg = hex(bytes[i + 2]), let fg = hex(bytes[i + 3]) {
                out += sgr(attribute: UInt8(bg << 4 | fg))
                i += 4
            } else if bytes[i...].starts(with: Array("@CLS@".utf8)) {
                out += clearScreen
                i += 5
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    /// Wildcat: "@bf@" sets background b and foreground f (hex).
    public static func wildcatToANSI(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x40, i + 3 < bytes.count, bytes[i + 3] == 0x40,
               let bg = hex(bytes[i + 1]), let fg = hex(bytes[i + 2]) {
                out += sgr(attribute: UInt8(bg << 4 | fg))
                i += 4
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    /// Avatar level 0: ^L clear, ^Y c n repeat, and ^V commands for attributes and cursor movement.
    public static func avatarToANSI(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var attribute: UInt8 = 0x07
        var i = 0
        while i < bytes.count, out.count < maxOutputBytes {
            let b = bytes[i]
            // 0x1A is end of file only in text position; as a parameter it is an ordinary value.
            if b == 0x1A { break }
            if b == 0x0C {
                attribute = 0x03
                out += clearScreen + sgr(attribute: attribute)
                i += 1
            } else if b == 0x19, i + 2 < bytes.count {
                out += [UInt8](repeating: bytes[i + 1], count: min(Int(bytes[i + 2]), maxOutputBytes - out.count))
                i += 3
            } else if b == 0x16, i + 1 < bytes.count {
                let command = bytes[i + 1]
                switch command {
                case 0x01 where i + 2 < bytes.count:
                    attribute = bytes[i + 2] & 0x7F
                    out += sgr(attribute: attribute)
                    i += 3
                case 0x02:
                    attribute |= 0x80
                    out += sgr(attribute: attribute)
                    i += 2
                case 0x03, 0x04, 0x05, 0x06:
                    // Up, down, left, right.
                    out += escape + [UInt8(ascii: "1")] + [Array("ABDC".utf8)[Int(command) - 3]]
                    i += 2
                case 0x07:
                    out += escape + [UInt8(ascii: "K")]
                    i += 2
                case 0x08 where i + 3 < bytes.count:
                    out += escape + Array("\(bytes[i + 2]);\(bytes[i + 3])H".utf8)
                    i += 4
                default:
                    out.append(b)
                    i += 1
                }
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    // MARK: Helpers

    private static let clearScreen: [UInt8] = [0x1B, 0x5B, 0x32, 0x4A, 0x1B, 0x5B, 0x48]

    private static func hex(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }

    /// SGR for a DOS attribute byte: low nibble foreground, bits 4-6 background, bit 7 blink.
    static func sgr(attribute: UInt8) -> [UInt8] {
        let fg = Int(attribute & 0x0F), bg = Int((attribute >> 4) & 0x07)
        var codes = ["0"]
        if fg >= 8 { codes.append("1") }
        if attribute & 0x80 != 0 { codes.append("5") }
        // VGA attribute order and ANSI order swap red and blue; the mapping is its own inverse.
        codes.append("3\(Palette.ansiToVGA[fg & 7])")
        codes.append("4\(Palette.ansiToVGA[bg])")
        return escape + Array((codes.joined(separator: ";") + "m").utf8)
    }
}
