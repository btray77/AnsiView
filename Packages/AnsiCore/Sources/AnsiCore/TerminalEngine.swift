import CoreGraphics

/// One live BBS screen of any emulation: bytes in, a screen of cells out, keys turned into the
/// bytes that platform's keyboard sent. Every engine keeps its parser state between `feed` calls,
/// so sequences split across network packets work.
public protocol TerminalEngine {
    var columns: Int { get }
    var rows: Int { get }
    /// Zero based.
    var cursor: (row: Int, column: Int) { get }
    var cursorVisible: Bool { get }
    /// Increases whenever anything visible may have changed.
    var changeCount: Int { get }
    /// BEL (or the platform's bell) characters received.
    var bells: Int { get }
    var scrollbackCount: Int { get }
    /// The font this platform draws with; nil uses the entry's font.
    var font: BitmapFont? { get }
    /// How much wider than its font pixels the screen is shown (teletext filled a 4:3 television).
    var horizontalStretch: Double { get }

    mutating func feed(_ bytes: [UInt8])
    /// Bytes the terminal must send back (status reports), cleared by the call.
    mutating func takeReplies() -> [UInt8]
    mutating func resize(columns: Int, rows: Int)
    mutating func clearScrollback()
    /// Exactly `rows` rows: the live screen or `scrollOffset` lines back.
    func screen(scrollOffset: Int) -> AnsiScreen

    /// A key as this platform's keyboard sent it.
    func bytes(for key: TerminalKey, backspaceSendsDelete: Bool) -> [UInt8]
    /// Typed or pasted text in this platform's character set.
    func text(_ text: String, encoding: TextEncoding) -> [UInt8]
    /// Control plus a key; nil when the platform has no such code.
    func control(_ character: Character) -> [UInt8]?
    /// A picture drawn under the text (RIPscrip), in the screen's pixel size; nil for text only.
    func overlay() -> CGImage?
    /// A mouse click at a position in the overlay's pixels: the bytes to send (RIP buttons).
    mutating func click(x: Int, y: Int) -> [UInt8]
}

public extension TerminalEngine {
    var font: BitmapFont? { nil }
    var horizontalStretch: Double { 1 }
    func bytes(for key: TerminalKey, backspaceSendsDelete: Bool) -> [UInt8] {
        TerminalInput.bytes(for: key, backspaceSendsDelete: backspaceSendsDelete)
    }
    func text(_ text: String, encoding: TextEncoding) -> [UInt8] { TerminalInput.text(text, encoding: encoding) }
    func control(_ character: Character) -> [UInt8]? { TerminalInput.control(character) }
    func overlay() -> CGImage? { nil }
    mutating func click(x: Int, y: Int) -> [UInt8] { [] }
}

extension TerminalEmulator: TerminalEngine {
    public var scrollbackCount: Int { scrollback.count }
    /// Amiga boards draw with the Topaz style font; the others use the entry's font.
    public var font: BitmapFont? { profile == .amiga ? PlatformFonts.topaz : nil }
}

public enum TerminalEngines {
    /// A fresh engine for an emulation and screen size.
    public static func make(_ emulation: TerminalEmulation, columns: Int, rows: Int, encoding: TextEncoding,
                            iceColors: Bool) -> any TerminalEngine {
        switch emulation {
        case .avatar:
            var a = AvatarTerminal(columns: columns, rows: rows, encoding: encoding)
            a.iceColors = iceColors
            return a
        case .petscii64: return PETSCIITerminal(model: .c64, columns: columns, rows: rows)
        case .petscii128: return PETSCIITerminal(model: .c128, columns: columns, rows: rows)
        case .atascii: return ATASCIITerminal(columns: columns, rows: rows)
        case .appleII: return AppleIITerminal(columns: columns, rows: rows)
        case .ripscrip: return RIPTerminal(columns: columns, rows: rows, encoding: encoding)
        case .viewdata: return TeletextTerminal(flavour: .viewdata, columns: columns, rows: rows)
        case .mode7: return TeletextTerminal(flavour: .mode7, columns: columns, rows: rows)
        default: break
        }
        var t = TerminalEmulator(columns: columns, rows: rows, encoding: encoding)
        t.iceColors = iceColors
        t.entryIceColors = iceColors
        switch emulation {
        case .vt100: t.profile = .vt100
        case .vt220: t.profile = .vt220
        case .amiga: t.profile = .amiga
        default: break
        }
        return t
    }
}
