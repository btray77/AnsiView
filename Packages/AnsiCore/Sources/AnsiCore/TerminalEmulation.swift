/// The kind of terminal a BBS expects: the PC ANSI-BBS norm, a DEC VT terminal, or a home computer
/// of the 1980s with its own character set and control codes. Chosen per dialing directory entry.
public enum TerminalEmulation: String, Codable, CaseIterable {
    case ansiBBS, vt100, vt220, avatar, ripscrip, petscii64, petscii128, atascii, viewdata, mode7, appleII, amiga

    public var label: String {
        switch self {
        case .ansiBBS: return "ANSI-BBS"
        case .vt100: return "VT100"
        case .vt220: return "VT220"
        case .avatar: return "Avatar (AVT/0+)"
        case .ripscrip: return "RIPscrip"
        case .petscii64: return "PETSCII (C64)"
        case .petscii128: return "PETSCII (C128 80 col)"
        case .atascii: return "ATASCII (Atari)"
        case .viewdata: return "Viewdata / Prestel"
        case .mode7: return "Mode 7 (BBC Micro)"
        case .appleII: return "Apple II"
        case .amiga: return "Amiga ANSI"
        }
    }

    /// The screen the platform had: 40x25 for the C64, 40x24 for Atari and Viewdata, and so on.
    public var defaultColumns: Int {
        switch self {
        case .petscii64, .atascii, .viewdata, .mode7: return 40
        default: return 80
        }
    }

    public var defaultRows: Int {
        switch self {
        case .vt100, .vt220, .atascii, .viewdata, .appleII: return 24
        case .amiga: return 25
        default: return 25
        }
    }

    /// Names offered in the telnet TERMINAL-TYPE cycle, the first one sent first. They follow the
    /// names SyncTERM and Synchronet use for each mode where one exists (docs/BBS-COMPAT.md).
    public var terminalNames: [String] {
        switch self {
        case .ansiBBS: return ["ANSI", "ANSI-BBS", "VT100"]
        case .vt100: return ["VT100", "VT102", "ANSI"]
        case .vt220: return ["VT220", "VT100", "ANSI"]
        case .avatar: return ["AVATAR", "ANSI"]
        case .ripscrip: return ["RIP", "ANSI"]
        case .petscii64: return ["PETSCII", "C64"]
        case .petscii128: return ["PETSCII", "C128"]
        case .atascii: return ["ATASCII", "ATARI"]
        case .viewdata: return ["PRESTEL", "VIEWDATA"]
        case .mode7: return ["BBC", "MODE7"]
        case .appleII: return ["APPLE2", "DUMB"]
        case .amiga: return ["AMIGA", "ANSI"]
        }
    }
}
