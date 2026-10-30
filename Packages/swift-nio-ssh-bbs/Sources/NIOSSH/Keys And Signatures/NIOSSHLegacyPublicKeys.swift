//===----------------------------------------------------------------------===//
//
// AnsiView patch (see PATCHES.md): RSA host keys (RFC 4253 ssh-rsa, RFC 8332 rsa-sha2-256 and
// rsa-sha2-512), verified with Apple's Security framework, and DSA host keys (RFC 4253 ssh-dss),
// verified with SSHBigUInt. Verification only: this package never signs with these keys.
//
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

import Crypto
import Foundation
import NIOCore

#if canImport(Security)
import Security
#endif

/// The three RSA signature algorithms and their wire names.
enum RSASignatureAlgorithm: String, Sendable, CaseIterable {
    case sha1 = "ssh-rsa"
    case sha256 = "rsa-sha2-256"
    case sha512 = "rsa-sha2-512"
}

/// Reads an mpint body (no length) as an unsigned value; nil when negative.
private func unsignedMPIntBody(_ bytes: [UInt8]) -> [UInt8]? {
    if let first = bytes.first, first & 0x80 != 0 { return nil }
    return Array(bytes.drop { $0 == 0 })
}

/// An RSA public key, kept as the exact bytes the server sent so that the exchange hash and the
/// known hosts fingerprint use them unchanged.
struct NIOSSHRSAPublicKey: Hashable, Sendable {
    /// The key blob after the "ssh-rsa" string: `mpint e`, `mpint n`, as received.
    let blobWithoutPrefix: [UInt8]
    let modulus: [UInt8]
    let exponent: [UInt8]

    static let minimumModulusBits = 1024
    static let maximumModulusBits = 16384

    var modulusBits: Int { SSHBigUInt(bigEndianBytes: self.modulus).bitWidth }

    init(exponentMPInt: [UInt8], modulusMPInt: [UInt8], blobWithoutPrefix: [UInt8]) throws {
        guard let exponent = unsignedMPIntBody(exponentMPInt), let modulus = unsignedMPIntBody(modulusMPInt),
            let lastE = exponent.last, lastE & 1 == 1, SSHBigUInt(bigEndianBytes: exponent).bitWidth >= 2,
            exponent.count <= modulus.count
        else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "invalid RSA key")
        }
        let bits = SSHBigUInt(bigEndianBytes: modulus).bitWidth
        guard bits >= Self.minimumModulusBits, bits <= Self.maximumModulusBits, modulus.last! & 1 == 1 else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "RSA key of \(bits) bits is not accepted")
        }
        self.exponent = exponent
        self.modulus = modulus
        self.blobWithoutPrefix = blobWithoutPrefix
    }

    /// PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }` in DER.
    static func pkcs1DER(modulus: [UInt8], exponent: [UInt8]) -> [UInt8] {
        func length(_ count: Int) -> [UInt8] {
            if count < 0x80 { return [UInt8(count)] }
            var bytes: [UInt8] = []
            var value = count
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ value: [UInt8]) -> [UInt8] {
            var body = Array(value.drop { $0 == 0 })
            if body.isEmpty || body[0] & 0x80 != 0 { body.insert(0, at: 0) }
            return [0x02] + length(body.count) + body
        }
        let content = integer(modulus) + integer(exponent)
        return [0x30] + length(content.count) + content
    }

    /// Verifies a PKCS#1 v1.5 signature over `message` (the exchange hash, or signed data).
    func isValid(signature: [UInt8], algorithm: RSASignatureAlgorithm, message: [UInt8]) -> Bool {
        #if canImport(Security)
        let size = self.modulus.count
        guard !signature.isEmpty, signature.count <= size else { return false }
        // Some servers drop leading zero bytes of the signature (OpenSSH pads them back too).
        let padded = [UInt8](repeating: 0, count: size - signature.count) + signature
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: self.modulusBits,
        ]
        let der = Self.pkcs1DER(modulus: self.modulus, exponent: self.exponent)
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil) else {
            return false
        }
        let secAlgorithm: SecKeyAlgorithm
        switch algorithm {
        case .sha1: secAlgorithm = .rsaSignatureMessagePKCS1v15SHA1
        case .sha256: secAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
        case .sha512: secAlgorithm = .rsaSignatureMessagePKCS1v15SHA512
        }
        return SecKeyVerifySignature(key, secAlgorithm, Data(message) as CFData, Data(padded) as CFData, nil)
        #else
        return false
        #endif
    }
}

