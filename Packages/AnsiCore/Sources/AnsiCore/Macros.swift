import Foundation

/// Text typed by a keyboard macro or a login script `text` step, with escapes:
/// `\r` CR, `\n` LF, `\t` TAB, `\e` ESC, `\\` a backslash and `\xHH` any byte. An unknown or
/// incomplete escape is sent as typed. Other characters use the BBS's encoding, and a real line
/// break typed in the field is a CR (as Return would send).
public enum MacroText {
    public static func bytes(_ text: String, encoding: TextEncoding) -> [UInt8] {
        var out: [UInt8] = []
        var literal = ""
        func flush() {
            out += TerminalInput.text(literal, encoding: encoding)
            literal = ""
        }
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            guard scalar == "\\", i + 1 < scalars.count else {
                literal.unicodeScalars.append(scalar)
                i += 1
                continue
            }
            var byte: UInt8?
            var length = 2
            switch scalars[i + 1] {
            case "r": byte = 13
            case "n": byte = 10
            case "t": byte = 9
            case "e": byte = 27
            case "\\": byte = 92
            case "x":
                if i + 3 < scalars.count, let value = UInt8(String(String.UnicodeScalarView(scalars[(i + 2)...(i + 3)])), radix: 16) {
                    byte = value
                    length = 4
                }
            default: break
            }
            if let byte {
                flush()
                out.append(byte)
                i += length
            } else {
                literal.unicodeScalars.append(scalar)
                i += 1
            }
        }
        flush()
        return out
    }
}

/// The ten macro keys, Option-1 ... Option-9 then Option-0.
public enum MacroSet {
    public static let slotCount = 10

    /// The slot for a digit key, or nil.
    public static func slot(forDigit character: Character) -> Int? {
        guard let digit = character.wholeNumberValue, character.isASCII else { return nil }
        return digit == 0 ? 9 : digit - 1
    }

    public static func label(slot: Int) -> String {
        "Option-\(slot == 9 ? 0 : slot + 1)"
    }

    /// The entry's macro for `slot`, else the global one; nil when both are empty.
    public static func text(slot: Int, entry: BBSEntry, global: [String]) -> String? {
        guard (0..<slotCount).contains(slot) else { return nil }
        if slot < entry.macros.count, !entry.macros[slot].isEmpty { return entry.macros[slot] }
        if slot < global.count, !global[slot].isEmpty { return global[slot] }
        return nil
    }
}
