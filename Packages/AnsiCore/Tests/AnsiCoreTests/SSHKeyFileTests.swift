import Foundation
import Testing
@testable import AnsiCore

private func keyData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/sshkeys"))
    return try Data(contentsOf: url)
}

private func publicBlob(_ name: String) throws -> Data {
    let text = String(decoding: try keyData(name + ".pub"), as: UTF8.self)
    return try #require(Data(base64Encoded: String(text.split(separator: " ")[1])))
}

private func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

@Test func blowfishVector() {
    // Schneier's published test vectors (key, plaintext, ciphertext).
    let vectors = [("0000000000000000", "0000000000000000", "4EF997456198DD78"),
                   ("FFFFFFFFFFFFFFFF", "FFFFFFFFFFFFFFFF", "51866FD5B85ECB8A"),
                   ("0123456789ABCDEF", "1111111111111111", "61F9C3802281B096")]
    for (key, plain, cipher) in vectors {
        let bf = Blowfish(key: hex(key))
        let p = hex(plain)
        var l = UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
        var r = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])
        bf.encrypt(&l, &r)
        #expect(String(format: "%08X%08X", l, r) == cipher)
    }
}

@Test func ed25519Unencrypted() throws {
    let key = try SSHKeyFile.parse(try keyData("ed25519"), passphrase: nil)
    #expect(key.typeName == "ssh-ed25519")
    #expect(key.publicKeyBlob == (try publicBlob("ed25519")))
    #expect(!SSHKeyFile.isEncrypted(try keyData("ed25519")))
}

@Test func ed25519WithPassphrase() throws {
    let data = try keyData("ed25519_pass")
    #expect(SSHKeyFile.isEncrypted(data))
    let key = try SSHKeyFile.parse(data, passphrase: "fixture-passphrase")
    #expect(key.publicKeyBlob == (try publicBlob("ed25519_pass")))
}

@Test func cbcCipherWithPassphrase() throws {
    let key = try SSHKeyFile.parse(try keyData("ed25519_cbc"), passphrase: "fixture-passphrase")
    #expect(key.publicKeyBlob == (try publicBlob("ed25519_cbc")))
}

@Test func wrongPassphrase() throws {
    #expect(throws: SSHKeyFileError.wrongPassphrase) {
        try SSHKeyFile.parse(try keyData("ed25519_pass"), passphrase: "not it")
    }
}

@Test func needsPassphrase() throws {
    #expect(throws: SSHKeyFileError.needsPassphrase) {
        try SSHKeyFile.parse(try keyData("ecdsa384_pass"), passphrase: nil)
    }
    #expect(throws: SSHKeyFileError.needsPassphrase) {
        try SSHKeyFile.parse(try keyData("ecdsa384_pass"), passphrase: "")
    }
}

@Test func ecdsaKeys() throws {
    let p256 = try SSHKeyFile.parse(try keyData("ecdsa256"), passphrase: nil)
    #expect(p256.typeName == "ecdsa-sha2-nistp256")
    #expect(p256.publicKeyBlob == (try publicBlob("ecdsa256")))
    let p384 = try SSHKeyFile.parse(try keyData("ecdsa384_pass"), passphrase: "fixture-passphrase")
    #expect(p384.typeName == "ecdsa-sha2-nistp384")
    #expect(p384.publicKeyBlob == (try publicBlob("ecdsa384_pass")))
    let p521 = try SSHKeyFile.parse(try keyData("ecdsa521"), passphrase: nil)
    #expect(p521.publicKeyBlob == (try publicBlob("ecdsa521")))
}

@Test func pemEcKey() throws {
    let key = try SSHKeyFile.parse(try keyData("ecdsa256_pem"), passphrase: nil)
    #expect(key.typeName == "ecdsa-sha2-nistp256")
    #expect(key.publicKeyBlob == (try publicBlob("ecdsa256_pem")))
}

@Test func rsaRefused() throws {
    #expect(throws: SSHKeyFileError.unsupportedKeyType("ssh-rsa")) {
        try SSHKeyFile.parse(try keyData("rsa"), passphrase: nil)
    }
    #expect(SSHKeyFileError.unsupportedKeyType("ssh-rsa").message.contains("ssh-keygen -t ed25519"))
}

@Test func notAKey() {
    #expect(throws: SSHKeyFileError.notAKey) { try SSHKeyFile.parse(Data("hello".utf8), passphrase: nil) }
    #expect(throws: SSHKeyFileError.notAKey) {
        try SSHKeyFile.parse(Data("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n".utf8),
                             passphrase: nil)
    }
}
