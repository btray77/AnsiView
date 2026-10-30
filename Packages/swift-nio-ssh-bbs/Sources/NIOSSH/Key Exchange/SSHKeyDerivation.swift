//===----------------------------------------------------------------------===//
//
// AnsiView patch (see PATCHES.md): RFC 4253 section 7.2 key derivation with key extension.
//
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOCore

enum SSHKeyDerivation {
    /// An unsigned big endian integer as an SSH mpint (RFC 4251 section 5): a 4 byte length, no
    /// leading zero bytes, and one zero byte in front when the top bit would otherwise be set.
    static func mpint(_ unsignedBigEndian: [UInt8]) -> [UInt8] {
        var body = ArraySlice(unsignedBigEndian.drop { $0 == 0 })
        if let first = body.first, first & 0x80 != 0 {
            body.insert(0, at: body.startIndex)
        }
        let length = UInt32(body.count)
        return [
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
        ] + body
    }

    /// RFC 4253 section 7.2, given a hasher that has already taken `K || H`:
    /// K1 = HASH(K || H || X || session_id), K(n+1) = HASH(K || H || K1 || ... || Kn), and the
    /// key is the first `length` bytes of K1 || K2 || ...
    static func expand<H: HashFunction, S: Sequence>(
        _ seeded: H,
        letter: UInt8,
        sessionID: S,
        length: Int
    ) -> [UInt8] where S.Element == UInt8 {
        var first = seeded
        first.update(data: [letter])
        first.update(data: Array(sessionID))
        var output = Array(first.finalize())
        while output.count < length {
            var next = seeded
            next.update(data: output)
            output += Array(next.finalize())
        }
        return Array(output.prefix(length))
    }

    /// One key from the shared secret (unsigned big endian), the exchange hash and the session id.
    static func derive<H: HashFunction>(
        _ type: H.Type,
        sharedSecret: [UInt8],
        exchangeHash: [UInt8],
        letter: UInt8,
        sessionID: [UInt8],
        length: Int
    ) -> [UInt8] {
        var hasher = H()
        hasher.update(data: Self.mpint(sharedSecret))
        hasher.update(data: exchangeHash)
        return Self.expand(hasher, letter: letter, sessionID: sessionID, length: length)
    }

    /// The six session keys of RFC 4253 section 7.2 for our role.
    static func sessionKeys<H: HashFunction>(
        _ type: H.Type,
        sharedSecret: [UInt8],
        exchangeHash: [UInt8],
        sessionID: [UInt8],
        sizes: ExpectedKeySizes,
        isClient: Bool
    ) -> NIOSSHSessionKeys {
        func key(_ letter: Character, _ length: Int) -> [UInt8] {
            Self.derive(
                type,
                sharedSecret: sharedSecret,
                exchangeHash: exchangeHash,
                letter: letter.asciiValue!,
                sessionID: sessionID,
                length: length
            )
        }
        let ivC2S = key("A", sizes.ivSize)
        let ivS2C = key("B", sizes.ivSize)
        let encC2S = SymmetricKey(data: key("C", sizes.encryptionKeySize))
        let encS2C = SymmetricKey(data: key("D", sizes.encryptionKeySize))
        let macC2S = SymmetricKey(data: key("E", sizes.macKeySize))
        let macS2C = SymmetricKey(data: key("F", sizes.macKeySize))
        if isClient {
            return NIOSSHSessionKeys(
                initialInboundIV: ivS2C,
                initialOutboundIV: ivC2S,
                inboundEncryptionKey: encS2C,
                outboundEncryptionKey: encC2S,
                inboundMACKey: macS2C,
                outboundMACKey: macC2S
            )
        }
        return NIOSSHSessionKeys(
            initialInboundIV: ivC2S,
            initialOutboundIV: ivS2C,
            inboundEncryptionKey: encC2S,
            outboundEncryptionKey: encS2C,
            inboundMACKey: macC2S,
            outboundMACKey: macS2C
        )
    }
}
