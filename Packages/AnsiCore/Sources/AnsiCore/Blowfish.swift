import CryptoKit
import Foundation

/// Blowfish, only as far as `bcrypt_pbkdf` needs it (OpenSSH uses bcrypt_pbkdf to turn a key
/// file's passphrase into its AES key). Written from Schneier's description and OpenBSD's
/// blowfish.c structure; the initial state is computed pi (`BlowfishPi.swift`).
final class Blowfish {
    private var p: [UInt32]
    private var s: [UInt32]

    /// The initial state, not yet keyed (bcrypt starts here).
    init() {
        p = Array(Self.piWords[0..<18])
        s = Array(Self.piWords[18...])
    }

    /// Standard Blowfish key schedule.
    convenience init(key: [UInt8]) {
        self.init()
        expand0(key: key)
    }

    @inline(__always) private func f(_ x: UInt32) -> UInt32 {
        let a = s[Int(x >> 24)]
        let b = s[256 + Int((x >> 16) & 0xFF)]
        let c = s[512 + Int((x >> 8) & 0xFF)]
        let d = s[768 + Int(x & 0xFF)]
        return ((a &+ b) ^ c) &+ d
    }

    func encrypt(_ left: inout UInt32, _ right: inout UInt32) {
        var l = left ^ p[0]
        var r = right
        var i = 1
        while i <= 16 {
            r ^= f(l) ^ p[i]
            l ^= f(r) ^ p[i + 1]
            i += 2
        }
        left = r ^ p[17]
        right = l
    }

    /// Four bytes big endian from `data`, wrapping around (OpenBSD's Blowfish_stream2word).
    private static func word(_ data: [UInt8], _ j: inout Int) -> UInt32 {
        var w: UInt32 = 0
        for _ in 0..<4 {
            if j >= data.count { j = 0 }
            w = w << 8 | UInt32(data.isEmpty ? 0 : data[j])
            j += 1
        }
        return w
    }

    private func keyP(_ key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.word(key, &j) }
    }

    /// Blowfish_expand0state: the key schedule without salt.
    func expand0(key: [UInt8]) {
        keyP(key)
        var l: UInt32 = 0, r: UInt32 = 0
        var i = 0
        while i < 18 {
            encrypt(&l, &r)
            p[i] = l; p[i + 1] = r
            i += 2
        }
        i = 0
        while i < 1024 {
            encrypt(&l, &r)
            s[i] = l; s[i + 1] = r
            i += 2
        }
    }

    /// Blowfish_expandstate: the key schedule mixing in salt (`data`).
    func expand(data: [UInt8], key: [UInt8]) {
        keyP(key)
        var j = 0
        var l: UInt32 = 0, r: UInt32 = 0
        var i = 0
        while i < 18 {
            l ^= Self.word(data, &j)
            r ^= Self.word(data, &j)
            encrypt(&l, &r)
            p[i] = l; p[i + 1] = r
            i += 2
        }
        i = 0
        while i < 1024 {
            l ^= Self.word(data, &j)
            r ^= Self.word(data, &j)
            encrypt(&l, &r)
            s[i] = l; s[i + 1] = r
            i += 2
        }
    }
}

/// OpenBSD's bcrypt_pbkdf (the KDF of OpenSSH key files).
enum BCryptPBKDF {
    private static let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)

    static func hash(pass: [UInt8], salt: [UInt8]) -> [UInt8] {
        let bf = Blowfish()
        bf.expand(data: salt, key: pass)
        for _ in 0..<64 {
            bf.expand0(key: salt)
            bf.expand0(key: pass)
        }
        var words = [UInt32](repeating: 0, count: 8)
        for i in 0..<8 {
            var w: UInt32 = 0
            for k in 0..<4 { w = w << 8 | UInt32(magic[4 * i + k]) }
            words[i] = w
        }
        for _ in 0..<64 {
            var i = 0
            while i < 8 {
                var l = words[i], r = words[i + 1]
                bf.encrypt(&l, &r)
                words[i] = l
                words[i + 1] = r
                i += 2
            }
        }
        var out: [UInt8] = []
        for w in words {
            out += [UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8(w >> 24)]
        }
        return out
    }

    static func derive(password: [UInt8], salt: [UInt8], rounds: Int, length: Int) -> [UInt8] {
        guard rounds > 0, length > 0 else { return [] }
        let stride = (length + 31) / 32
        let amount = (length + stride - 1) / stride
        let sha2pass = Array(SHA512.hash(data: password))
        var key = [UInt8](repeating: 0, count: length)
        var remaining = length
        var count: UInt32 = 1
        while remaining > 0 {
            let countSalt = salt + [UInt8(count >> 24), UInt8((count >> 16) & 0xFF), UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)]
            var tmp = hash(pass: sha2pass, salt: Array(SHA512.hash(data: countSalt)))
            var out = tmp
            if rounds > 1 {
                for _ in 1..<rounds {
                    tmp = hash(pass: sha2pass, salt: Array(SHA512.hash(data: tmp)))
                    for i in out.indices { out[i] ^= tmp[i] }
                }
            }
            let take = min(amount, remaining)
            var written = 0
            for i in 0..<take {
                let dest = i * stride + Int(count - 1)
                if dest >= length { break }
                key[dest] = out[i]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return key
    }
}
