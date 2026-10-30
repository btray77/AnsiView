import CryptoKit
import Foundation

/// SSH public key fingerprints, written the way OpenSSH prints them.
public enum SSHFingerprint {
    /// `SHA256:` and the unpadded base64 of the SHA-256 of the key blob (`ssh-keygen -lf`).
    public static func sha256(_ blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// The algorithm name at the start of a key blob (`ssh-ed25519`, `ecdsa-sha2-nistp256`, ...).
    public static func keyType(_ blob: Data) -> String? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return nil }
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, length <= 64, bytes.count >= 4 + length else { return nil }
        let name = String(decoding: bytes[4..<(4 + length)], as: UTF8.self)
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-@.".contains($0)) }) else { return nil }
        return name
    }
}

/// Trust on first use for SSH host keys, in OpenSSH `known_hosts` format so the file can be read
/// and edited with ordinary tools. Lines AnsiView does not understand (hashed hosts, markers,
/// comments) are kept unchanged and otherwise ignored.
public struct KnownHosts: Equatable {
    public enum Check: Equatable {
        case trusted
        case unknown
        /// A key is saved for this host and it is not the one offered.
        case changed(saved: String)
    }

    private struct Line: Equatable {
        var raw: String
        var patterns: [String] = []
        var keyType = ""
        var key = Data()
        var isEntry: Bool { !patterns.isEmpty }
    }

    private var lines: [Line]

    public init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Self.parse(String($0)) }
        while lines.last?.raw.isEmpty == true { lines.removeLast() }
    }

    /// `host` for port 22, `[host]:port` otherwise; host names in lower case.
    public static func hostPattern(host: String, port: Int) -> String {
        let name = host.lowercased()
        return port == 22 ? name : "[\(name)]:\(port)"
    }

    public func check(host: String, port: Int, key: Data) -> Check {
        let pattern = Self.hostPattern(host: host, port: port)
        let saved = lines.filter { $0.isEntry && $0.patterns.contains(pattern) }
        if saved.contains(where: { $0.key == key }) { return .trusted }
        if let first = saved.first { return .changed(saved: SSHFingerprint.sha256(first.key)) }
        return .unknown
    }

    /// Saves the key for a host that has none. A host with a saved key is left alone: a changed key
    /// is only accepted after `forget`.
    public mutating func trust(host: String, port: Int, key: Data) {
        guard check(host: host, port: port, key: key) == .unknown else { return }
        let pattern = Self.hostPattern(host: host, port: port)
        let type = SSHFingerprint.keyType(key) ?? "ssh-unknown"
        let raw = "\(pattern) \(type) \(key.base64EncodedString())"
        lines.append(Line(raw: raw, patterns: [pattern], keyType: type, key: key))
    }

    /// Removes the host from every line (a line naming only that host goes).
    public mutating func forget(host: String, port: Int) {
        let pattern = Self.hostPattern(host: host, port: port)
        lines = lines.compactMap { line in
            guard line.isEntry, line.patterns.contains(pattern) else { return line }
            var kept = line
            kept.patterns.removeAll { $0 == pattern }
            guard !kept.patterns.isEmpty else { return nil }
            kept.raw = "\(kept.patterns.joined(separator: ",")) \(kept.keyType) \(kept.key.base64EncodedString())"
            return kept
        }
    }

    public var text: String {
        lines.isEmpty ? "" : lines.map(\.raw).joined(separator: "\n") + "\n"
    }

    private static func parse(_ raw: String) -> Line {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        var line = Line(raw: raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        // Comments, markers (@cert-authority, @revoked) and hashed host names are not entries here.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("@"), !trimmed.hasPrefix("|") else { return line }
        let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 3, let key = Data(base64Encoded: String(fields[2])) else { return line }
        line.patterns = fields[0].split(separator: ",").map { $0.lowercased() }
        line.keyType = String(fields[1])
        line.key = key
        return line
    }
}

/// The known hosts file in the app's container (`Application Support/AnsiView/known_hosts`).
public struct KnownHostsFile {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: KnownHostsFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return KnownHostsFile(url: support.appendingPathComponent("AnsiView").appendingPathComponent("known_hosts"))
    }

    /// A missing or unreadable file is an empty list.
    public func load() -> KnownHosts {
        KnownHosts(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public func save(_ hosts: KnownHosts) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(hosts.text.utf8).write(to: url, options: .atomic)
    }
}
