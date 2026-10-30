import Foundation
import Testing
@testable import AnsiCore

@Test func knownCertificatesTrustOnFirstUse() {
    var known = KnownCertificates(text: "")
    let a = CertificateInfo(fingerprint: "AA:BB", subject: "bbs.example.com", systemTrusted: false)
    let b = CertificateInfo(fingerprint: "CC:DD", subject: "bbs.example.com", systemTrusted: false)
    #expect(known.check(host: "BBS.example.com", port: 992, certificate: a) == .unknown)
    known.trust(host: "bbs.example.com", port: 992, certificate: a)
    #expect(known.check(host: "bbs.example.com", port: 992, certificate: a) == .trusted)
    #expect(known.check(host: "bbs.example.com", port: 992, certificate: b) == .changed(saved: "AA:BB"))
    #expect(known.check(host: "bbs.example.com", port: 993, certificate: a) == .unknown)
    known.forget(host: "bbs.example.com", port: 992)
    #expect(known.check(host: "bbs.example.com", port: 992, certificate: b) == .unknown)
}

@Test func knownCertificatesTextRoundTripKeepsOtherLines() {
    var known = KnownCertificates(text: "# comment\nother.example:992 11:22 Other BBS\n")
    known.trust(host: "bbs.example.com", port: 992, certificate: CertificateInfo(fingerprint: "AA:BB", subject: "My BBS", systemTrusted: false))
    let again = KnownCertificates(text: known.text)
    #expect(again.text.hasPrefix("# comment\nother.example:992 11:22 Other BBS\n"))
    #expect(again.check(host: "bbs.example.com", port: 992, certificate: CertificateInfo(fingerprint: "AA:BB", subject: "", systemTrusted: false)) == .trusted)
}

@Test func certificateErrorsReadWell() {
    #expect(BBSConnectionError.certificateChanged("h", "AA", "BB").message.contains("changed"))
    #expect(BBSConnectionError.certificateNotTrusted("h").message.contains("not trusted"))
}

@Test func telnetSettingsChooseTLS() {
    var entry = BBSEntry(name: "A", host: "h", port: 992)
    entry.telnetSecure = true
    #expect(TransportSettings(entry: entry).telnetSecure)
    entry.mode = .raw
    #expect(!TransportSettings(entry: entry).telnetSecure)
}

/// Answers certificate questions without asking, recording them.
final class RecordingCertificateVerifier: CertificateVerifying {
    var answer = true
    var asked: [CertificateInfo] = []
    var store = KnownCertificates(text: "")

    func verify(host: String, port: Int, certificate: CertificateInfo, done: @escaping (BBSConnectionError?) -> Void) {
        switch store.check(host: host, port: port, certificate: certificate) {
        case .trusted: done(nil)
        case .changed(let saved): done(.certificateChanged(host, saved, certificate.fingerprint))
        case .unknown:
            asked.append(certificate)
            if answer {
                store.trust(host: host, port: port, certificate: certificate)
                done(nil)
            } else {
                done(.certificateNotTrusted(host))
            }
        }
    }
}

final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ more: String) -> String {
        lock.lock(); defer { lock.unlock() }
        text += more
        return text
    }
}

/// A local `openssl s_server` with a fresh self signed certificate.
final class LocalTLSServer: @unchecked Sendable {
    let port: Int
    private let process = Process()

    init?(greeting: String, folder: URL) {
        let openssl = ["/opt/homebrew/bin/openssl", "/opt/local/bin/openssl", "/usr/local/bin/openssl"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        // LibreSSL's s_server (/usr/bin/openssl) lacks -naccept, so an OpenSSL 3 is needed.
        guard let openssl else { return nil }
        let key = folder.appendingPathComponent("key.pem").path, cert = folder.appendingPathComponent("cert.pem").path
        let make = Process()
        make.executableURL = URL(fileURLWithPath: openssl)
        make.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2",
                          "-subj", "/CN=AnsiView Test BBS"]
        make.standardOutput = FileHandle.nullDevice
        make.standardError = FileHandle.nullDevice
        // A folder that already has a certificate keeps it (the same BBS again).
        if !FileManager.default.fileExists(atPath: cert) {
            guard (try? make.run()) != nil else { return nil }
            make.waitUntilExit()
        }
        port = Int.random(in: 41000...48000)
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = ["s_server", "-accept", "\(port)", "-cert", cert, "-key", key, "-naccept", "1"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Wait until the port listens (lsof never connects, so the single accept is kept for the test).
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !Self.listening(port) { Thread.sleep(forTimeInterval: 0.1) }
        input.fileHandleForWriting.write(Data(greeting.utf8))
    }

    deinit { if process.isRunning { process.terminate() } }

    static func listening(_ port: Int) -> Bool {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        lsof.standardOutput = out
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return true }
        lsof.waitUntilExit()
        return !out.fileHandleForReading.readDataToEndOfFile().isEmpty
    }

