import Foundation

/// How an exported screen ends its lines.
public enum LineEnding: String, Codable, CaseIterable, Equatable {
    case crlf, lf

    public var label: String { self == .crlf ? "CR LF (DOS)" : "LF (Unix)" }
}

/// Character set and line ending conversion for exported screens.
public enum ScreenEncoding {
    /// CP437 bytes as UTF-8. Control bytes (below 0x20 and DEL) stay as they are, since they are
    /// commands (escape sequences, Ctrl-A codes, line ends), not the glyphs DOS draws for them.
    public static func utf8(fromCP437 bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 2)
        for b in bytes {
            if b < 0x80 {
                out.append(b)
            } else {
                out += Array(String(Character(CP437.unicode[Int(b)])).utf8)
            }
        }
        return out
    }

    /// Replaces each CR LF pair with the chosen ending. A lone CR (animation padding) is kept.
    public static func lineEndings(_ bytes: [UInt8], _ ending: LineEnding) -> [UInt8] {
        guard ending == .lf else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                out.append(0x0A)
                i += 2
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }
}
