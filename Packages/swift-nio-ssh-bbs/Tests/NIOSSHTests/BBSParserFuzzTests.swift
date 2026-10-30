// AnsiView patch (see PATCHES.md): fuzzing of the parsers this patch adds or changes. Each case
// feeds mutated and random input; passing means no crash, no hang, and every parse either
// returns a message, returns nil (incomplete), or throws.

import Crypto
import NIOCore
import XCTest

@testable import NIOSSH

/// A small deterministic generator (SplitMix64) so failures can be reproduced.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class BBSParserFuzzTests: XCTestCase {
    private func seeds() throws -> [[UInt8]] {
        var messages: [SSHMessage] = []
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let signature = try hostKey.sign(digest: SHA256.hash(data: [1, 2, 3]))
        messages.append(
            .keyExchangeDHGroupExchangeGroup(
                .init(
                    prime: ByteBuffer(bytes: DiffieHellmanParameters.mpintBody(DiffieHellmanGroup.group14.prime)),
                    generator: ByteBuffer(bytes: [2])
                )
            )
        )
        messages.append(.keyExchangeInit(.init(publicKey: ByteBuffer(bytes: [0, 0x80, 1]), kind: .groupExchangeInit)))
        messages.append(
            .keyExchangeInit(
                .init(publicKey: ByteBuffer(), kind: .groupExchangeRequest(minimum: 2048, preferred: 3072, maximum: 8192))
            )
        )
        messages.append(
            .keyExchangeReply(
                .init(hostKey: hostKey.publicKey, publicKey: ByteBuffer(bytes: [5]), signature: signature, isGroupExchangeReply: true)
            )
        )
        messages.append(
            .userAuthInfoRequest(
                .init(name: "n", instruction: "i", languageTag: "", prompts: [.init(prompt: "Password: ", echo: false)])
            )
        )
        messages.append(.userAuthInfoResponse(.init(responses: ["secret", ""])))
        messages.append(.userAuthPasswordChangeRequest(.init(prompt: "Change it", languageTag: "en")))
        messages.append(
            .userAuthRequest(.init(username: "u", service: "ssh-connection", method: .keyboardInteractive(submethods: "")))
        )
        return messages.map { message in
            var buffer = ByteBuffer()
            buffer.writeSSHMessage(message)
            return Array(buffer.readableBytesView)
        }
    }

    private func parse(_ bytes: [UInt8]) {
        var buffer = ByteBuffer(bytes: bytes)
        _ = try? buffer.readSSHMessage()
    }

    func testSeedsRoundTrip() throws {
        for seed in try self.seeds() {
            var buffer = ByteBuffer(bytes: seed)
            let message = try XCTUnwrap(try buffer.readSSHMessage(), "\(seed.prefix(8))")
            var again = ByteBuffer()
            again.writeSSHMessage(message)
            XCTAssertEqual(Array(again.readableBytesView), seed)
        }
    }

    func testMutatedMessagesNeverCrash() throws {
        var rng = SeededGenerator(state: 4419)
        let seeds = try self.seeds()
        for _ in 0..<40000 {
            var bytes = seeds.randomElement(using: &rng)!
            switch rng.next() % 4 {
            case 0:
                // Flip a few bytes (often lengths).
                for _ in 0..<(1 + Int(rng.next() % 4)) {
                    let index = Int(rng.next() % UInt64(bytes.count))
                    bytes[index] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
                }
            case 1:
                bytes = Array(bytes.prefix(Int(rng.next() % UInt64(bytes.count + 1))))
            case 2:
                bytes += (0..<Int(rng.next() % 16)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            default:
                // Large lengths and prompt counts.
                let index = 1 + Int(rng.next() % UInt64(max(bytes.count - 4, 1)))
                if index + 4 <= bytes.count {
                    bytes.replaceSubrange(index..<(index + 4), with: [0xFF, 0xFF, 0xFF, UInt8(truncatingIfNeeded: rng.next())])
                }
            }
            self.parse(bytes)
        }
    }

    func testRandomPayloadsForEachNewMessageNumber() {
        var rng = SeededGenerator(state: 4256)
        for _ in 0..<20000 {
            let id = [31, 32, 33, 34, 60, 61, 50].randomElement(using: &rng)!
            let count = Int(rng.next() % 300)
            self.parse([UInt8(id)] + (0..<count).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        }
    }

    func testRandomHostKeysAndSignatures() {
        var rng = SeededGenerator(state: 8332)
        for _ in 0..<3000 {
            for name in ["ssh-rsa", "ssh-dss", "rsa-sha2-256", "rsa-sha2-512"] {
                var buffer = ByteBuffer()
                buffer.writeSSHString(Array(name.utf8))
                for _ in 0..<Int(rng.next() % 5) {
                    let length = Int(rng.next() % 200)
                    buffer.writeSSHString((0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
                }
                var keyCopy = buffer
                _ = try? keyCopy.readSSHHostKey()
                _ = try? buffer.readSSHSignature()
            }
        }
    }

    /// Random ciphertext through the real packet parser with each new cipher: errors only.
    func testRandomCiphertextThroughThePacketParser() throws {
        var rng = SeededGenerator(state: 4344)
        for scheme in AESCBCCTRSchemes.all {
            for _ in 0..<40 {
                let sizes = scheme.keySizes
                let keys = NIOSSHSessionKeys(
                    initialInboundIV: (0..<sizes.ivSize).map { _ in UInt8(truncatingIfNeeded: rng.next()) },
                    initialOutboundIV: (0..<sizes.ivSize).map { _ in UInt8(truncatingIfNeeded: rng.next()) },
                    inboundEncryptionKey: SymmetricKey(data: (0..<sizes.encryptionKeySize).map { _ in UInt8(truncatingIfNeeded: rng.next()) }),
                    outboundEncryptionKey: SymmetricKey(data: (0..<sizes.encryptionKeySize).map { _ in UInt8(truncatingIfNeeded: rng.next()) }),
                    inboundMACKey: SymmetricKey(data: (0..<sizes.macKeySize).map { _ in UInt8(truncatingIfNeeded: rng.next()) }),
                    outboundMACKey: SymmetricKey(data: (0..<sizes.macKeySize).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
                )
                var parser = SSHPacketParser(isServer: false, allocator: .init())
                var version = ByteBuffer(bytes: Array("SSH-2.0-x\r\n".utf8))
                parser.append(bytes: &version)
                _ = try parser.nextPacket()
                parser.addEncryption(try scheme.init(initialKeys: keys))
                var noise = ByteBuffer(bytes: (0..<Int(rng.next() % 600)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
                parser.append(bytes: &noise)
                do {
                    let message = try parser.nextPacket()
                    // Random bytes passing a 96 to 512 bit MAC would be a broken MAC check.
                    XCTAssertNil(message, "\(scheme.cipherName) \(scheme.macName ?? "")")
                } catch {}
            }
        }
    }
}
