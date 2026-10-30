//===----------------------------------------------------------------------===//
//
// AnsiView patch (see PATCHES.md): the fixed MODP groups of RFC 3526 used by RFC 8268.
//
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

/// A finite field Diffie-Hellman group: prime modulus and generator.
struct DiffieHellmanGroup: Sendable {
    var prime: SSHBigUInt
    var generator: SSHBigUInt

    /// RFC 2409 section 6.2, Oakley group 2, 1024-bit MODP (diffie-hellman-group1-sha1, RFC 4253).
    /// Weak; offered last, for old BBS servers only.
    static let group1 = DiffieHellmanGroup(
        prime: SSHBigUInt(hexDigits: """
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
            020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
            4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
            EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF
            """),
        generator: SSHBigUInt(limbs: [2])
    )

    /// RFC 3526 section 3, 2048-bit MODP group (diffie-hellman-group14-*).
    static let group14 = DiffieHellmanGroup(
        prime: SSHBigUInt(hexDigits: """
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
            020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
            4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
            EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
            98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
            9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
            E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
            3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF
            """),
        generator: SSHBigUInt(limbs: [2])
    )

    /// RFC 3526 section 5, 4096-bit MODP group (diffie-hellman-group16-sha512).
    static let group16 = DiffieHellmanGroup(
        prime: SSHBigUInt(hexDigits: """
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
            020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
            4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
            EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
            98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
            9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
            E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
            3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33
            A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7
            ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864
            D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2
            08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7
            88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8
            DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2
            233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9
            93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF
            """),
        generator: SSHBigUInt(limbs: [2])
    )
}

extension SSHBigUInt {
    /// Parses hexadecimal digits, ignoring whitespace (for the constants above).
    init(hexDigits text: String) {
        var bytes: [UInt8] = []
        var pending: UInt8?
        for character in text.unicodeScalars where !character.properties.isWhitespace {
            guard let digit = UInt8(String(character), radix: 16) else {
                preconditionFailure("not a hex digit: \(character)")
            }
            if let high = pending {
                bytes.append(high << 4 | digit)
                pending = nil
            } else {
                pending = digit
            }
        }
        precondition(pending == nil, "odd number of hex digits")
        self.init(bigEndianBytes: bytes)
    }
}
