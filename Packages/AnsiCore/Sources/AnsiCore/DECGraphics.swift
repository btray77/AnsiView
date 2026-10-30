/// The DEC Special Graphics set (ESC ( 0), bytes 0x5F to 0x7E: line drawing and symbols. Each maps
/// to its CP437 glyph where one exists, or to a Unicode scalar drawn from the system font.
enum DECGraphics {
    static func map(_ code: UInt8) -> (code: UInt8, scalar: Unicode.Scalar?)? {
        guard (0x5F...0x7E).contains(code) else { return nil }
        let entry = table[Int(code) - 0x5F]
        if entry.cp437 != 0 { return (entry.cp437, nil) }
        return (0x3F, entry.scalar)
    }

    private static let table: [(cp437: UInt8, scalar: Unicode.Scalar)] = [
        (0x20, " "), (0x04, "\u{25C6}"), (0xB1, "\u{2592}"), (0, "\u{2409}"), (0, "\u{240C}"), (0, "\u{240D}"),
        (0, "\u{240A}"), (0xF8, "\u{00B0}"), (0xF1, "\u{00B1}"), (0, "\u{2424}"), (0, "\u{240B}"), (0xD9, "\u{2518}"),
        (0xBF, "\u{2510}"), (0xDA, "\u{250C}"), (0xC0, "\u{2514}"), (0xC5, "\u{253C}"), (0, "\u{23BA}"), (0, "\u{23BB}"),
        (0xC4, "\u{2500}"), (0, "\u{23BC}"), (0, "\u{23BD}"), (0xC3, "\u{251C}"), (0xB4, "\u{2524}"), (0xC1, "\u{2534}"),
        (0xC2, "\u{252C}"), (0xB3, "\u{2502}"), (0xF3, "\u{2264}"), (0xF2, "\u{2265}"), (0xE3, "\u{03C0}"), (0, "\u{2260}"),
        (0x9C, "\u{00A3}"), (0xFA, "\u{00B7}"),
    ]
}
