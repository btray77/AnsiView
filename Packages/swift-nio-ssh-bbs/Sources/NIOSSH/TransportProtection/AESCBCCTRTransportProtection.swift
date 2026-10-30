//===----------------------------------------------------------------------===//
//
// AnsiView patch (see PATCHES.md): block ciphers for older SSH servers, with
// encrypt-and-MAC HMAC (RFC 4253 section 6.4, RFC 6668):
//   aes128/192/256-ctr (RFC 4344), aes128/192/256-cbc and 3des-cbc (RFC 4253);
//   hmac-sha2-256, hmac-sha2-512 (RFC 6668), hmac-sha1, hmac-sha1-96, hmac-md5, hmac-md5-96 (RFC 4253).
//
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

#if canImport(CommonCrypto)
import CommonCrypto
import Crypto
import NIOCore

// MARK: Block cipher

enum SSHAESMode: Sendable {
    case ctr
    case cbc
}

/// A block cipher encryptor or decryptor whose CTR counter or CBC chaining value carries over
/// from one call to the next, as SSH requires across packets (CommonCrypto, a system framework).
final class SSHAESCipher {
    private var cryptor: CCCryptorRef?
    let blockSize: Int

    /// AES (16, 24 or 32 byte keys) or, with `tripleDES`, 3DES-EDE (24 byte keys, 8 byte blocks).
    init(mode: SSHAESMode, encrypt: Bool, key: [UInt8], iv: [UInt8], tripleDES: Bool = false) throws {
        self.blockSize = tripleDES ? 8 : 16
        guard tripleDES ? key.count == 24 : [16, 24, 32].contains(key.count), iv.count == self.blockSize,
            !(tripleDES && mode == .ctr)
        else {
            throw NIOSSHError.invalidKeySize
        }
        var cryptor: CCCryptorRef?
        let status = CCCryptorCreateWithMode(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
            CCMode(mode == .ctr ? kCCModeCTR : kCCModeCBC),
            CCAlgorithm(tripleDES ? kCCAlgorithm3DES : kCCAlgorithmAES),
            CCPadding(ccNoPadding),
            iv,
            key,
            key.count,
            nil,
            0,
            0,
            CCModeOptions(mode == .ctr ? kCCModeOptionCTR_BE : 0),
            &cryptor
        )
        guard status == kCCSuccess, let cryptor else {
            throw NIOSSHError.invalidKeySize
        }
        self.cryptor = cryptor
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    /// Encrypts or decrypts a whole number of blocks.
    func process(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count % self.blockSize == 0 else { throw NIOSSHError.invalidEncryptedPacketLength }
        guard !input.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCryptorUpdate(self.cryptor, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess, moved == input.count else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }
        return output
    }
}

// MARK: Algorithms

protocol SSHAESCipherAlgorithm: _NIOSSHSendableMetatype {
    static var name: String { get }
    static var keySize: Int { get }
    static var mode: SSHAESMode { get }
    static var isTripleDES: Bool { get }
}

extension SSHAESCipherAlgorithm {
    static var isTripleDES: Bool { false }
    static var blockSize: Int { Self.isTripleDES ? 8 : 16 }
}

enum AES128CTRAlgorithm: SSHAESCipherAlgorithm {
    static let name = "aes128-ctr"
    static let keySize = 16
    static let mode = SSHAESMode.ctr
}

enum AES192CTRAlgorithm: SSHAESCipherAlgorithm {
    static let name = "aes192-ctr"
    static let keySize = 24
    static let mode = SSHAESMode.ctr
}

enum AES256CTRAlgorithm: SSHAESCipherAlgorithm {
    static let name = "aes256-ctr"
    static let keySize = 32
    static let mode = SSHAESMode.ctr
}

enum AES128CBCAlgorithm: SSHAESCipherAlgorithm {
    static let name = "aes128-cbc"
    static let keySize = 16
    static let mode = SSHAESMode.cbc
}

enum AES192CBCAlgorithm: SSHAESCipherAlgorithm {
    static let name = "aes192-cbc"
    static let keySize = 24
    static let mode = SSHAESMode.cbc
}

enum AES256CBCAlgorithm: SSHAESCipherAlgorithm {
    static let name = "aes256-cbc"
    static let keySize = 32
    static let mode = SSHAESMode.cbc
}

enum TripleDESCBCAlgorithm: SSHAESCipherAlgorithm {
    static let name = "3des-cbc"
    static let keySize = 24
    static let mode = SSHAESMode.cbc
    static var isTripleDES: Bool { true }
}

protocol SSHHMACAlgorithm: _NIOSSHSendableMetatype {
    static var name: String { get }
    /// Key length in bytes (the digest size, RFC 4253 section 6.4 and RFC 6668).
    static var keyLength: Int { get }
    /// Bytes of the code sent on the wire (12 for the -96 variants).
    static var length: Int { get }
    static func code(key: SymmetricKey, data: [UInt8]) -> [UInt8]
}

extension SSHHMACAlgorithm {
    static var length: Int { Self.keyLength }
}

enum HMACSHA1Algorithm: SSHHMACAlgorithm {
    static let name = "hmac-sha1"
    static let keyLength = 20
    static func code(key: SymmetricKey, data: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
    }
}

enum HMACSHA196Algorithm: SSHHMACAlgorithm {
    static let name = "hmac-sha1-96"
    static let keyLength = 20
    static var length: Int { 12 }
    static func code(key: SymmetricKey, data: [UInt8]) -> [UInt8] {
        Array(HMACSHA1Algorithm.code(key: key, data: data).prefix(12))
    }
}

enum HMACMD5Algorithm: SSHHMACAlgorithm {
    static let name = "hmac-md5"
    static let keyLength = 16
    static func code(key: SymmetricKey, data: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.MD5>.authenticationCode(for: data, using: key))
    }
}

