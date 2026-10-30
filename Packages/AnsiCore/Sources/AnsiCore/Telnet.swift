/// The telnet options AnsiView negotiates. Every other option is refused.
public enum TelnetOption: UInt8, CaseIterable {
    case binary = 0
    case echo = 1
    case suppressGoAhead = 3
    case terminalType = 24
    case naws = 31
}

/// The telnet protocol (RFC 854 and the option RFCs) as a pure state machine: bytes from the
/// server go in, decoded data and the replies to send come out. No I/O happens here.
///
/// The server may enable BINARY, ECHO and SUPPRESS-GO-AHEAD on its side; this side offers
/// BINARY, SUPPRESS-GO-AHEAD, TERMINAL-TYPE and NAWS. Requests that match the current state get
/// no reply and answers to our own requests are not answered, so negotiation cannot loop.
public struct TelnetSession {
    public static let IAC: UInt8 = 255, DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252
    public static let WILL: UInt8 = 251, SB: UInt8 = 250, SE: UInt8 = 240
    /// Longest subnegotiation kept; longer ones are discarded (a broken or hostile server).
    public static let maxSubnegotiation = 512

    private static let remoteOptions: Set<UInt8> = [0, 1, 3]
    private static let localOptions: Set<UInt8> = [0, 3, 24, 31]

    private struct OptionState {
        var enabled = false
        var asked = false
    }

    private enum State { case data, iac, verb(UInt8), sb, sbIAC }

    public let terminalTypes: [String]
    public private(set) var columns: Int
    public private(set) var rows: Int

    private var local: [UInt8: OptionState] = [:]
    private var remote: [UInt8: OptionState] = [:]
    private var state = State.data
    private var subnegotiation: [UInt8] = []
    private var subnegotiationOverflow = false
    private var lastDataWasCR = false
    private var terminalTypeIndex = 0

    public init(columns: Int, rows: Int, terminalTypes: [String] = ["ANSI", "ANSI-BBS", "VT100"]) {
        self.columns = columns
        self.rows = rows
        self.terminalTypes = terminalTypes.isEmpty ? ["ANSI"] : terminalTypes
    }

    public func localEnabled(_ option: TelnetOption) -> Bool { local[option.rawValue]?.enabled ?? false }
    public func remoteEnabled(_ option: TelnetOption) -> Bool { remote[option.rawValue]?.enabled ?? false }

    /// The opening requests: DO SUPPRESS-GO-AHEAD, WILL TERMINAL-TYPE, WILL NAWS.
    public mutating func start() -> [UInt8] {
        remote[TelnetOption.suppressGoAhead.rawValue, default: OptionState()].asked = true
        local[TelnetOption.terminalType.rawValue, default: OptionState()].asked = true
        local[TelnetOption.naws.rawValue, default: OptionState()].asked = true
        return [Self.IAC, Self.DO, 3, Self.IAC, Self.WILL, 24, Self.IAC, Self.WILL, 31]
    }

    /// Decodes bytes from the server. The state carries over, so a command may be split anywhere.
    public mutating func receive(_ bytes: [UInt8]) -> (data: [UInt8], reply: [UInt8]) {
        var data: [UInt8] = []
        var reply: [UInt8] = []
        data.reserveCapacity(bytes.count)
        for byte in bytes {
            switch state {
            case .data:
                if byte == Self.IAC {
                    state = .iac
                } else if byte == 0, lastDataWasCR, !remoteEnabled(.binary) {
                    lastDataWasCR = false
                } else {
                    data.append(byte)
                    lastDataWasCR = byte == 13
                }
            case .iac:
                switch byte {
                case Self.IAC:
                    data.append(255)
                    lastDataWasCR = false
                    state = .data
                case Self.WILL, Self.WONT, Self.DO, Self.DONT:
                    state = .verb(byte)
                case Self.SB:
                    subnegotiation.removeAll(keepingCapacity: true)
                    subnegotiationOverflow = false
                    state = .sb
                default:
                    // NOP, GA, AYT, DM, BRK and the rest carry nothing a terminal shows.
                    state = .data
                }
            case .verb(let verb):
                negotiate(verb, byte, reply: &reply)
                state = .data
            case .sb:
                if byte == Self.IAC { state = .sbIAC } else { appendSubnegotiation(byte) }
            case .sbIAC:
                if byte == Self.SE {
                    if !subnegotiationOverflow { reply += handleSubnegotiation() }
                    state = .data
                } else {
                    // IAC IAC inside a subnegotiation is a data 255; anything else is malformed.
                    if byte == Self.IAC { appendSubnegotiation(255) }
                    state = .sb
                }
            }
        }
        return (data, reply)
    }

