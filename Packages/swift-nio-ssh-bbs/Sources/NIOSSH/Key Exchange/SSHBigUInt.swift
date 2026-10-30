//===----------------------------------------------------------------------===//
//
// AnsiView patch (see PATCHES.md): fixed width unsigned integers and Montgomery arithmetic for
// finite field Diffie-Hellman (RFC 4253 section 8, RFC 4419, RFC 8268).
//
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

/// An unsigned integer of any size, stored as little endian 64 bit limbs.
///
/// Only the operations Diffie-Hellman needs are here. Values handled by `SSHMontgomeryModulus.power`
/// with a secret exponent are processed in constant time; the helpers on this type (comparison,
/// byte conversion, bit width) are variable time and are only used on public values.
struct SSHBigUInt: Hashable, Sendable {
    /// Little endian limbs, without trailing (most significant) zero limbs.
    private(set) var limbs: [UInt64]

    init(limbs: [UInt64]) {
        var limbs = limbs
        while let last = limbs.last, last == 0 {
            limbs.removeLast()
        }
        self.limbs = limbs
    }

    /// Reads a big endian unsigned integer (leading zero bytes are allowed).
    init<Bytes: Collection>(bigEndianBytes bytes: Bytes) where Bytes.Element == UInt8 {
        var limbs = [UInt64](repeating: 0, count: (bytes.count + 7) / 8)
        var shift: UInt64 = 0
        var index = 0
        for byte in bytes.reversed() {
            limbs[index] |= UInt64(byte) << shift
            shift += 8
            if shift == 64 {
                shift = 0
                index += 1
            }
        }
        self.init(limbs: limbs)
    }

    var isZero: Bool { self.limbs.isEmpty }

    /// The number of significant bits (0 for zero).
    var bitWidth: Int {
        guard let top = self.limbs.last else { return 0 }
        return (self.limbs.count - 1) * 64 + (64 - top.leadingZeroBitCount)
    }

    /// The minimal big endian representation (empty for zero).
    var bigEndianBytes: [UInt8] {
        self.bigEndianBytes(paddedTo: (self.bitWidth + 7) / 8)
    }

    /// The big endian representation, left padded with zeros to `count` bytes.
    func bigEndianBytes(paddedTo count: Int) -> [UInt8] {
        precondition(count * 8 >= self.bitWidth, "value does not fit")
        var bytes = [UInt8](repeating: 0, count: count)
        for position in 0..<count {
            let limbIndex = position / 8
            guard limbIndex < self.limbs.count else { break }
            bytes[count - 1 - position] = UInt8(truncatingIfNeeded: self.limbs[limbIndex] >> UInt64((position % 8) * 8))
        }
        return bytes
    }

    /// Whether bit `index` is set (variable time; public values only).
    func bit(_ index: Int) -> Bool {
        let limb = index / 64
        guard limb < self.limbs.count else { return false }
        return (self.limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }

    /// `self - other`; `other` must not be larger than `self`.
    func subtracting(_ other: SSHBigUInt) -> SSHBigUInt {
        precondition(!(self < other), "subtraction would underflow")
        var result = self.limbs
        var borrow: UInt64 = 0
        for index in 0..<result.count {
            let rhs = index < other.limbs.count ? other.limbs[index] : 0
            let (d1, o1) = result[index].subtractingReportingOverflow(rhs)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            result[index] = d2
            borrow = flag(o1) + flag(o2)
        }
        return SSHBigUInt(limbs: result)
    }

    /// The limbs zero extended to `count`.
    func paddedLimbs(_ count: Int) -> [UInt64] {
        precondition(self.limbs.count <= count, "value does not fit")
        return self.limbs + [UInt64](repeating: 0, count: count - self.limbs.count)
    }
}

extension SSHBigUInt: Comparable {
    static func < (lhs: SSHBigUInt, rhs: SSHBigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }
}

/// Montgomery arithmetic modulo an odd public modulus.
///
/// `power` is a Montgomery ladder over a fixed number of exponent bits: every step does the same
/// two multiplications, the secret bit only selects operands through a masked swap, and the
/// multiplication's final subtraction is masked too. No branch or memory index depends on the
/// exponent's bits.
struct SSHMontgomeryModulus: Sendable {
    let modulus: SSHBigUInt
    private let n: [UInt64]
    /// -n^-1 mod 2^64.
    private let n0inv: UInt64
    /// R^2 mod n, with R = 2^(64 * limbs).
    private let rSquared: [UInt64]

    var limbCount: Int { self.n.count }

    /// Nil when the modulus is even or smaller than 3.
    init?(_ modulus: SSHBigUInt) {
        guard let low = modulus.limbs.first, low & 1 == 1, modulus.bitWidth >= 2 else {
            return nil
        }
        self.modulus = modulus
        self.n = modulus.limbs

        // Newton iteration for the inverse of n0 modulo 2^64 (each step doubles the correct bits).
        var inverse: UInt64 = 1
        for _ in 0..<6 {
            inverse = inverse &* (2 &- low &* inverse)
        }
        self.n0inv = 0 &- inverse

        // R^2 mod n = 2^(128 * limbs) mod n, by doubling 1 that many times (public, variable time).
        let count = modulus.limbs.count
        var value = [UInt64](repeating: 0, count: count)
        value[0] = 1
        for _ in 0..<(128 * count) {
            Self.doubleModulo(&value, modulus.limbs)
        }
        self.rSquared = value
    }

