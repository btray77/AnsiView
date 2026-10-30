//===----------------------------------------------------------------------===//
//
// AnsiView patch (see PATCHES.md): finite field Diffie-Hellman key exchange.
//   diffie-hellman-group1-sha1, diffie-hellman-group14-sha1 (RFC 4253 section 8),
//   diffie-hellman-group14-sha256, diffie-hellman-group16-sha512 (RFC 8268),
//   diffie-hellman-group-exchange-sha1/-sha256 (RFC 4419, client side only).
//
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOCore

/// One finite field Diffie-Hellman method: its name, its hash and its group (nil for group exchange).
protocol FiniteFieldDiffieHellmanVariant: _NIOSSHSendableMetatype {
    associatedtype Hasher: HashFunction
    static var name: Substring { get }
    static var group: DiffieHellmanGroup? { get }
}

enum DHGroup1SHA1: FiniteFieldDiffieHellmanVariant {
    typealias Hasher = Insecure.SHA1
    static let name: Substring = "diffie-hellman-group1-sha1"
    static var group: DiffieHellmanGroup? { .group1 }
}

enum DHGroup14SHA1: FiniteFieldDiffieHellmanVariant {
    typealias Hasher = Insecure.SHA1
    static let name: Substring = "diffie-hellman-group14-sha1"
    static var group: DiffieHellmanGroup? { .group14 }
}

enum DHGroup14SHA256: FiniteFieldDiffieHellmanVariant {
    typealias Hasher = SHA256
    static let name: Substring = "diffie-hellman-group14-sha256"
    static var group: DiffieHellmanGroup? { .group14 }
}

enum DHGroup16SHA512: FiniteFieldDiffieHellmanVariant {
    typealias Hasher = SHA512
    static let name: Substring = "diffie-hellman-group16-sha512"
    static var group: DiffieHellmanGroup? { .group16 }
}

enum DHGroupExchangeSHA1: FiniteFieldDiffieHellmanVariant {
    typealias Hasher = Insecure.SHA1
    static let name: Substring = "diffie-hellman-group-exchange-sha1"
    static var group: DiffieHellmanGroup? { nil }
}

enum DHGroupExchangeSHA256: FiniteFieldDiffieHellmanVariant {
    typealias Hasher = SHA256
    static let name: Substring = "diffie-hellman-group-exchange-sha256"
    static var group: DiffieHellmanGroup? { nil }
}

enum DiffieHellmanParameters {
    /// Bits of the private exponent: twice the 256 bit security of the strongest cipher. The
    /// ladder always runs exactly this many steps.
    static let exponentBits = 512

    /// RFC 4419 SSH_MSG_KEX_DH_GEX_REQUEST values (RFC 8270 raises the minimum to 2048).
    static let groupExchangeMinimum: UInt32 = 2048
    static let groupExchangePreferred: UInt32 = 3072
    static let groupExchangeMaximum: UInt32 = 8192

    /// A random exponent of exactly `exponentBits` bits (top bit set).
    static func randomExponent() -> SSHBigUInt {
        var rng = CSPRNG()
        var limbs = (0..<(exponentBits / 64)).map { _ in rng.next() as UInt64 }
        limbs[limbs.count - 1] |= 1 << 63
        return SSHBigUInt(limbs: limbs)
    }

    /// The body of an mpint (no length): minimal, with a zero byte when the top bit is set.
    static func mpintBody(_ value: SSHBigUInt) -> [UInt8] {
        Array(SSHKeyDerivation.mpint(value.bigEndianBytes).dropFirst(4))
    }

    /// An mpint body from the wire as an unsigned value; negative values are refused.
    static func unsigned(_ body: ByteBuffer) throws -> SSHBigUInt {
        if let first = body.readableBytesView.first, first & 0x80 != 0 {
            throw NIOSSHError.invalidSSHMessage(reason: "negative Diffie-Hellman value")
        }
        return SSHBigUInt(bigEndianBytes: body.readableBytesView)
    }

    /// RFC 4253 section 8: values outside 1 < v < p - 1 must not be accepted.
    static func checkRange(_ value: SSHBigUInt, prime: SSHBigUInt) throws {
        let one = SSHBigUInt(limbs: [1])
        guard one < value, value < prime.subtracting(one) else {
            throw NIOSSHError.invalidSSHMessage(reason: "Diffie-Hellman value out of range")
        }
    }
}

