import Foundation
import Security
import Testing
@testable import AnsiCore

@Test func clientCertificateFieldsRoundTrip() throws {
    var entry = BBSEntry(name: "S", host: "s.example.com", port: 992)
    entry.telnetSecure = true
    entry.tlsClientIdentity = Data([1, 2, 3])
    entry.tlsClientIdentityName = "My BBS key"
    let back = try JSONDecoder().decode(BBSEntry.self, from: JSONEncoder().encode(entry))
    #expect(back.tlsClientIdentity == Data([1, 2, 3]) && back.tlsClientIdentityName == "My BBS key")
    let old = try JSONDecoder().decode(BBSEntry.self, from: Data(#"{"name":"O","host":"o.example.com"}"#.utf8))
    #expect(old.tlsClientIdentity == nil && old.tlsClientIdentityName == "")
    // Exported directories never carry a Keychain reference.
    let imported = try DialingDirectory.importEntries(from: DialingDirectory(entries: [entry]).exportData(ids: nil))
    #expect(imported.first?.tlsClientIdentity == nil)
}

@Test func keychainIdentitiesCanBeListed() {
    // Whatever this Mac holds; the call must not fail or block.
    let identities = TLSClientIdentities.list()
    #expect(identities.allSatisfy { !$0.reference.isEmpty })
    #expect(TLSClientIdentities.identity(reference: Data([0, 1, 2])) == nil)
}

/// A client certificate and key as an in memory identity (PKCS#12 imported without a keychain).
private func makeIdentity(folder: URL, openssl: String) -> (SecIdentity, String)? {
    let key = folder.appendingPathComponent("client-key.pem").path, cert = folder.appendingPathComponent("client.pem").path
    let p12 = folder.appendingPathComponent("client.p12").path
    func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: openssl)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
    guard run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2",
               "-subj", "/CN=AnsiView Test Client"]),
          run(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12, "-passout", "pass:test",
               "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1"]),
          let data = FileManager.default.contents(atPath: p12) else { return nil }
    guard #available(macOS 15, *) else { return nil }
    var items: CFArray?
    let options: [String: Any] = [kSecImportExportPassphrase as String: "test", kSecImportToMemoryOnly as String: true]
    guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
          let first = (items as? [[String: Any]])?.first, let identity = first[kSecImportItemIdentity as String] else { return nil }
    return ((identity as! SecIdentity), cert)
}

private func connect(port: Int, identity: SecIdentity?) async -> BBSClientState {
    await withCheckedContinuation { continuation in
        let queue = DispatchQueue(label: "tls-client-cert")
        var settings = TransportSettings(mode: .telnet)
        settings.telnetSecure = true
        let client = BBSClient(host: "127.0.0.1", port: port, settings: settings, columns: 80, rows: 25,
                               connectTimeout: testConnectTimeout, queue: queue)
        let verifier = RecordingCertificateVerifier()
        client.certificateVerifier = verifier
        client.clientIdentity = identity
        var received: [UInt8] = []
        var finished = false
        func end(_ state: BBSClientState) {
            guard !finished else { return }
            finished = true
            client.disconnect()
            _ = verifier
            continuation.resume(returning: state)
        }
        client.onData = { bytes in
            received += bytes
            if String(decoding: received, as: UTF8.self).contains("HELLO") { end(.connected) }
        }
        client.onState = { state in if case .closed = state { end(state) } }
        client.connect()
        queue.asyncAfter(deadline: .now() + 60) { end(.closed(.timedOut("test"))) }
    }
}

@Test(.timeLimit(.minutes(1))) func serverThatRequiresAClientCertificate() async throws {
    let openssl = ["/opt/homebrew/bin/openssl", "/opt/local/bin/openssl", "/usr/local/bin/openssl"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let openssl else { return }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tlsclient-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (identity, clientCert) = try #require(makeIdentity(folder: folder, openssl: openssl))
    // -Verify 1: the server refuses a handshake without a client certificate it can check.
    let extra = ["-Verify", "1", "-CAfile", clientCert]
    guard let withCert = await LocalTLSServer.start(greeting: "HELLO\r\n", folder: folder, extra: extra) else { return }
    #expect(await connect(port: withCert.port, identity: identity) == .connected)
    guard let without = await LocalTLSServer.start(greeting: "HELLO\r\n", folder: folder, extra: extra) else { return }
    #expect(await connect(port: without.port, identity: nil) != .connected)
}

@Test func clientCertificateChoiceInTheForm() {
    EntryForm.clientIdentities = { [TLSClientIdentities.Item(name: "Key A", reference: Data([1])), TLSClientIdentities.Item(name: "Key B", reference: Data([2]))] }
    defer { EntryForm.clientIdentities = { [] } }
    var entry = BBSEntry(name: "T", host: "t.example.com", port: 992)
    entry.telnetSecure = true
    var form = EntryForm.make(entry: entry, password: "", fonts: BitmapFont.supportedNames, speeds: [0])
    #expect(form.field("tlsClientIdentity")?.options == ["None", "Key A", "Key B"])
    form.setChoice("tlsClientIdentity", index: 2)
    let chosen = EntryForm.apply(form, to: entry).entry
    #expect(chosen.tlsClientIdentity == Data([2]) && chosen.tlsClientIdentityName == "Key B")
    var again = EntryForm.make(entry: chosen, password: "", fonts: BitmapFont.supportedNames, speeds: [0])
    #expect(again.field("tlsClientIdentity")?.index == 2)
    again.setChoice("tlsClientIdentity", index: 0)
    #expect(EntryForm.apply(again, to: chosen).entry.tlsClientIdentity == nil)
}
