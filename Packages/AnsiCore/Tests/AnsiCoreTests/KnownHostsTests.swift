import Foundation
import Testing
@testable import AnsiCore

private func publicKey(_ name: String) throws -> (type: String, blob: Data) {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "pub", subdirectory: "Fixtures/sshkeys"))
    let parts = try String(contentsOf: url, encoding: .utf8).split(separator: " ")
    return (String(parts[0]), try #require(Data(base64Encoded: String(parts[1]))))
}

@Test func fingerprintMatchesSshKeygen() throws {
    // Expected values printed by `ssh-keygen -lf` for the fixture keys.
    #expect(SSHFingerprint.sha256(try publicKey("ed25519").blob) == "SHA256:LmwNL7t4Bd6LXWUtVHOTxqbjqgHJns8kINA3KeApeRM")
    #expect(SSHFingerprint.sha256(try publicKey("ecdsa256").blob) == "SHA256:PDbVH/jMVNxqsXZRP3FBgde+C83PvVjgI1IBd/PstZE")
    #expect(SSHFingerprint.sha256(try publicKey("rsa").blob) == "SHA256:L7Ru114S7IvU0d/wul6wWi5tpYqICmtXXf11A3yugKU")
}

@Test func keyTypeFromBlob() throws {
    #expect(SSHFingerprint.keyType(try publicKey("ed25519").blob) == "ssh-ed25519")
    #expect(SSHFingerprint.keyType(try publicKey("ecdsa256").blob) == "ecdsa-sha2-nistp256")
    #expect(SSHFingerprint.keyType(try publicKey("rsa").blob) == "ssh-rsa")
    #expect(SSHFingerprint.keyType(Data([0, 0, 0, 99, 1])) == nil)
}

@Test func hostPatternWithPort() {
    #expect(KnownHosts.hostPattern(host: "BBS.Example.com", port: 22) == "bbs.example.com")
    #expect(KnownHosts.hostPattern(host: "bbs.example.com", port: 2222) == "[bbs.example.com]:2222")
    #expect(KnownHosts.hostPattern(host: "::1", port: 22) == "::1")
    #expect(KnownHosts.hostPattern(host: "::1", port: 2022) == "[::1]:2022")
}

@Test func unknownThenTrusted() throws {
    let key = try publicKey("ed25519").blob
    var hosts = KnownHosts(text: "")
    #expect(hosts.check(host: "bbs.example.com", port: 2222, key: key) == .unknown)
    hosts.trust(host: "bbs.example.com", port: 2222, key: key)
    #expect(hosts.check(host: "bbs.example.com", port: 2222, key: key) == .trusted)
    // A different port is a different host to OpenSSH.
    #expect(hosts.check(host: "bbs.example.com", port: 22, key: key) == .unknown)
    #expect(hosts.text.hasPrefix("[bbs.example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4Ff5m"))
}

@Test func changedKeyIsRefused() throws {
    let old = try publicKey("ed25519").blob
    let new = try publicKey("ecdsa256").blob
    var hosts = KnownHosts(text: "")
    hosts.trust(host: "bbs.example.com", port: 22, key: old)
    #expect(hosts.check(host: "bbs.example.com", port: 22, key: new)
            == .changed(saved: "SHA256:LmwNL7t4Bd6LXWUtVHOTxqbjqgHJns8kINA3KeApeRM"))
    // Trusting again never happens silently: trust() adds a line only for an unknown host.
    hosts.trust(host: "bbs.example.com", port: 22, key: new)
    #expect(hosts.check(host: "bbs.example.com", port: 22, key: new) != .trusted)
}

@Test func parseIgnoresCommentsAndHashedLines() throws {
    let key = try publicKey("ed25519")
    let b64 = key.blob.base64EncodedString()
    let text = """
    # a comment

    |1|abc=|def= ssh-ed25519 \(b64)
    @cert-authority *.example.com ssh-ed25519 \(b64)
    other.example.com,bbs.example.com ssh-ed25519 \(b64) a comment
    broken line
    """
    let hosts = KnownHosts(text: text)
    #expect(hosts.check(host: "bbs.example.com", port: 22, key: key.blob) == .trusted)
    #expect(hosts.check(host: "nope.example.com", port: 22, key: key.blob) == .unknown)
    // Unknown lines are kept when saving.
    #expect(hosts.text.contains("|1|abc=|def="))
    #expect(hosts.text.contains("broken line"))
}

@Test func forgetRemovesOnlyThatHost() throws {
    let key = try publicKey("ed25519").blob
    var hosts = KnownHosts(text: "")
    hosts.trust(host: "a.example.com", port: 22, key: key)
    hosts.trust(host: "b.example.com", port: 22, key: key)
    hosts.forget(host: "a.example.com", port: 22)
    #expect(hosts.check(host: "a.example.com", port: 22, key: key) == .unknown)
    #expect(hosts.check(host: "b.example.com", port: 22, key: key) == .trusted)
}

@Test func knownHostsFileRoundTrip() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knownhosts-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = KnownHostsFile(url: folder.appendingPathComponent("known_hosts"))
    let key = try publicKey("ecdsa256").blob
    #expect(file.load().check(host: "bbs.example.com", port: 22, key: key) == .unknown)
    var hosts = file.load()
    hosts.trust(host: "bbs.example.com", port: 22, key: key)
    try file.save(hosts)
    #expect(file.load().check(host: "bbs.example.com", port: 22, key: key) == .trusted)
}
