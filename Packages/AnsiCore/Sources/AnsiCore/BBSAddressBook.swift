import Foundation

/// How the terminal reaches a BBS: telnet (with option negotiation), a plain TCP byte stream,
/// SSH, a WebSocket (ws or wss) or RLogin (RFC 1282).
public enum ConnectionMode: String, Codable, CaseIterable {
    case telnet, raw, ssh, webSocket, rlogin

    public var label: String {
        switch self {
        case .telnet: return "Telnet"
        case .raw: return "Raw TCP"
        case .ssh: return "SSH"
        case .webSocket: return "WebSocket"
        case .rlogin: return "RLogin"
        }
    }

    /// The usual port: 23 telnet and raw, 22 SSH, 80 WebSocket (443 with TLS), 513 RLogin.
    public func defaultPort(secure: Bool = false) -> Int {
        switch self {
        case .telnet, .raw: return 23
        case .ssh: return 22
        case .webSocket: return secure ? 443 : 80
        case .rlogin: return 513
        }
    }
}

/// Whether a BBS plays the dial and handshake sound while connecting.
public enum ModemSoundChoice: String, Codable, CaseIterable {
    /// Follows Playback > Modem Sounds.
    case playbackSetting, on, off

    public var label: String {
        switch self {
        case .playbackSetting: return "Same as Playback > Modem Sounds"
        case .on: return "On"
        case .off: return "Off"
        }
    }
}

/// One saved BBS in the dialing directory. Passwords are never stored here: they live in the
/// Keychain under `credentialKey`.
public struct BBSEntry: Codable, Equatable, Identifiable {
    public static let defaultBusyText = "all nodes are busy|nodes are busy|no free nodes|system is busy"

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    /// Typed by Terminal > Send Username and by the login script.
    public var username: String?
    /// A bundled font (`BitmapFont.supportedNames`).
    public var fontName: String
    public var columns: Int
    public var rows: Int
    public var encoding: TextEncoding
    public var mode: ConnectionMode
    /// Received bytes are shown at this modem speed; 0 is unlimited.
    public var baud: Int
    public var backspaceSendsDelete: Bool
    public var notes: String
    /// Groups such as "Favourites" or "Trade Wars games".
    public var tags: [String]
    public var lastCalled: Date?
    public var totalCalls: Int
    /// Starts a capture into `captureFolderBookmark` as soon as the BBS answers.
    public var captureOnConnect: Bool
    /// A security scoped bookmark to the capture folder (only valid on this Mac).
    public var captureFolderBookmark: Data?
    public var captureFolderName: String?
    public var modemSound: ModemSoundChoice
    /// Option-1 ... Option-0 (`MacroSet.slotCount` strings, empty means unset), with `MacroText` escapes.
    public var macros: [String]
    /// Runs `loginScript` when the BBS answers (and a username is set).
    public var autoLogin: Bool
    public var loginScript: [LoginStep]
    /// Text that means the BBS is full (`|` between alternatives); seeing it soon after connecting hangs up.
    public var busyText: String
    /// Sent first when the BBS asks for the terminal type (telnet TERMINAL-TYPE).
    public var terminalType: String
    /// Shows the blink attribute as a bright background (iCE colours) instead of blinking text.
    public var iceColors: Bool
    /// SSH: a security scoped bookmark to the private key file (only valid on this Mac).
    public var sshKeyBookmark: Data?
    /// SSH: the key file's name, shown in the editor.
    public var sshKeyName: String?
    /// SSH: saves a host key seen for the first time without asking. A changed key is still refused.
    public var sshTrustNewHostKey: Bool
    /// WebSocket: the URL path, such as / or /ws.
    public var webSocketPath: String
    /// WebSocket: wss (TLS) instead of ws.
    public var webSocketSecure: Bool
    /// WebSocket: subprotocols for Sec-WebSocket-Protocol, separated by commas (empty sends none).
    public var webSocketSubprotocols: String
    /// WebSocket: the stream carries telnet (a telnet bridge), so telnet negotiation runs inside it.
    public var webSocketTelnet: Bool
    /// RLogin: the client user name; empty sends the username.
    public var rloginClientUser: String
    /// RLogin: the server user name; empty sends the username.
    public var rloginServerUser: String

    public static let standardTerminalTypes = ["ANSI", "ANSI-BBS", "VT100"]

    /// The names offered in the TERMINAL-TYPE cycle: the entry's choice first, then the standard ones.
    public var terminalTypes: [String] {
        let first = terminalType.trimmingCharacters(in: .whitespaces)
        let rest = Self.standardTerminalTypes.filter { $0.caseInsensitiveCompare(first) != .orderedSame }
        return first.isEmpty ? Self.standardTerminalTypes : [first] + rest
    }

