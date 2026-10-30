import Foundation

/// Reads a SyncTERM dialing directory (`syncterm.lst`): INI text with one `[Name]` section per
/// BBS and `Key=Value` lines (`Address`, `Port`, `ConnectionType`, `Username`, `Password`,
/// `Comment`, `BPSRate`, `ScreenMode`). Telnet and Raw entries import; other connection types
/// are listed in `skipped`. Passwords come back beside the entry, for the Keychain.
public enum SyncTermImport {
    public struct Imported: Equatable {
        public var entry: BBSEntry
        public var password: String?
    }

    public struct Result: Equatable {
        public var entries: [Imported] = []
        /// "Name (reason)" for each section not imported.
        public var skipped: [String] = []
    }

    public static func parse(_ text: String) -> Result {
        var sections: [(name: String, values: [String: String])] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces), [:]))
                continue
            }
            guard !sections.isEmpty, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            sections[sections.count - 1].values[key] = value
        }
        var result = Result()
        for (name, values) in sections {
            let type = values["connectiontype"] ?? "Telnet"
            let mode: ConnectionMode
            switch type.lowercased() {
            case "telnet": mode = .telnet
            case "raw": mode = .raw
            default:
                result.skipped.append("\(name) (\(type))")
                continue
            }
            guard let address = values["address"], !address.isEmpty,
                  let parsed = BBSAddress.parse(address) else {
                result.skipped.append("\(name) (no address)")
                continue
            }
            var entry = BBSEntry(name: name.isEmpty ? parsed.host : name, host: parsed.host, port: parsed.port)
            entry.mode = mode
            if let port = values["port"].flatMap(Int.init), (1...65535).contains(port) { entry.port = port }
            if let user = values["username"], !user.isEmpty { entry.username = user }
            if let comment = values["comment"] { entry.notes = comment }
            if let bps = values["bpsrate"].flatMap(Int.init), bps >= 0 { entry.baud = bps }
            if let mode = values["screenmode"], let size = screenSize(mode) {
                entry.columns = size.columns
                entry.rows = size.rows
            }
            let password = values["password"].flatMap { $0.isEmpty ? nil : $0 }
            result.entries.append(Imported(entry: entry, password: password))
        }
        return result
    }

    /// "80x50" style screen modes; named modes (C64 and so on) keep the default 80 x 25.
    static func screenSize(_ mode: String) -> (columns: Int, rows: Int)? {
        let parts = mode.lowercased().split(separator: "x")
        guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]),
              TerminalEmulator.sizeRange.contains(columns), TerminalEmulator.sizeRange.contains(rows) else { return nil }
        return (columns, rows)
    }
}