    /// Outgoing data: 255 doubled, and CR not followed by LF sent as CR NUL unless our side is BINARY.
    public func encode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        let binary = localEnabled(.binary)
        for (index, byte) in bytes.enumerated() {
            out.append(byte)
            if byte == Self.IAC {
                out.append(Self.IAC)
            } else if byte == 13, !binary, index + 1 >= bytes.count || bytes[index + 1] != 10 {
                out.append(0)
            }
        }
        return out
    }

    /// Records a new terminal size; returns the NAWS report to send when NAWS is on.
    public mutating func resize(columns: Int, rows: Int) -> [UInt8] {
        self.columns = columns
        self.rows = rows
        return localEnabled(.naws) ? windowSize() : []
    }

    // MARK: Negotiation

    private mutating func negotiate(_ verb: UInt8, _ option: UInt8, reply: inout [UInt8]) {
        switch verb {
        case Self.WILL:
            guard Self.remoteOptions.contains(option) else {
                reply += [Self.IAC, Self.DONT, option]
                return
            }
            var s = remote[option] ?? OptionState()
            if !s.enabled {
                if !s.asked { reply += [Self.IAC, Self.DO, option] }
                s.enabled = true
            }
            s.asked = false
            remote[option] = s
        case Self.WONT:
            var s = remote[option] ?? OptionState()
            if s.enabled, !s.asked { reply += [Self.IAC, Self.DONT, option] }
            s = OptionState()
            remote[option] = s
        case Self.DO:
            guard Self.localOptions.contains(option) else {
                reply += [Self.IAC, Self.WONT, option]
                return
            }
            var s = local[option] ?? OptionState()
            let turningOn = !s.enabled
            if turningOn, !s.asked { reply += [Self.IAC, Self.WILL, option] }
            s.enabled = true
            s.asked = false
            local[option] = s
            if turningOn {
                if option == TelnetOption.naws.rawValue { reply += windowSize() }
                if option == TelnetOption.terminalType.rawValue { terminalTypeIndex = 0 }
            }
        case Self.DONT:
            let s = local[option] ?? OptionState()
            if s.enabled, !s.asked { reply += [Self.IAC, Self.WONT, option] }
            local[option] = OptionState()
        default:
            break
        }
    }

    private mutating func appendSubnegotiation(_ byte: UInt8) {
        if subnegotiation.count < Self.maxSubnegotiation {
            subnegotiation.append(byte)
        } else {
            subnegotiationOverflow = true
        }
    }

    private mutating func handleSubnegotiation() -> [UInt8] {
        // TERMINAL-TYPE SEND: answer IS with the next name; the last one repeats (RFC 1091).
        guard subnegotiation.count >= 2, subnegotiation[0] == TelnetOption.terminalType.rawValue,
              subnegotiation[1] == 1, localEnabled(.terminalType) else { return [] }
        let name = terminalTypes[min(terminalTypeIndex, terminalTypes.count - 1)]
        terminalTypeIndex += 1
        return [Self.IAC, Self.SB, 24, 0] + Array(name.utf8) + [Self.IAC, Self.SE]
    }

    private func windowSize() -> [UInt8] {
        var out: [UInt8] = [Self.IAC, Self.SB, TelnetOption.naws.rawValue]
        for value in [columns, rows] {
            let clamped = UInt16(min(65535, max(0, value)))
            for byte in [UInt8(clamped >> 8), UInt8(clamped & 0xFF)] {
                out.append(byte)
                if byte == Self.IAC { out.append(Self.IAC) }
            }
        }
        return out + [Self.IAC, Self.SE]
    }
}