enum HMACMD596Algorithm: SSHHMACAlgorithm {
    static let name = "hmac-md5-96"
    static let keyLength = 16
    static var length: Int { 12 }
    static func code(key: SymmetricKey, data: [UInt8]) -> [UInt8] {
        Array(HMACMD5Algorithm.code(key: key, data: data).prefix(12))
    }
}

enum HMACSHA256Algorithm: SSHHMACAlgorithm {
    static let name = "hmac-sha2-256"
    static let keyLength = 32
    static func code(key: SymmetricKey, data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }
}

enum HMACSHA512Algorithm: SSHHMACAlgorithm {
    static let name = "hmac-sha2-512"
    static let keyLength = 64
    static func code(key: SymmetricKey, data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA512>.authenticationCode(for: data, using: key))
    }
}

// MARK: Transport protection

/// A block cipher in CTR or CBC mode with an HMAC over `sequence_number || unencrypted_packet`
/// (encrypt-and-MAC; the -etm variants are not offered, see PATCHES.md).
final class AESCBCCTRTransportProtection<Cipher: SSHAESCipherAlgorithm, MAC: SSHHMACAlgorithm>:
    NIOSSHTransportProtection, _NIOSSHSendableMetatype
{
    static var cipherName: String { Cipher.name }
    static var macName: String? { MAC.name }
    static var cipherBlockSize: Int { Cipher.blockSize }
    static var keySizes: ExpectedKeySizes {
        ExpectedKeySizes(ivSize: Cipher.blockSize, encryptionKeySize: Cipher.keySize, macKeySize: MAC.keyLength)
    }

    var macBytes: Int { MAC.length }
    var lengthEncrypted: Bool { true }

    private var encryptor: SSHAESCipher
    private var decryptor: SSHAESCipher
    private var outboundMACKey: SymmetricKey
    private var inboundMACKey: SymmetricKey
    /// The first block of the packet being read, already decrypted by `decryptFirstBlock`.
    private var firstBlock: [UInt8]?

    init(initialKeys: NIOSSHSessionKeys) throws {
        (self.encryptor, self.decryptor, self.outboundMACKey, self.inboundMACKey) = try Self.make(initialKeys)
    }

    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        (self.encryptor, self.decryptor, self.outboundMACKey, self.inboundMACKey) = try Self.make(newKeys)
        self.firstBlock = nil
    }

    private static func make(
        _ keys: NIOSSHSessionKeys
    ) throws -> (SSHAESCipher, SSHAESCipher, SymmetricKey, SymmetricKey) {
        guard keys.outboundEncryptionKey.bitCount == Cipher.keySize * 8,
            keys.inboundEncryptionKey.bitCount == Cipher.keySize * 8,
            keys.outboundMACKey.bitCount == MAC.keyLength * 8,
            keys.inboundMACKey.bitCount == MAC.keyLength * 8
        else {
            throw NIOSSHError.invalidKeySize
        }
        let encryptor = try SSHAESCipher(
            mode: Cipher.mode,
            encrypt: true,
            key: keys.outboundEncryptionKey.withUnsafeBytes { Array($0) },
            iv: keys.initialOutboundIV,
            tripleDES: Cipher.isTripleDES
        )
        let decryptor = try SSHAESCipher(
            mode: Cipher.mode,
            encrypt: false,
            key: keys.inboundEncryptionKey.withUnsafeBytes { Array($0) },
            iv: keys.initialInboundIV,
            tripleDES: Cipher.isTripleDES
        )
        return (encryptor, decryptor, keys.outboundMACKey, keys.inboundMACKey)
    }

    func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        let block = Cipher.blockSize
        guard let ciphertext = source.getBytes(at: source.readerIndex, length: block) else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }
        let plaintext = try self.decryptor.process(ciphertext)
        // packet_length: the whole packet (length field included) must be a whole number of
        // blocks and at least 16 bytes (RFC 4253 section 6). Checked before waiting for more bytes.
        let length =
            UInt32(plaintext[0]) << 24 | UInt32(plaintext[1]) << 16 | UInt32(plaintext[2]) << 8 | UInt32(plaintext[3])
        guard (length &+ 4) % UInt32(block) == 0, length >= 12 else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }
        source.setBytes(plaintext, at: source.readerIndex)
        self.firstBlock = plaintext
    }

    func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        guard let firstBlock = self.firstBlock else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }
        self.firstBlock = nil
        let block = Cipher.blockSize
        let macLength = MAC.length
        guard source.readableBytes >= block + macLength, (source.readableBytes - macLength) % block == 0,
            var rest = source.getBytes(
                at: source.readerIndex + block,
                length: source.readableBytes - block - macLength
            ),
            let received = source.getBytes(at: source.writerIndex - macLength, length: macLength)
        else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }
        rest = try self.decryptor.process(rest)
        let packet = firstBlock + rest

        // MAC over sequence_number || unencrypted packet, compared in constant time, before the
        // padding or payload is looked at.
        let expected = MAC.code(key: self.inboundMACKey, data: Self.macInput(sequenceNumber, packet))
        var difference: UInt8 = 0
        for index in 0..<macLength {
            difference |= expected[index] ^ received[index]
        }
        guard difference == 0 else {
            throw NIOSSHError.invalidPacketFormat
        }

        // packet_length || padding_length || payload || padding
        let paddingLength = Int(packet[4])
        guard paddingLength >= 4 else { throw NIOSSHError.insufficientPadding }
        guard 5 + paddingLength <= packet.count else { throw NIOSSHError.excessPadding }
        source.moveReaderIndex(to: source.writerIndex)
        return ByteBuffer(bytes: packet[5..<(packet.count - paddingLength)])
    }

    func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        guard let packet = destination.getBytes(at: destination.readerIndex, length: destination.readableBytes),
            packet.count % Cipher.blockSize == 0
        else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }
        let mac = MAC.code(key: self.outboundMACKey, data: Self.macInput(sequenceNumber, packet))
        let ciphertext = try self.encryptor.process(packet)
        destination.setBytes(ciphertext, at: destination.readerIndex)
        destination.writeBytes(mac.prefix(MAC.length))
    }

    private static func macInput(_ sequenceNumber: UInt32, _ packet: [UInt8]) -> [UInt8] {
        var input = [UInt8]()
        input.reserveCapacity(4 + packet.count)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { input.append(contentsOf: $0) }
        input.append(contentsOf: packet)
        return input
    }
}

