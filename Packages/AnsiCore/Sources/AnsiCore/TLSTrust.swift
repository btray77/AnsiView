import CryptoKit
import Foundation
import Security

/// A server certificate as shown to the user: the SHA-256 of its DER bytes (colon separated
/// upper case hex, as browsers show it), its subject, and whether macOS trusts it for the host.
public struct CertificateInfo: Equatable {
    public var fingerprint: String
    public var subject: String
    public var issuer: String = ""
    public var notAfter: Date?
    public var systemTrusted: Bool

    public init(fingerprint: String, subject: String, issuer: String = "", notAfter: Date? = nil, systemTrusted: Bool) {
        self.fingerprint = fingerprint
        self.subject = subject
        self.issuer = issuer
        self.notAfter = notAfter
        self.systemTrusted = systemTrusted
    }

    public static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The leaf certificate of a trust object.
    static func make(trust: SecTrust, systemTrusted: Bool) -> CertificateInfo? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "unknown"
        let issuer = chain.count > 1 ? ((SecCertificateCopySubjectSummary(chain[1]) as String?) ?? "") : subject
        return CertificateInfo(fingerprint: fingerprint(der: der), subject: subject, issuer: issuer, systemTrusted: systemTrusted)
    }
}

/// Decides whether a certificate that macOS does not trust may be used (trust on first use).
/// `done` must be called on the queue the transport runs on, with nil to connect.
public protocol CertificateVerifying: AnyObject {
    func verify(host: String, port: Int, certificate: CertificateInfo, done: @escaping (BBSConnectionError?) -> Void)
}

/// Certificates the user trusted for telnet over TLS, one per `host:port`, in a small text file:
/// `host:port FINGERPRINT subject`. Other lines (comments) are kept.
public struct KnownCertificates: Equatable {
    public enum Check: Equatable {
        case trusted
        case unknown
        case changed(saved: String)
    }

    private var lines: [String]

    public init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    private func saved(_ key: String) -> String? {
        for line in lines where !line.hasPrefix("#") {
            let fields = line.split(separator: " ", maxSplits: 2)
            if fields.count >= 2, fields[0] == key { return String(fields[1]) }
        }
        return nil
    }

    public func check(host: String, port: Int, certificate: CertificateInfo) -> Check {
        guard let fingerprint = saved(Self.key(host: host, port: port)) else { return .unknown }
        return fingerprint == certificate.fingerprint ? .trusted : .changed(saved: fingerprint)
    }

    public mutating func trust(host: String, port: Int, certificate: CertificateInfo) {
        let key = Self.key(host: host, port: port)
        guard saved(key) == nil else { return }
        let subject = certificate.subject.replacingOccurrences(of: "\n", with: " ")
        lines.append("\(key) \(certificate.fingerprint) \(subject)")
    }

    public mutating func forget(host: String, port: Int) {
        let key = Self.key(host: host, port: port)
        lines.removeAll { $0.split(separator: " ").first.map(String.init) == key }
    }

    public var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }
}

/// The trusted certificates file in the app container (`Application Support/AnsiView/known_tls_hosts`).
public struct KnownCertificatesFile {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var standard: KnownCertificatesFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return KnownCertificatesFile(url: support.appendingPathComponent("AnsiView").appendingPathComponent("known_tls_hosts"))
    }

    public func load() -> KnownCertificates {
        KnownCertificates(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public func save(_ known: KnownCertificates) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(known.text.utf8).write(to: url, options: .atomic)
    }
}