struct FiniteFieldDiffieHellmanKeyExchange<Variant: FiniteFieldDiffieHellmanVariant>: EllipticCurveKeyExchangeProtocol {
    private let ourRole: SSHConnectionRole
    private let previousSessionIdentifier: ByteBuffer?
    private var group: DiffieHellmanGroup?
    private var modulus: SSHMontgomeryModulus?
    private var secret: SSHBigUInt?
    private var ourPublic: SSHBigUInt?
    /// Group exchange: whether the server's group has arrived.
    private var receivedGroup = false

    static var keyExchangeAlgorithmNames: [Substring] { [Variant.name] }

    static var isGroupExchange: Bool { Variant.group == nil }

    init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier
        if let group = Variant.group {
            self.useGroup(group)
        }
    }

    private mutating func useGroup(_ group: DiffieHellmanGroup) {
        let modulus = SSHMontgomeryModulus(group.prime)!
        let secret = DiffieHellmanParameters.randomExponent()
        self.group = group
        self.modulus = modulus
        self.secret = secret
        self.ourPublic = modulus.power(group.generator, exponent: secret, exponentBits: DiffieHellmanParameters.exponentBits)
    }

    func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) -> SSHMessage.KeyExchangeECDHInitMessage {
        precondition(self.ourRole.isClient, "Only clients may initiate the client side key exchange!")
        guard let ourPublic = self.ourPublic else {
            // Group exchange: ask for a group first (RFC 4419 SSH_MSG_KEX_DH_GEX_REQUEST).
            return .init(
                publicKey: allocator.buffer(capacity: 0),
                kind: .groupExchangeRequest(
                    minimum: DiffieHellmanParameters.groupExchangeMinimum,
                    preferred: DiffieHellmanParameters.groupExchangePreferred,
                    maximum: DiffieHellmanParameters.groupExchangeMaximum
                )
            )
        }
        return .init(publicKey: ByteBuffer(bytes: DiffieHellmanParameters.mpintBody(ourPublic)))
    }

    mutating func receiveGroupExchangeGroup(
        _ message: SSHMessage.KeyExchangeDHGroupExchangeGroupMessage
    ) throws -> SSHMessage.KeyExchangeECDHInitMessage {
        guard Self.isGroupExchange, self.ourRole.isClient, !self.receivedGroup else {
            throw NIOSSHError.protocolViolation(protocolName: "key exchange", violation: "unexpected group exchange group")
        }
        let prime = try DiffieHellmanParameters.unsigned(message.prime)
        let generator = try DiffieHellmanParameters.unsigned(message.generator)
        let bits = UInt32(prime.bitWidth)
        guard prime.bit(0), bits >= DiffieHellmanParameters.groupExchangeMinimum,
            bits <= DiffieHellmanParameters.groupExchangeMaximum
        else {
            throw NIOSSHError.invalidSSHMessage(reason: "group exchange prime of \(bits) bits is not accepted")
        }
        try DiffieHellmanParameters.checkRange(generator, prime: prime)
        self.useGroup(DiffieHellmanGroup(prime: prime, generator: generator))
        self.receivedGroup = true
        return .init(
            publicKey: ByteBuffer(bytes: DiffieHellmanParameters.mpintBody(self.ourPublic!)),
            kind: .groupExchangeInit
        )
    }

    mutating func completeKeyExchangeServerSide(
        clientKeyExchangeMessage message: SSHMessage.KeyExchangeECDHInitMessage,
        serverHostKey: NIOSSHPrivateKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, SSHMessage.KeyExchangeECDHReplyMessage) {
        precondition(self.ourRole.isServer, "Only servers may receive a client key exchange packet!")
        guard !Self.isGroupExchange, message.kind == .ecdh, let ourPublic = self.ourPublic else {
            throw NIOSSHError.protocolViolation(protocolName: "key exchange", violation: "group exchange is client only")
        }
        let (result, hash) = try self.finish(
            theirPublic: message.publicKey,
            hostKey: serverHostKey.publicKey,
            initialExchangeBytes: &initialExchangeBytes,
            allocator: allocator,
            expectedKeySizes: expectedKeySizes
        )
        let signature = try serverHostKey.sign(digest: hash)
        let reply = SSHMessage.KeyExchangeECDHReplyMessage(
            hostKey: serverHostKey.publicKey,
            publicKey: ByteBuffer(bytes: DiffieHellmanParameters.mpintBody(ourPublic)),
            signature: signature
        )
        return (result, reply)
    }

    mutating func receiveServerKeyExchangePayload(
        serverKeyExchangeMessage message: SSHMessage.KeyExchangeECDHReplyMessage,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> KeyExchangeResult {
        precondition(self.ourRole.isClient, "Only clients may receive a server key exchange packet!")
        // A group exchange reply (33) only after the group arrived; a plain reply (31) otherwise.
        guard message.isGroupExchangeReply == Self.isGroupExchange, !Self.isGroupExchange || self.receivedGroup else {
            throw NIOSSHError.protocolViolation(protocolName: "key exchange", violation: "unexpected key exchange reply")
        }
        let (result, hash) = try self.finish(
            theirPublic: message.publicKey,
            hostKey: message.hostKey,
            initialExchangeBytes: &initialExchangeBytes,
            allocator: allocator,
            expectedKeySizes: expectedKeySizes
        )
        guard message.hostKey.isValidSignature(message.signature, for: hash) else {
            throw NIOSSHError.invalidExchangeHashSignature
        }
        return result
    }

    private func finish(
        theirPublic: ByteBuffer,
        hostKey: NIOSSHPublicKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, Variant.Hasher.Digest) {
        guard let group = self.group, let modulus = self.modulus, let secret = self.secret,
            let ourPublic = self.ourPublic
        else {
            throw NIOSSHError.protocolViolation(protocolName: "key exchange", violation: "no group")
        }
        let theirs = try DiffieHellmanParameters.unsigned(theirPublic)
        try DiffieHellmanParameters.checkRange(theirs, prime: group.prime)
        let shared = modulus.power(theirs, exponent: secret, exponentBits: DiffieHellmanParameters.exponentBits)

        // H = HASH(V_C || V_S || I_C || I_S || K_S [|| min || n || max || p || g] || e || f || K)
        initialExchangeBytes.writeCompositeSSHString { $0.writeSSHHostKey(hostKey) }
        if Self.isGroupExchange {
            initialExchangeBytes.writeInteger(DiffieHellmanParameters.groupExchangeMinimum)
            initialExchangeBytes.writeInteger(DiffieHellmanParameters.groupExchangePreferred)
            initialExchangeBytes.writeInteger(DiffieHellmanParameters.groupExchangeMaximum)
            initialExchangeBytes.writeBytes(SSHKeyDerivation.mpint(group.prime.bigEndianBytes))
            initialExchangeBytes.writeBytes(SSHKeyDerivation.mpint(group.generator.bigEndianBytes))
        }
        let ours = SSHKeyDerivation.mpint(ourPublic.bigEndianBytes)
        let their = SSHKeyDerivation.mpint(theirs.bigEndianBytes)
        if self.ourRole.isClient {
            initialExchangeBytes.writeBytes(ours)
            initialExchangeBytes.writeBytes(their)
        } else {
            initialExchangeBytes.writeBytes(their)
            initialExchangeBytes.writeBytes(ours)
        }
        let sharedBytes = shared.bigEndianBytes
        var hasher = Variant.Hasher()
        hasher.update(data: initialExchangeBytes.readableBytesView)
        hasher.update(data: SSHKeyDerivation.mpint(sharedBytes))
        let exchangeHash = hasher.finalize()
        let hashBytes = Array(exchangeHash)

        let sessionID = self.previousSessionIdentifier ?? ByteBuffer(bytes: hashBytes)
        let keys = SSHKeyDerivation.sessionKeys(
            Variant.Hasher.self,
            sharedSecret: sharedBytes,
            exchangeHash: hashBytes,
            sessionID: Array(sessionID.readableBytesView),
            sizes: expectedKeySizes,
            isClient: self.ourRole.isClient
        )
        return (KeyExchangeResult(sessionID: sessionID, keys: keys), exchangeHash)
    }
}