    public init(name: String, host: String, port: Int = 23) {
        id = UUID()
        self.name = name
        self.host = host
        self.port = port
        fontName = "IBM VGA"
        columns = 80
        rows = 25
        encoding = .cp437
        mode = .telnet
        baud = 0
        backspaceSendsDelete = false
        notes = ""
        tags = []
        lastCalled = nil
        totalCalls = 0
        captureOnConnect = false
        captureFolderBookmark = nil
        captureFolderName = nil
        modemSound = .playbackSetting
        macros = Array(repeating: "", count: MacroSet.slotCount)
        autoLogin = true
        loginScript = LoginScript.defaultSteps
        busyText = Self.defaultBusyText
        terminalType = "ANSI"
        iceColors = false
        sshKeyBookmark = nil
        sshKeyName = nil
        sshTrustNewHostKey = false
        webSocketPath = "/"
        webSocketSecure = false
        webSocketSubprotocols = ""
        webSocketTelnet = false
        rloginClientUser = ""
        rloginServerUser = ""
    }

    public var address: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The Keychain key for this entry's SSH key file passphrase; nil without a username.
    public var sshPassphraseKey: CredentialKey? {
        guard let username, !username.isEmpty, !host.isEmpty else { return nil }
        return CredentialKey(host: host, port: port, account: "ssh-key-passphrase:" + username)
    }

    /// The Keychain key for this entry's password; nil without a username.
    public var credentialKey: CredentialKey? {
        guard let username, !username.isEmpty, !host.isEmpty else { return nil }
        return CredentialKey(host: host, port: port, account: username)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, fontName, columns, rows, encoding, mode, baud, backspaceSendsDelete
        case notes, tags, lastCalled, totalCalls, captureOnConnect, captureFolderBookmark, captureFolderName
        case modemSound, macros, autoLogin, loginScript, busyText, terminalType, iceColors
        case sshKeyBookmark, sshKeyName, sshTrustNewHostKey, webSocketPath, webSocketSecure, webSocketSubprotocols
        case webSocketTelnet, rloginClientUser, rloginServerUser
    }

