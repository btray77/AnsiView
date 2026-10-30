import CommonCrypto
import CryptoKit
import Foundation

/// Why a private key file cannot be used, in words for the status line or an alert.
public enum SSHKeyFileError: Error, Equatable {
    case notAKey
    case needsPassphrase
    case wrongPassphrase
    case unsupportedKeyType(String)
    case unsupportedCipher(String)
    case damaged
    /// More bcrypt rounds than `SSHKeyFile.maxRounds` (each costs milliseconds of CPU).
    case tooManyRounds(Int)

    public var message: String {
        switch self {
        case .notAKey:
            return "The chosen file is not an SSH private key (OpenSSH or PEM format)."
        case .needsPassphrase:
            return "The SSH key file is protected by a passphrase. Type it in the entry's Key passphrase field."
        case .wrongPassphrase:
            return "The key passphrase is wrong, so the SSH key file could not be opened."
        case .unsupportedKeyType(let type):
            return "\(type) keys are not supported by AnsiView's SSH (it signs with Ed25519 and ECDSA keys only). Make an Ed25519 key with: ssh-keygen -t ed25519"
        case .unsupportedCipher(let cipher):
            return "The key file is encrypted with \(cipher), which AnsiView cannot open. Re-save it with: ssh-keygen -p -f <file>"
        case .damaged:
            return "The SSH key file is damaged or cut short."
        case .tooManyRounds(let rounds):
            return "The key file asks for \(rounds) passphrase rounds, more than AnsiView accepts (\(SSHKeyFile.maxRounds)); opening it would take minutes. Re-save it with: ssh-keygen -p -a 16 -f <file>"
        }
    }
}

/// A private key AnsiView can sign with (what swift-nio-ssh accepts).
public enum SSHPrivateKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    public var typeName: String {
        switch self {
        case .ed25519: return "ssh-ed25519"
        case .p256: return "ecdsa-sha2-nistp256"
        case .p384: return "ecdsa-sha2-nistp384"
        case .p521: return "ecdsa-sha2-nistp521"
        }
    }

    /// The public key in SSH wire format (what a `.pub` file holds in base64).
    public var publicKeyBlob: Data {
        var w = SSHWire.Writer()
        w.string(Array(typeName.utf8))
        switch self {
        case .ed25519(let k): w.string(Array(k.publicKey.rawRepresentation))
        case .p256(let k): w.string(Array("nistp256".utf8)); w.string(Array(k.publicKey.x963Representation))
        case .p384(let k): w.string(Array("nistp384".utf8)); w.string(Array(k.publicKey.x963Representation))
        case .p521(let k): w.string(Array("nistp521".utf8)); w.string(Array(k.publicKey.x963Representation))
        }
        return Data(w.bytes)
    }
}

/// SSH wire format pieces (RFC 4251 strings and integers).
enum SSHWire {
    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func uint32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw SSHKeyFileError.damaged }
            let v = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            offset += 4
            return v
        }

        mutating func string() throws -> [UInt8] {
            let length = Int(try uint32())
            guard length <= bytes.count - offset else { throw SSHKeyFileError.damaged }
            defer { offset += length }
            return Array(bytes[offset..<(offset + length)])
        }

        mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }

        var rest: [UInt8] { Array(bytes[offset...]) }
    }

    struct Writer {
        var bytes: [UInt8] = []
        mutating func uint32(_ v: UInt32) { bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        mutating func string(_ s: [UInt8]) { uint32(UInt32(s.count)); bytes += s }
    }
}

/// Reads SSH private key files: OpenSSH (`openssh-key-v1`, unencrypted or bcrypt with
/// aes256-ctr, aes128-ctr, aes192-ctr, aes256-cbc, aes128-cbc, aes192-cbc) and PEM ECDSA keys
/// (`EC PRIVATE KEY`, PKCS#8 `PRIVATE KEY`).
public enum SSHKeyFile {
    private static let openSSHMagic = Array("openssh-key-v1".utf8) + [0]
    /// OpenSSH writes 16 by default; `ssh-keygen -a` users pick 100 or so. About 3 ms a round.
    public static let maxRounds = 1024

