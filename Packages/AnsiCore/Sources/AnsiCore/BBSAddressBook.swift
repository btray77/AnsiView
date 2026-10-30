import Foundation

/// Telnet (with option negotiation) or a plain TCP byte stream.
public enum ConnectionMode: String, Codable, CaseIterable {
    case telnet, raw

    public var label: String { self == .telnet ? "Telnet" : "Raw TCP" }
}

/// One saved BBS. Passwords are never stored.
public struct BBSEntry: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    /// Typed by Terminal > Send Username.
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
    }

    public var address: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, fontName, columns, rows, encoding, mode, baud, backspaceSendsDelete
    }

    /// Missing or out of range fields fall back to the defaults, so older or hand edited books load.
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
    }

    private static func clampSize(_ value: Int) -> Int {
        min(TerminalEmulator.sizeRange.upperBound, max(TerminalEmulator.sizeRange.lowerBound, value))
    }
}

/// The saved BBS list, stored as JSON in the app's user defaults.
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
