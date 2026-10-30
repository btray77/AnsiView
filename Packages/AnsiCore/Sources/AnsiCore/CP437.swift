/// Code page 437 to Unicode, including the graphic glyphs DOS shows for control codes.
public enum CP437 {
    public static let unicode: [Unicode.Scalar] = Array((
        "\u{0020}☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼"
        + " !\"#$%&'()*+,-./0123456789:;<=>?"
        + "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_"
        + "`abcdefghijklmnopqrstuvwxyz{|}~⌂"
        + "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒ"
        + "áíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐"
        + "└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀"
        + "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}"
    ).unicodeScalars)

    private static let reverse: [Unicode.Scalar: UInt8] = {
        var map: [Unicode.Scalar: UInt8] = [:]
        for (code, scalar) in unicode.enumerated() { map[scalar] = UInt8(code) }
        return map
    }()

    /// The CP437 code that displays `scalar`, if there is one.
    public static func code(for scalar: Unicode.Scalar) -> UInt8? {
        reverse[scalar]
    }

    /// `text` as CP437 bytes, space padded or cut to `length`; unmappable characters become "?".
    public static func bytes(_ text: String, length: Int) -> [UInt8] {
        var out = text.unicodeScalars.prefix(length).map { code(for: $0) ?? 0x3F }
        if out.count < length { out += Array(repeating: 0x20, count: length - out.count) }
        return out
    }
}