    /// Starts a server off the Swift concurrency threads (it blocks while openssl starts).
    static func start(greeting: String, folder: URL) async -> LocalTLSServer? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: LocalTLSServer(greeting: greeting, folder: folder)) }
        }
    }
}

private func connect(port: Int, verifier: RecordingCertificateVerifier) async -> (BBSClientState, [UInt8]) {
    await withCheckedContinuation { continuation in
        let queue = DispatchQueue(label: "tls-test")
        var settings = TransportSettings(mode: .telnet)
        settings.telnetSecure = true
        let client = BBSClient(host: "127.0.0.1", port: port, settings: settings, columns: 80, rows: 25,
                               connectTimeout: testConnectTimeout, queue: queue)
        client.certificateVerifier = verifier
        var received: [UInt8] = []
        var finished = false
        func end(_ state: BBSClientState) {
            guard !finished else { return }
            finished = true
            client.disconnect()
            continuation.resume(returning: (state, received))
        }
        client.onData = { bytes in
            received += bytes
            if String(decoding: received, as: UTF8.self).contains("HELLO") { end(.connected) }
        }
        client.onState = { state in if case .closed = state { end(state) } }
        client.connect()
        queue.asyncAfter(deadline: .now() + 120) { end(.closed(.timedOut("test"))) }
        _ = client
    }
}

@Test(.timeLimit(.minutes(1))) func telnetOverTLSWithASelfSignedCertificate() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let verifier = RecordingCertificateVerifier()
    guard let first = await LocalTLSServer.start(greeting: "HELLO\r\n", folder: folder) else { return }
    let (state, bytes) = await connect(port: first.port, verifier: verifier)
    #expect(state == .connected)
    #expect(String(decoding: bytes, as: UTF8.self).contains("HELLO"))
    #expect(verifier.asked.count == 1)
    #expect(verifier.asked.first?.subject == "AnsiView Test BBS")
    #expect(verifier.asked.first?.systemTrusted == false)
    let fingerprint = try #require(verifier.asked.first?.fingerprint)
    #expect(fingerprint.count == 95)

    // Same certificate again: no question.
    let firstPort = first.port
    _ = firstPort
    guard let second = await LocalTLSServer.start(greeting: "HELLO\r\n", folder: folder) else { return }
    verifier.store = KnownCertificates(text: "")
    verifier.store.trust(host: "127.0.0.1", port: second.port, certificate: verifier.asked[0])
    let again = await connect(port: second.port, verifier: verifier)
    #expect(again.0 == .connected)
    #expect(verifier.asked.count == 1)

    // A new certificate on a host with a saved one is refused.
    let other = folder.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    guard let third = await LocalTLSServer.start(greeting: "HELLO\r\n", folder: other) else { return }
    verifier.store = KnownCertificates(text: "")
    verifier.store.trust(host: "127.0.0.1", port: third.port, certificate: verifier.asked[0])
    let changed = await connect(port: third.port, verifier: verifier)
    if case .closed(.certificateChanged(_, let saved, _)) = changed.0 {
        #expect(saved == fingerprint)
    } else {
        Issue.record("expected a changed certificate refusal, got \(changed.0)")
    }

    // Not trusted by the user.
    let declined = folder.appendingPathComponent("declined")
    try FileManager.default.createDirectory(at: declined, withIntermediateDirectories: true)
    guard let fourth = await LocalTLSServer.start(greeting: "HELLO\r\n", folder: declined) else { return }
    let refuser = RecordingCertificateVerifier()
    refuser.answer = false
    let refused = await connect(port: fourth.port, verifier: refuser)
    #expect(refused.0 == .closed(.certificateNotTrusted("127.0.0.1")))
}