/// Every cipher and MAC pair, in the order offered: CTR before CBC, larger keys first, 3DES last,
/// and for each cipher the MACs strongest first.
enum AESCBCCTRSchemes {
    typealias Scheme = (NIOSSHTransportProtection & _NIOSSHSendableMetatype).Type

    static let ciphersInOrder: [String] = [
        "aes256-ctr", "aes192-ctr", "aes128-ctr", "aes256-cbc", "aes192-cbc", "aes128-cbc", "3des-cbc",
    ]
    static let macsInOrder: [String] = [
        "hmac-sha2-256", "hmac-sha2-512", "hmac-sha1", "hmac-sha1-96", "hmac-md5", "hmac-md5-96",
    ]

    private static func withEveryMAC<C: SSHAESCipherAlgorithm>(_ cipher: C.Type) -> [Scheme] {
        [
            AESCBCCTRTransportProtection<C, HMACSHA256Algorithm>.self,
            AESCBCCTRTransportProtection<C, HMACSHA512Algorithm>.self,
            AESCBCCTRTransportProtection<C, HMACSHA1Algorithm>.self,
            AESCBCCTRTransportProtection<C, HMACSHA196Algorithm>.self,
            AESCBCCTRTransportProtection<C, HMACMD5Algorithm>.self,
            AESCBCCTRTransportProtection<C, HMACMD596Algorithm>.self,
        ]
    }

    static let all: [Scheme] =
        withEveryMAC(AES256CTRAlgorithm.self) + withEveryMAC(AES192CTRAlgorithm.self)
        + withEveryMAC(AES128CTRAlgorithm.self) + withEveryMAC(AES256CBCAlgorithm.self)
        + withEveryMAC(AES192CBCAlgorithm.self) + withEveryMAC(AES128CBCAlgorithm.self)
        + withEveryMAC(TripleDESCBCAlgorithm.self)
}
#endif