    /// `base ^ exponent mod modulus`, walking exactly `exponentBits` bits of the exponent from the
    /// top. `base` must be smaller than the modulus and `exponent` must fit in `exponentBits`.
    func power(_ base: SSHBigUInt, exponent: SSHBigUInt, exponentBits: Int) -> SSHBigUInt {
        precondition(base < self.modulus, "base must be reduced")
        precondition(exponent.bitWidth <= exponentBits, "exponent wider than the ladder")
        let count = self.n.count
        let exponentLimbs = exponent.paddedLimbs((exponentBits + 63) / 64)

        var one = [UInt64](repeating: 0, count: count)
        one[0] = 1
        var r0 = self.multiply(one, self.rSquared)  // 1 in Montgomery form
        var r1 = self.multiply(base.paddedLimbs(count), self.rSquared)

        for index in stride(from: exponentBits - 1, through: 0, by: -1) {
            let bit = (exponentLimbs[index / 64] >> UInt64(index % 64)) & 1
            Self.conditionalSwap(&r0, &r1, bit)
            r1 = self.multiply(r0, r1)
            r0 = self.multiply(r0, r0)
            Self.conditionalSwap(&r0, &r1, bit)
        }
        return SSHBigUInt(limbs: self.multiply(r0, one))
    }

    /// Montgomery product a * b * R^-1 mod n (CIOS), for a, b < n.
    func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let count = self.n.count
        var t = [UInt64](repeating: 0, count: count + 2)
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                self.n.withUnsafeBufferPointer { n in
                    t.withUnsafeMutableBufferPointer { t in
                        for i in 0..<count {
                            // t += a * b[i]
                            var carry: UInt64 = 0
                            let bi = b[i]
                            for j in 0..<count {
                                let (hi, lo) = a[j].multipliedFullWidth(by: bi)
                                let (s1, c1) = t[j].addingReportingOverflow(lo)
                                let (s2, c2) = s1.addingReportingOverflow(carry)
                                t[j] = s2
                                carry = hi &+ flag(c1) &+ flag(c2)
                            }
                            let (s3, c3) = t[count].addingReportingOverflow(carry)
                            t[count] = s3
                            t[count + 1] = flag(c3)

                            // t = (t + m * n) / 2^64
                            let m = t[0] &* self.n0inv
                            let (hi0, lo0) = m.multipliedFullWidth(by: n[0])
                            let (_, c0) = t[0].addingReportingOverflow(lo0)
                            carry = hi0 &+ flag(c0)
                            for j in 1..<max(count, 1) {
                                let (hi, lo) = m.multipliedFullWidth(by: n[j])
                                let (s1, c1) = t[j].addingReportingOverflow(lo)
                                let (s2, c2) = s1.addingReportingOverflow(carry)
                                t[j - 1] = s2
                                carry = hi &+ flag(c1) &+ flag(c2)
                            }
                            let (s4, c4) = t[count].addingReportingOverflow(carry)
                            t[count - 1] = s4
                            t[count] = t[count + 1] &+ flag(c4)
                        }
                    }
                }
            }
        }

        // t < 2n: subtract n once, keep the difference when there was no borrow (masked select).
        var difference = [UInt64](repeating: 0, count: count)
        var borrow: UInt64 = 0
        for j in 0..<count {
            let (d1, o1) = t[j].subtractingReportingOverflow(self.n[j])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            difference[j] = d2
            borrow = flag(o1) | flag(o2)
        }
        // The top limb t[count] is 0 or 1; the difference is valid when t[count] >= borrow.
        let (_, finalBorrow) = t[count].subtractingReportingOverflow(borrow)
        let keepT = 0 &- flag(finalBorrow)  // all ones when t < n
        var result = [UInt64](repeating: 0, count: count)
        for j in 0..<count {
            result[j] = (t[j] & keepT) | (difference[j] & ~keepT)
        }
        return result
    }

    /// Swaps a and b when bit is 1, without branching on it.
    private static func conditionalSwap(_ a: inout [UInt64], _ b: inout [UInt64], _ bit: UInt64) {
        let mask = 0 &- bit
        for index in 0..<a.count {
            let x = (a[index] ^ b[index]) & mask
            a[index] ^= x
            b[index] ^= x
        }
    }

    /// value = 2 * value mod n, for value < n (public values only).
    private static func doubleModulo(_ value: inout [UInt64], _ n: [UInt64]) {
        var carry: UInt64 = 0
        for index in 0..<value.count {
            let next = value[index] >> 63
            value[index] = (value[index] << 1) | carry
            carry = next
        }
        // Subtract n when the doubled value (with its carry bit) is n or more.
        var difference = value
        var borrow: UInt64 = 0
        for index in 0..<value.count {
            let (d1, o1) = value[index].subtractingReportingOverflow(n[index])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            difference[index] = d2
            borrow = flag(o1) | flag(o2)
        }
        if carry == 1 || borrow == 0 {
            value = difference
        }
    }
}

/// 1 for true and 0 for false, read from the Bool's storage so no branch is involved.
@inline(__always)
private func flag(_ value: Bool) -> UInt64 {
    UInt64(unsafeBitCast(value, to: UInt8.self))
}
