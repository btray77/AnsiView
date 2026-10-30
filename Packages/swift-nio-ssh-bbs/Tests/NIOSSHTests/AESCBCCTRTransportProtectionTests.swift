// AnsiView patch (see PATCHES.md): AES-CTR/CBC with HMAC (RFC 4253 section 6, RFC 4344, RFC 6668).
// Block mode vectors: NIST SP 800-38A F.2.1, F.2.5, F.5.1, F.5.3, F.5.5. HMAC vectors: RFC 4231
// test cases 1 and 2 (SHA-256, SHA-512), RFC 2202 test case 1 (SHA-1). Every vector was also
// checked with OpenSSL 3.6 before it was written here.

import Crypto
import NIOCore
import XCTest

@testable import NIOSSH

final class AESCBCCTRTransportProtectionTests: XCTestCase {
    static let plaintext = bytes(
        "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
            + "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
    )
    static let key128 = bytes("2b7e151628aed2a6abf7158809cf4f3c")
    static let key192 = bytes("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b")
    static let key256 = bytes("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
    static let cbcIV = bytes("000102030405060708090a0b0c0d0e0f")
    static let ctrIV = bytes("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")

    /// Runs the cipher over the plaintext in two pieces (16 then 48 bytes), as the packet parser
    /// does with the first block, so the chaining or counter state must carry over.
    private func run(_ mode: SSHAESMode, key: [UInt8], iv: [UInt8], encrypt: Bool, _ input: [UInt8]) throws -> String {
        let cipher = try SSHAESCipher(mode: mode, encrypt: encrypt, key: key, iv: iv)
        let first = try cipher.process(Array(input[0..<16]))
        let rest = try cipher.process(Array(input[16...]))
        return hex(first + rest)
    }

    func testNISTBlockModeVectors() throws {
        let cases: [(SSHAESMode, [UInt8], [UInt8], String)] = [
            (.cbc, Self.key128, Self.cbcIV, "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b273bed6b8e3c1743b7116e69e222295163ff1caa1681fac09120eca307586e1a7"),
            (.cbc, Self.key256, Self.cbcIV, "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b"),
            (.ctr, Self.key128, Self.ctrIV, "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff5ae4df3edbd5d35e5b4f09020db03eab1e031dda2fbe03d1792170a0f3009cee"),
            (.ctr, Self.key192, Self.ctrIV, "1abc932417521ca24f2b0459fe7e6e0b090339ec0aa6faefd5ccc2c6f4ce8e941e36b26bd1ebc670d1bd1d665620abf74f78a7f6d29809585a97daec58c6b050"),
            (.ctr, Self.key256, Self.ctrIV, "601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c52b0930daa23de94ce87017ba2d84988ddfc9c58db67aada613c2dd08457941a6"),
        ]
        for (mode, key, iv, expected) in cases {
            XCTAssertEqual(try self.run(mode, key: key, iv: iv, encrypt: true, Self.plaintext), expected)
            XCTAssertEqual(try self.run(mode, key: key, iv: iv, encrypt: false, bytes(expected)), hex(Self.plaintext))
        }
    }

    /// NIST SP 800-38A F.2.3 (CBC-AES192) and a 3DES-EDE CBC vector made with `openssl enc -des-ede3-cbc`.
    func testAES192CBCAndTripleDESVectors() throws {
        XCTAssertEqual(
            try self.run(.cbc, key: Self.key192, iv: Self.cbcIV, encrypt: true, Self.plaintext),
            "4f021db243bc633d7178183a9fa071e8b4d9ada9ad7dedf4e5e738763f69145a571b242012fb7ae07fa9baac3df102e008b0e27988598881d920a9e64f5615cd"
        )
        let key = bytes("0123456789abcdef23456789abcdef01456789abcdef0123")
        let iv = bytes("f69f2445df4f9b17")
        let expected = "2079c3d53aa763e193b79e2569ab5262516570481f25b50f73c0bda85c8e0da79bd86425fae429fdbd65a7a21b6e5d20925d8b0ef919a428154b96ed90f2bc1e"
        let encryptor = try SSHAESCipher(mode: .cbc, encrypt: true, key: key, iv: iv, tripleDES: true)
        XCTAssertEqual(hex(try encryptor.process(Array(Self.plaintext[0..<8])) + encryptor.process(Array(Self.plaintext[8...]))), expected)
        let decryptor = try SSHAESCipher(mode: .cbc, encrypt: false, key: key, iv: iv, tripleDES: true)
        XCTAssertEqual(hex(try decryptor.process(bytes(expected))), hex(Self.plaintext))
        XCTAssertThrowsError(try SSHAESCipher(mode: .ctr, encrypt: true, key: key, iv: iv, tripleDES: true))
    }

    func testHMACVectors() {
        let key = SymmetricKey(data: [UInt8](repeating: 0x0B, count: 20))
        let hiThere = Array("Hi There".utf8)
        XCTAssertEqual(hex(HMACSHA256Algorithm.code(key: key, data: hiThere)), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        XCTAssertEqual(
            hex(HMACSHA512Algorithm.code(key: key, data: hiThere)),
            "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"
        )
        XCTAssertEqual(hex(HMACSHA1Algorithm.code(key: key, data: hiThere)), "b617318655057264e28bc0b6fb378c8ef146be00")
        let jefe = SymmetricKey(data: Array("Jefe".utf8))
        let question = Array("what do ya want for nothing?".utf8)
        XCTAssertEqual(hex(HMACSHA256Algorithm.code(key: jefe, data: question)), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual(
            hex(HMACSHA512Algorithm.code(key: jefe, data: question)),
            "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"
        )
        // RFC 2202 MD5 test case 1, and the -96 variants are the first 12 bytes (RFC 2104 section 5).
        let md5Key = SymmetricKey(data: [UInt8](repeating: 0x0B, count: 16))
        XCTAssertEqual(hex(HMACMD5Algorithm.code(key: md5Key, data: hiThere)), "9294727a3638bb1c13f48ef8158bfc9d")
        XCTAssertEqual(hex(HMACMD596Algorithm.code(key: md5Key, data: hiThere)), "9294727a3638bb1c13f48ef8")
        XCTAssertEqual(hex(HMACSHA196Algorithm.code(key: key, data: hiThere)), "b617318655057264e28bc0b6")
        XCTAssertEqual(HMACSHA196Algorithm.length, 12)
        XCTAssertEqual(HMACSHA196Algorithm.keyLength, 20)
    }

    func testNamesAndKeySizes() {
        let schemes = AESCBCCTRSchemes.all
        XCTAssertEqual(schemes.count, 42)
        XCTAssertEqual(
            Set(schemes.map { $0.cipherName }),
            ["aes256-ctr", "aes192-ctr", "aes128-ctr", "aes256-cbc", "aes192-cbc", "aes128-cbc", "3des-cbc"]
        )
        XCTAssertEqual(
            Set(schemes.compactMap { $0.macName }),
            ["hmac-sha2-256", "hmac-sha2-512", "hmac-sha1", "hmac-sha1-96", "hmac-md5", "hmac-md5-96"]
        )
        let des = schemes.first { $0.cipherName == "3des-cbc" && $0.macName == "hmac-md5-96" }!
        XCTAssertEqual(des.keySizes, ExpectedKeySizes(ivSize: 8, encryptionKeySize: 24, macKeySize: 16))
        XCTAssertEqual(des.cipherBlockSize, 8)
        let sha512 = schemes.first { $0.cipherName == "aes192-ctr" && $0.macName == "hmac-sha2-512" }!
        XCTAssertEqual(sha512.keySizes, ExpectedKeySizes(ivSize: 16, encryptionKeySize: 24, macKeySize: 64))
    }

    /// The order the library offers: AES-GCM first, then CTR, then CBC; each MAC once.
    func testBundledOrderIsModernFirst() {
        let ciphers = Constants.bundledTransportProtectionSchemes.map { $0.cipherName }
        var unique: [String] = []
        for cipher in ciphers where !unique.contains(cipher) {
            unique.append(cipher)
        }
        XCTAssertEqual(
            unique,
            [
                "aes256-gcm@openssh.com", "aes128-gcm@openssh.com", "aes256-ctr", "aes192-ctr", "aes128-ctr",
                "aes256-cbc", "aes192-cbc", "aes128-cbc", "3des-cbc",
            ]
        )
    }

    // MARK: Packets through the real serializer and parser

    private func keys(_ sizes: ExpectedKeySizes) -> NIOSSHSessionKeys {
        NIOSSHSessionKeys(
            initialInboundIV: .init(randomBytes: sizes.ivSize),
            initialOutboundIV: .init(randomBytes: sizes.ivSize),
            inboundEncryptionKey: SymmetricKey(data: [UInt8](randomBytes: sizes.encryptionKeySize)),
            outboundEncryptionKey: SymmetricKey(data: [UInt8](randomBytes: sizes.encryptionKeySize)),
            inboundMACKey: SymmetricKey(data: [UInt8](randomBytes: sizes.macKeySize)),
            outboundMACKey: SymmetricKey(data: [UInt8](randomBytes: sizes.macKeySize))
        )
    }

    private func pair(_ scheme: NIOSSHTransportProtection.Type) throws -> (SSHPacketSerializer, SSHPacketParser) {
        let keys = self.keys(scheme.keySizes)
        var serializer = SSHPacketSerializer()
        var parser = SSHPacketParser(isServer: false, allocator: .init())
        var buffer = ByteBuffer()
        try serializer.serialize(message: .version("SSH-2.0-Test"), to: &buffer)
        parser.append(bytes: &buffer)
        _ = try parser.nextPacket()
        serializer.addEncryption(try scheme.init(initialKeys: keys))
        parser.addEncryption(try scheme.init(initialKeys: keys.inverted))
        return (serializer, parser)
    }

    func testEverySchemeRoundTripsSeveralPacketsDripFed() throws {
        let messages: [SSHMessage] = [
            .serviceRequest(.init(service: "ssh-userauth")),
            .ignore(.init(data: ByteBuffer(bytes: [UInt8](repeating: 0x41, count: 1000)))),
            .newKeys,
            .serviceAccept(.init(service: "ssh-userauth")),
        ]
        for scheme in AESCBCCTRSchemes.all {
            var (serializer, parser) = try self.pair(scheme)
            for (index, message) in messages.enumerated() {
                var buffer = ByteBuffer()
                try serializer.serialize(message: message, to: &buffer)
                let macBytes = try scheme.init(initialKeys: self.keys(scheme.keySizes)).macBytes
                XCTAssertEqual((buffer.readableBytes - macBytes) % scheme.cipherBlockSize, 0)
                var received: SSHMessage?
                if index % 2 == 0 {
                    // Byte by byte: the first block is decrypted before the rest arrives.
                    while var slice = buffer.readSlice(length: 1) {
                        parser.append(bytes: &slice)
                        if let message = try parser.nextPacket() { received = message }
                    }
                } else {
                    parser.append(bytes: &buffer)
                    received = try parser.nextPacket()
                }
                XCTAssertEqual(received, message, "\(scheme.cipherName) \(scheme.macName ?? "")")
            }
        }
    }

    func testCorruptedCiphertextOrMACIsRejected() throws {
        for scheme in AESCBCCTRSchemes.all {
            for position in [5, 20, -1] {
                var (serializer, parser) = try self.pair(scheme)
                var buffer = ByteBuffer()
                try serializer.serialize(message: .serviceRequest(.init(service: "ssh-userauth-long-enough")), to: &buffer)
                let index = position < 0 ? buffer.writerIndex - 1 : position
                buffer.setInteger(buffer.getInteger(at: index, as: UInt8.self)! ^ 0x01, at: index)
                parser.append(bytes: &buffer)
                XCTAssertThrowsError(try parser.nextPacket(), "\(scheme.cipherName) \(scheme.macName ?? "") at \(position)")
            }
        }
    }

    func testBadLengthInFirstBlockIsRejected() throws {
        // A length that is not a whole number of blocks, and one below the minimum, decrypted from
        // a block the attacker chose: refused before any more bytes are waited for.
        for badLength in [UInt32(17), UInt32(4)] {
            let scheme = AESCBCCTRSchemes.all.first { $0.cipherName == "aes128-ctr" }!
            let keys = self.keys(scheme.keySizes)
            let encryptor = try SSHAESCipher(mode: .ctr, encrypt: true, key: keys.outboundEncryptionKey.bytes, iv: keys.initialOutboundIV)
            var block = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: badLength.bigEndian) { block.replaceSubrange(0..<4, with: $0) }
            let ciphertext = try encryptor.process(block)
            let decryptor = try scheme.init(initialKeys: keys.inverted)
            var buffer = ByteBuffer(bytes: ciphertext)
            XCTAssertThrowsError(try decryptor.decryptFirstBlock(&buffer))
        }
    }
}

extension SymmetricKey {
    var bytes: [UInt8] { self.withUnsafeBytes { Array($0) } }
}