    /// True for a passphrase protected file (asks before the user types a passphrase).
    public static func isEncrypted(_ data: Data) -> Bool {
        guard let body = try? openSSHBody(data) else {
            let text = String(decoding: data, as: UTF8.self)
            return text.contains("ENCRYPTED")
        }
        var r = SSHWire.Reader(body)
        r.offset = openSSHMagic.count
        return ((try? r.text()) ?? "none") != "none"
    }

    public static func parse(_ data: Data, passphrase: String?) throws -> SSHPrivateKey {
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            return try parseOpenSSH(try openSSHBody(data), passphrase: passphrase)
        }
        if text.contains("-----BEGIN RSA PRIVATE KEY-----") { throw SSHKeyFileError.unsupportedKeyType("ssh-rsa") }
        if text.contains("-----BEGIN DSA PRIVATE KEY-----") { throw SSHKeyFileError.unsupportedKeyType("ssh-dss") }
        if text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") || text.contains("Proc-Type: 4,ENCRYPTED") {
            throw SSHKeyFileError.unsupportedCipher("PEM encryption")
        }
        if text.contains("-----BEGIN EC PRIVATE KEY-----") || text.contains("-----BEGIN PRIVATE KEY-----") {
            if let k = try? P256.Signing.PrivateKey(pemRepresentation: text) { return .p256(k) }
            if let k = try? P384.Signing.PrivateKey(pemRepresentation: text) { return .p384(k) }
            if let k = try? P521.Signing.PrivateKey(pemRepresentation: text) { return .p521(k) }
            if let key = sec1(text) { return key }
            if text.contains("-----BEGIN PRIVATE KEY-----") { throw SSHKeyFileError.unsupportedKeyType("PKCS#8 Ed25519 or RSA") }
            throw SSHKeyFileError.damaged
        }
        throw SSHKeyFileError.notAKey
    }

    /// SEC1 `EC PRIVATE KEY` (what `ssh-keygen -m PEM` writes): SEQUENCE { INTEGER 1, OCTET STRING d, ... };
    /// the curve follows from the length of d.
    private static func sec1(_ text: String) -> SSHPrivateKey? {
        guard let start = text.range(of: "-----BEGIN EC PRIVATE KEY-----"),
              let end = text.range(of: "-----END EC PRIVATE KEY-----", range: start.upperBound..<text.endIndex),
              let der = Data(base64Encoded: String(text[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace })) else {
            return nil
        }
        let b = [UInt8](der)
        guard b.count > 8, b[0] == 0x30 else { return nil }
        var i = 1
        if b[i] & 0x80 != 0 { i += Int(b[i] & 0x7F) }
        i += 1
        guard i + 5 < b.count, b[i] == 0x02, b[i + 1] == 0x01, b[i + 2] == 0x01, b[i + 3] == 0x04 else { return nil }
        let length = Int(b[i + 4])
        let from = i + 5
        guard from + length <= b.count else { return nil }
        let d = Array(b[from..<(from + length)])
        switch length {
        case 32: return (try? P256.Signing.PrivateKey(rawRepresentation: d)).map { .p256($0) }
        case 48: return (try? P384.Signing.PrivateKey(rawRepresentation: d)).map { .p384($0) }
        case 65, 66: return (try? P521.Signing.PrivateKey(rawRepresentation: try fixed(d, 66))).map { .p521($0) }
        default: return nil
        }
    }

    private static func openSSHBody(_ data: Data) throws -> [UInt8] {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "-----BEGIN OPENSSH PRIVATE KEY-----"),
              let end = text.range(of: "-----END OPENSSH PRIVATE KEY-----", range: start.upperBound..<text.endIndex) else {
            throw SSHKeyFileError.notAKey
        }
        let base64 = text[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let body = Data(base64Encoded: String(base64)).map({ [UInt8]($0) }),
              body.starts(with: openSSHMagic) else { throw SSHKeyFileError.notAKey }
        return body
    }

    private static func parseOpenSSH(_ body: [UInt8], passphrase: String?) throws -> SSHPrivateKey {
        var r = SSHWire.Reader(body)
        r.offset = openSSHMagic.count
        let cipher = try r.text()
        let kdf = try r.text()
        let kdfOptions = try r.string()
        guard try r.uint32() == 1 else { throw SSHKeyFileError.damaged }
        _ = try r.string()  // public key
        var secret = try r.string()
        if cipher != "none" {
            guard kdf == "bcrypt" else { throw SSHKeyFileError.unsupportedCipher("\(cipher) with \(kdf)") }
            guard let spec = cipherSpec(cipher) else { throw SSHKeyFileError.unsupportedCipher(cipher) }
            guard let passphrase, !passphrase.isEmpty else { throw SSHKeyFileError.needsPassphrase }
            var o = SSHWire.Reader(kdfOptions)
            let salt = try o.string()
            let rounds = Int(try o.uint32())
            guard rounds > 0 else { throw SSHKeyFileError.damaged }
            guard rounds <= maxRounds else { throw SSHKeyFileError.tooManyRounds(rounds) }
            let material = BCryptPBKDF.derive(password: Array(passphrase.utf8), salt: salt, rounds: rounds,
                                              length: spec.keyLength + 16)
            secret = try aes(secret, key: Array(material[0..<spec.keyLength]), iv: Array(material[spec.keyLength...]),
                             counter: spec.counter)
        }
        var s = SSHWire.Reader(secret)
        let check1 = try s.uint32()
        let check2 = try s.uint32()
        guard check1 == check2 else {
            throw cipher == "none" ? SSHKeyFileError.damaged : SSHKeyFileError.wrongPassphrase
        }
        let type = try s.text()
        switch type {
        case "ssh-ed25519":
            _ = try s.string()
            let both = try s.string()
            guard both.count == 64 else { throw SSHKeyFileError.damaged }
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: both[0..<32]))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try s.string()  // curve name
            _ = try s.string()  // public point
            let scalar = try s.string()
            switch type {
            case "ecdsa-sha2-nistp256": return .p256(try P256.Signing.PrivateKey(rawRepresentation: fixed(scalar, 32)))
            case "ecdsa-sha2-nistp384": return .p384(try P384.Signing.PrivateKey(rawRepresentation: fixed(scalar, 48)))
            default: return .p521(try P521.Signing.PrivateKey(rawRepresentation: fixed(scalar, 66)))
            }
        default:
            throw SSHKeyFileError.unsupportedKeyType(type)
        }
    }

    /// An mpint scalar at exactly `size` bytes (leading sign zeros dropped, short values padded).
    private static func fixed(_ bytes: [UInt8], _ size: Int) throws -> [UInt8] {
        var b = bytes
        while b.count > size, b.first == 0 { b.removeFirst() }
        guard b.count <= size else { throw SSHKeyFileError.damaged }
        return [UInt8](repeating: 0, count: size - b.count) + b
    }

    private static func cipherSpec(_ name: String) -> (keyLength: Int, counter: Bool)? {
        switch name {
        case "aes128-ctr": return (16, true)
        case "aes192-ctr": return (24, true)
        case "aes256-ctr": return (32, true)
        case "aes128-cbc": return (16, false)
        case "aes192-cbc": return (24, false)
        case "aes256-cbc": return (32, false)
        default: return nil
        }
    }

    private static func aes(_ input: [UInt8], key: [UInt8], iv: [UInt8], counter: Bool) throws -> [UInt8] {
        guard input.count % 16 == 0 else { throw SSHKeyFileError.damaged }
        var cryptor: CCCryptorRef?
        let status = CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(counter ? kCCModeCTR : kCCModeCBC),
                                             CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), iv, key, key.count,
                                             nil, 0, 0, CCModeOptions(counter ? kCCModeOptionCTR_BE : 0), &cryptor)
        guard status == kCCSuccess, let cryptor else { throw SSHKeyFileError.damaged }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let update = CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        guard update == kCCSuccess, moved == input.count else { throw SSHKeyFileError.damaged }
        return output
    }
}
