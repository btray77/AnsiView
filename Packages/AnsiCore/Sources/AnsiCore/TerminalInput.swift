/// A key a BBS terminal sends as a control code or escape sequence.
public enum TerminalKey: Equatable {
    case returnKey, backspace, tab, escape
    case up, down, right, left
    case home, end, pageUp, pageDown, insert, forwardDelete
    /// F1 to F12.
    case function(Int)
}

/// Turns keys and text into the bytes a BBS expects (ANSI-BBS cursor keys, VT220 editing keys).
public enum TerminalInput {
    public static func bytes(for key: TerminalKey, backspaceSendsDelete: Bool) -> [UInt8] {
        func csi(_ tail: String) -> [UInt8] { [0x1B, 0x5B] + Array(tail.utf8) }
        switch key {
        // CR alone; the telnet layer sends it as CR NUL outside BINARY mode.
        case .returnKey: return [13]
        case .backspace: return [backspaceSendsDelete ? 127 : 8]
        case .tab: return [9]
        case .escape: return [27]
        case .up: return csi("A")
        case .down: return csi("B")
        case .right: return csi("C")
        case .left: return csi("D")
        case .home: return csi("1~")
        case .insert: return csi("2~")
        case .forwardDelete: return csi("3~")
        case .end: return csi("4~")
        case .pageUp: return csi("5~")
        case .pageDown: return csi("6~")
        case .function(let n):
            switch n {
            case 1...4: return [0x1B, 0x4F, 0x50 + UInt8(n - 1)]
            case 5...12:
                let codes = [15, 17, 18, 19, 20, 21, 23, 24]
                return csi("\(codes[n - 5])~")
            default: return []
            }
        }
    }

    /// Typed or pasted text in the BBS's encoding. Line breaks become CR (Return); characters
    /// CP437 cannot show are dropped.
    public static func text(_ text: String, encoding: TextEncoding) -> [UInt8] {
        var out: [UInt8] = []
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if !previousCR { out.append(13) }
                previousCR = false
                continue
            }
            previousCR = scalar == "\r"
            if previousCR { out.append(13); continue }
            switch encoding {
            case .utf8: out += Array(String(Character(scalar)).utf8)
            case .cp437:
                if scalar.value < 0x80 {
                    out.append(UInt8(scalar.value))
                } else if let code = CP437.code(for: scalar) {
                    out.append(code)
                }
            }
        }
        return out
    }

    /// Control plus a letter (or one of @ [ \ ] ^ _): the matching control code.
    public static func control(_ character: Character) -> [UInt8]? {
        guard let ascii = character.uppercased().first?.asciiValue, (0x40...0x5F).contains(ascii) else { return nil }
        return [ascii - 0x40]
    }
}
