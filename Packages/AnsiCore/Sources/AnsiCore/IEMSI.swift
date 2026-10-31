/// Interactive EMSI (FSC-0056): a BBS that sends `**EMSI_IRQ` lets the caller's terminal log in by
/// sending an `**EMSI_ICI` packet with the user's name, password and terminal. Only used when an
/// entry turns IEMSI on and has a username and saved password.
public enum IEMSI {
    public struct Login: Equatable {
        public var name: String
        public var password: String
        public var rows: Int
        public var columns: Int
        /// AVT0, ANSI, VT100, VT52 or TTY.
        public var emulation: String

        public init(name: String, password: String, rows: Int, columns: Int, emulation: String) {
            self.name = name
            self.password = password
            self.rows = rows
            self.columns = columns
            self.emulation = emulation
        }
    }

    /// The IEMSI terminal name for an emulation.
    public static func crtName(_ emulation: TerminalEmulation) -> String {
        switch emulation {
        case .avatar: return "AVT0"
        case .vt100, .vt220: return "VT100"
        case .vt52: return "VT52"
        case .ansiBBS, .ripscrip, .amiga: return "ANSI"
        default: return "TTY"
        }
    }

    /// CRC-16/XMODEM (polynomial 0x1021, start 0), used by the fixed sequences.
    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// The ZMODEM CRC-32 register started at 0xFFFFFFFF and not inverted at the end (FSC-0056).
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc
    }

    /// A field in braces: `}` doubled, controls, 8-bit characters and `\` written as \XX (ISO 8859-1).
    public static func field(_ text: String) -> [UInt8] {
        var out: [UInt8] = [UInt8(ascii: "{")]
        for scalar in text.unicodeScalars {
            let value = scalar.value <= 0xFF ? UInt8(scalar.value) : UInt8(ascii: "?")
            switch value {
            case UInt8(ascii: "}"): out += [value, value]
            case UInt8(ascii: "\\"), 0x00...0x1F, 0x7F...0xFF: out += Array(String(format: "\\%02X", value).utf8)
            default: out.append(value)
            }
        }
        out.append(UInt8(ascii: "}"))
        return out
    }

    static func sequence(_ type: String) -> [UInt8] {
        let body = Array("EMSI_\(type)".utf8)
        return Array("**".utf8) + body + Array(String(format: "%04X", crc16(body)).utf8) + [0x0D]
    }

    /// The `**EMSI_ICI` packet for a login.
    public static func ici(_ login: Login) -> [UInt8] {
        var data: [UInt8] = []
        data += field(login.name)
        data += field(login.name)
        data += field("") + field("") + field("")
        data += field(login.password)
        data += field("")
        data += field("\(login.emulation),\(login.rows),\(login.columns),0")
        data += field("ZMO")
        data += field("")
        data += field("MORE")
        data += field("AnsiView,2.0,")
        data += field("")
        let body = Array("EMSI_ICI".utf8) + Array(String(format: "%04X", data.count).utf8) + data
        return Array("**".utf8) + body + Array(String(format: "%08X", crc32(body)).utf8) + [0x0D]
    }
}

/// The caller's side of the IEMSI handshake: answers the BBS's IRQ with ICI, resends on NAK (three
/// tries), acknowledges the ISI twice, and stops for good after that.
public struct IEMSIClient {
    public let login: IEMSI.Login
    private var window: [UInt8] = []
    private var sent = 0
    public private(set) var isFinished = false

    public init(login: IEMSI.Login) {
        self.login = login
    }

    /// Bytes from the BBS; returns what to send back.
    public mutating func feed(_ bytes: [UInt8]) -> [UInt8] {
        guard !isFinished else { return [] }
        var out: [UInt8] = []
        for b in bytes {
            window.append(b)
            if window.count > 32 { window.removeFirst(window.count - 32) }
            if ends(with: "**EMSI_IRQ8E08"), sent == 0 {
                out += IEMSI.ici(login)
                sent = 1
            } else if ends(with: "**EMSI_NAKEEC3"), sent > 0 {
                if sent >= 3 { isFinished = true; return out }
                out += IEMSI.ici(login)
                sent += 1
            } else if ends(with: "**EMSI_ISI"), sent > 0 {
                out += IEMSI.sequence("ACK") + IEMSI.sequence("ACK")
                isFinished = true
                return out
            }
        }
        return out
    }

    private func ends(with text: String) -> Bool {
        let tail = Array(text.utf8)
        return window.count >= tail.count && Array(window.suffix(tail.count)) == tail
    }
}