    /// Missing or out of range fields fall back to the defaults, so older (plan 7) or hand edited books load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), host: try c.decode(String.self, forKey: .host))
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        if let port = try? c.decode(Int.self, forKey: .port), (1...65535).contains(port) { self.port = port }
        username = try? c.decode(String.self, forKey: .username)
        if let font = try? c.decode(String.self, forKey: .fontName) { fontName = font }
        if let value = try? c.decode(Int.self, forKey: .columns) { columns = Self.clampSize(value) }
        if let value = try? c.decode(Int.self, forKey: .rows) { rows = Self.clampSize(value) }
        if let value = try? c.decode(TextEncoding.self, forKey: .encoding) { encoding = value }
        if let value = try? c.decode(ConnectionMode.self, forKey: .mode) { mode = value }
        if let value = try? c.decode(Int.self, forKey: .baud), value >= 0 { baud = value }
        if let value = try? c.decode(Bool.self, forKey: .backspaceSendsDelete) { backspaceSendsDelete = value }
        if let value = try? c.decode(String.self, forKey: .notes) { notes = value }
        if let value = try? c.decode([String].self, forKey: .tags) { tags = value }
        lastCalled = try? c.decode(Date.self, forKey: .lastCalled)
        if let value = try? c.decode(Int.self, forKey: .totalCalls), value >= 0 { totalCalls = value }
        if let value = try? c.decode(Bool.self, forKey: .captureOnConnect) { captureOnConnect = value }
        captureFolderBookmark = try? c.decode(Data.self, forKey: .captureFolderBookmark)
        captureFolderName = try? c.decode(String.self, forKey: .captureFolderName)
        if let value = try? c.decode(ModemSoundChoice.self, forKey: .modemSound) { modemSound = value }
        if let value = try? c.decode([String].self, forKey: .macros) {
            macros = Array((value + Array(repeating: "", count: MacroSet.slotCount)).prefix(MacroSet.slotCount))
        }
        if let value = try? c.decode(Bool.self, forKey: .autoLogin) { autoLogin = value }
        if let value = try? c.decode([LoginStep].self, forKey: .loginScript) { loginScript = value }
        if let value = try? c.decode(String.self, forKey: .busyText) { busyText = value }
        if let value = try? c.decode(String.self, forKey: .terminalType), !value.isEmpty { terminalType = value }
        if let value = try? c.decode(Bool.self, forKey: .iceColors) { iceColors = value }
        sshKeyBookmark = try? c.decode(Data.self, forKey: .sshKeyBookmark)
        sshKeyName = try? c.decode(String.self, forKey: .sshKeyName)
        if let value = try? c.decode(Bool.self, forKey: .sshTrustNewHostKey) { sshTrustNewHostKey = value }
        if let value = try? c.decode(String.self, forKey: .webSocketPath), !value.isEmpty { webSocketPath = value }
        if let value = try? c.decode(Bool.self, forKey: .webSocketSecure) { webSocketSecure = value }
        if let value = try? c.decode(String.self, forKey: .webSocketSubprotocols) { webSocketSubprotocols = value }
        if let value = try? c.decode(Bool.self, forKey: .webSocketTelnet) { webSocketTelnet = value }
        if let value = try? c.decode(String.self, forKey: .rloginClientUser) { rloginClientUser = value }
        if let value = try? c.decode(String.self, forKey: .rloginServerUser) { rloginServerUser = value }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encode(fontName, forKey: .fontName)
        try c.encode(columns, forKey: .columns)
        try c.encode(rows, forKey: .rows)
        try c.encode(encoding, forKey: .encoding)
        try c.encode(mode, forKey: .mode)
        try c.encode(baud, forKey: .baud)
        try c.encode(backspaceSendsDelete, forKey: .backspaceSendsDelete)
        try c.encode(notes, forKey: .notes)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(lastCalled, forKey: .lastCalled)
        try c.encode(totalCalls, forKey: .totalCalls)
        try c.encode(captureOnConnect, forKey: .captureOnConnect)
        try c.encodeIfPresent(captureFolderBookmark, forKey: .captureFolderBookmark)
        try c.encodeIfPresent(captureFolderName, forKey: .captureFolderName)
        try c.encode(modemSound, forKey: .modemSound)
        try c.encode(macros, forKey: .macros)
        try c.encode(autoLogin, forKey: .autoLogin)
        try c.encode(loginScript, forKey: .loginScript)
        try c.encode(busyText, forKey: .busyText)
        try c.encode(terminalType, forKey: .terminalType)
        try c.encode(iceColors, forKey: .iceColors)
        try c.encodeIfPresent(sshKeyBookmark, forKey: .sshKeyBookmark)
        try c.encodeIfPresent(sshKeyName, forKey: .sshKeyName)
        try c.encode(sshTrustNewHostKey, forKey: .sshTrustNewHostKey)
        try c.encode(webSocketPath, forKey: .webSocketPath)
        try c.encode(webSocketSecure, forKey: .webSocketSecure)
        try c.encode(webSocketSubprotocols, forKey: .webSocketSubprotocols)
        try c.encode(webSocketTelnet, forKey: .webSocketTelnet)
        try c.encode(rloginClientUser, forKey: .rloginClientUser)
        try c.encode(rloginServerUser, forKey: .rloginServerUser)
    }

    private static func clampSize(_ value: Int) -> Int {
        min(TerminalEmulator.sizeRange.upperBound, max(TerminalEmulator.sizeRange.lowerBound, value))
    }
}

/// The plan 7 address book: a JSON array of entries under `bbsAddressBook`. Kept so old data
/// migrates into `DialingDirectory` (and a downgraded app still finds its book).
public struct BBSAddressBook: Equatable {
    public static let defaultsKey = "bbsAddressBook"
    public var entries: [BBSEntry]

    public init(entries: [BBSEntry] = []) {
        self.entries = entries
    }

    /// Anything unreadable gives an empty book.
    public init(data: Data?) {
        entries = data.flatMap { try? JSONDecoder().decode([BBSEntry].self, from: $0) } ?? []
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
    }
}

/// Reads an address typed by the user: `host`, `host:port`, `telnet://host:port/`, `[v6]:port`.
public enum BBSAddress {
    public static func parse(_ text: String, defaultPort: Int = 23) -> (host: String, port: Int)? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["telnet://"] where s.lowercased().hasPrefix(scheme) {
            s.removeFirst(scheme.count)
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        var host = s
        var portText: String?
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.hasPrefix(":") { portText = String(rest.dropFirst()) } else if !rest.isEmpty { return nil }
        } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            host = String(s[..<colon])
            portText = String(s[s.index(after: colon)...])
        }
        guard !host.isEmpty else { return nil }
        var port = defaultPort
        if let portText {
            guard let value = Int(portText), (1...65535).contains(value) else { return nil }
            port = value
        }
        return (host, port)
    }
}