/// A DSA public key (ssh-dss: 1024 bit p, 160 bit q, SHA-1), kept as received.
struct NIOSSHDSAPublicKey: Hashable, Sendable {
    let blobWithoutPrefix: [UInt8]
    let p: SSHBigUInt
    let q: SSHBigUInt
    let g: SSHBigUInt
    let y: SSHBigUInt

    init(p: [UInt8], q: [UInt8], g: [UInt8], y: [UInt8], blobWithoutPrefix: [UInt8]) throws {
        guard let p = unsignedMPIntBody(p), let q = unsignedMPIntBody(q), let g = unsignedMPIntBody(g),
            let y = unsignedMPIntBody(y)
        else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "invalid DSA key")
        }
        self.p = SSHBigUInt(bigEndianBytes: p)
        self.q = SSHBigUInt(bigEndianBytes: q)
        self.g = SSHBigUInt(bigEndianBytes: g)
        self.y = SSHBigUInt(bigEndianBytes: y)
        let one = SSHBigUInt(limbs: [1])
        guard (1024...3072).contains(self.p.bitWidth), self.q.bitWidth == 160, self.p.bit(0), self.q.bit(0),
            one < self.g, self.g < self.p, one < self.y, self.y < self.p
        else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "DSA key parameters are not accepted")
        }
        self.blobWithoutPrefix = blobWithoutPrefix
    }

    /// FIPS 186 verification of the 40 byte `r || s` over SHA-1(message). Public values only.
    func isValid(signature: [UInt8], message: [UInt8]) -> Bool {
        guard signature.count == 40 else { return false }
        let r = SSHBigUInt(bigEndianBytes: signature[0..<20])
        let s = SSHBigUInt(bigEndianBytes: signature[20..<40])
        guard !r.isZero, !s.isZero, r < self.q, s < self.q,
            let modQ = SSHMontgomeryModulus(self.q), let modP = SSHMontgomeryModulus(self.p)
        else {
            return false
        }
        let digest = SSHBigUInt(bigEndianBytes: Array(Insecure.SHA1.hash(data: message)))
        // q is prime, so s^-1 = s^(q-2) mod q.
        let qMinus2 = self.q.subtracting(SSHBigUInt(limbs: [2]))
        let w = modQ.power(s, exponent: qMinus2, exponentBits: qMinus2.bitWidth)
        let u1 = digest.remainder(dividingBy: self.q).multiplied(by: w).remainder(dividingBy: self.q)
        let u2 = r.multiplied(by: w).remainder(dividingBy: self.q)
        let gu1 = modP.power(self.g, exponent: u1, exponentBits: max(u1.bitWidth, 1))
        let yu2 = modP.power(self.y, exponent: u2, exponentBits: max(u2.bitWidth, 1))
        let v = gu1.multiplied(by: yu2).remainder(dividingBy: self.p).remainder(dividingBy: self.q)
        return v == r
    }
}

extension SSHBigUInt {
    /// The full product (schoolbook; public values only).
    func multiplied(by other: SSHBigUInt) -> SSHBigUInt {
        guard !self.isZero, !other.isZero else { return SSHBigUInt(limbs: []) }
        var result = [UInt64](repeating: 0, count: self.limbs.count + other.limbs.count)
        for i in 0..<self.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<other.limbs.count {
                let (hi, lo) = self.limbs[i].multipliedFullWidth(by: other.limbs[j])
                let (s1, c1) = result[i + j].addingReportingOverflow(lo)
                let (s2, c2) = s1.addingReportingOverflow(carry)
                result[i + j] = s2
                carry = hi &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            result[i + other.limbs.count] = carry
        }
        return SSHBigUInt(limbs: result)
    }

    /// `self mod divisor` by shift and subtract (variable time; public values only).
    func remainder(dividingBy divisor: SSHBigUInt) -> SSHBigUInt {
        precondition(!divisor.isZero, "division by zero")
        guard !(self < divisor) else { return self }
        var remainder = SSHBigUInt(limbs: [])
        for index in stride(from: self.bitWidth - 1, through: 0, by: -1) {
            var limbs = remainder.limbs + [0]
            var carry: UInt64 = self.bit(index) ? 1 : 0
            for position in 0..<limbs.count {
                let next = limbs[position] >> 63
                limbs[position] = (limbs[position] << 1) | carry
                carry = next
            }
            remainder = SSHBigUInt(limbs: limbs)
            if !(remainder < divisor) {
                remainder = remainder.subtracting(divisor)
            }
        }
        return remainder
    }
}
