/// Looks at the first bytes of a session for signs that the BBS expects another terminal type:
/// PETSCII clear screen and colour codes, ATASCII end of line codes, RIPscrip `!|` lines, Viewdata
/// ESC attributes or Avatar ^V commands. It only suggests (once); the terminal never switches by
/// itself. Once ANSI escape sequences are seen, nothing but RIPscrip is suggested.
public struct TerminalDetector {
    /// Bytes looked at before giving up.
    public static let window = 2048

    private var seen = 0
    private var previous: UInt8 = 0x0A
    private var lineStart = true
    private var ansi = false
    private var petscii = 0
    private var petsciiClear = false
    private var atasciiEOL = 0
    private var newlines = 0
    private var viewdataAttributes = 0
    private var avatarCommands = 0
    /// Words like "yOU" or "cOMMODORE": lower case set PETSCII text read as ASCII.
    private var swappedCaseWords = 0
    private var wordLetters: [UInt8] = []
    private var suggested = false

    public init() {}

    public var isFinished: Bool { suggested || seen >= Self.window }

    private static let petsciiCodes: Set<UInt8> = [0x93, 0x05, 0x1C, 0x1E, 0x1F, 0x81, 0x90, 0x95, 0x96, 0x97, 0x98, 0x99,
                                                   0x9A, 0x9B, 0x9C, 0x9E, 0x9F, 0x11, 0x91, 0x1D, 0x9D, 0x12, 0x92, 0x0E, 0x8E]

    /// Feeds received bytes; returns a suggestion the first time one is certain enough.
    public mutating func feed(_ bytes: [UInt8]) -> TerminalEmulation? {
        guard !isFinished else { return nil }
        var rip = false
        for b in bytes.prefix(Self.window - seen) {
            if b == UInt8(ascii: "|"), previous == UInt8(ascii: "!"), lineStart { rip = true }
            if previous == 0x1B {
                if b == UInt8(ascii: "[") { ansi = true } else if (0x40...0x5F).contains(b) { viewdataAttributes += 1 }
            }
            if previous == 0x16, (0x01...0x19).contains(b) { avatarCommands += 1 }
            if Self.petsciiCodes.contains(b) { petscii += 1 }
            if b == 0x93 { petsciiClear = true }
            if b == 0x9B { atasciiEOL += 1 }
            if b == 0x0D || b == 0x0A { newlines += 1 }
            if (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) {
                wordLetters.append(b)
            } else {
                if wordLetters.count >= 3, (0x61...0x7A).contains(wordLetters[0]),
                   wordLetters.dropFirst().allSatisfy({ (0x41...0x5A).contains($0) }) {
                    swappedCaseWords += 1
                }
                wordLetters.removeAll()
            }
            // `!|` counts at the start of a line (the `!` itself may follow a line break).
            if b != UInt8(ascii: "!") { lineStart = b == 0x0D || b == 0x0A }
            previous = b
        }
        seen += min(bytes.count, Self.window - seen)
        let suggestion = decide(rip: rip)
        if suggestion != nil { suggested = true }
        return suggestion
    }

    private func decide(rip: Bool) -> TerminalEmulation? {
        if rip { return .ripscrip }
        if ansi { return nil }
        if petsciiClear, petscii >= 3 { return .petscii64 }
        if swappedCaseWords >= 3 { return .petscii64 }
        if atasciiEOL >= 2 { return .atascii }
        if viewdataAttributes >= 3 { return .viewdata }
        if avatarCommands >= 2 { return .avatar }
        return nil
    }
}
