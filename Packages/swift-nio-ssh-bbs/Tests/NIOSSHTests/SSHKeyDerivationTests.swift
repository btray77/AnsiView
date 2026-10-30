// AnsiView patch (see PATCHES.md): RFC 4253 section 7.2 key derivation, including the key
// extension, against values computed with Python's hashlib (an independent implementation).

import Crypto
import XCTest

@testable import NIOSSH

final class SSHKeyDerivationTests: XCTestCase {
    static let k = bytes("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7")
    static let h1 = bytes("00820a295903ed9bc74de0e99ae8565e57167689")
    static let h2 = bytes("7bde03b6174b06ac22d902ada587e02f46b15e82e96fcc34d951b86efe0642f8")
    static let h5 = bytes(
        "af1d3205f05173232429559726444a2e65dfcaed9d0d976a594ddbf965901bbfd388cc9d422ce505f3aba698c26ddbe7"
            + "4738cde81b4e5e572ed35f714f0885b2"
    )
    static let sid = bytes("3f3af1ecebbd1410ab417ec0d27bbfcb5d340e177ae159b59fc8626c2dfd9175")

    func testMPIntEncoding() {
        XCTAssertEqual(SSHKeyDerivation.mpint([0x00, 0x00, 0x7F]), [0, 0, 0, 1, 0x7F])
        XCTAssertEqual(SSHKeyDerivation.mpint([0x80]), [0, 0, 0, 2, 0x00, 0x80])
        XCTAssertEqual(SSHKeyDerivation.mpint([0x00, 0x80, 0x01]), [0, 0, 0, 3, 0x00, 0x80, 0x01])
        XCTAssertEqual(SSHKeyDerivation.mpint([]), [0, 0, 0, 0])
        XCTAssertEqual(SSHKeyDerivation.mpint([0, 0]), [0, 0, 0, 0])
    }

    func testDerivationMatchesHashlib() {
        func derive<H: HashFunction>(_ type: H.Type, _ h: [UInt8], _ letter: Character, _ length: Int) -> String {
            hex(
                SSHKeyDerivation.derive(
                    type,
                    sharedSecret: Self.k,
                    exchangeHash: h,
                    letter: letter.asciiValue!,
                    sessionID: Self.sid,
                    length: length
                )
            )
        }
        XCTAssertEqual(derive(Insecure.SHA1.self, Self.h1, "C", 32), "740636784db9cc8f8730433b75ac35ccda3dfc2a6bba2f4bf9464c089f83a42c")
        XCTAssertEqual(
            derive(Insecure.SHA1.self, Self.h1, "E", 64),
            "4fd81cfe509237984ca8854c823765297eb0d3d497580aa91770c5749e96a033"
                + "fd7e88fdcacb1312861a9b0af6ca8164ea894442de2ff2c65615f1cb239868be"
        )
        XCTAssertEqual(
            derive(SHA256.self, Self.h2, "F", 64),
            "d82aa074539a46804330e42695a043bdf77974a82e20cf12663c0debec725532"
                + "787d80bf93ba40dcb583e3d3c99b6669d422b4dbaaf5efb249b15c2b401bc933"
        )
        XCTAssertEqual(derive(SHA256.self, Self.h2, "A", 16), "30640238e90af2f90514240ced0346bb")
        XCTAssertEqual(derive(SHA512.self, Self.h5, "D", 32), "2a688a5aa9dae6971070545ad20d73dcd03f404113ccfd938cc47d726858ccec")
    }

    /// The elliptic curve exchange now extends its keys too (upstream truncated a single digest).
    func testEllipticCurveKeysAreExtended() throws {
        var hasher = SHA256()
        hasher.update(data: SSHKeyDerivation.mpint(Self.k))
        hasher.update(data: Self.h2)
        let expanded = SSHKeyDerivation.expand(hasher, letter: UInt8(ascii: "F"), sessionID: Self.sid, length: 64)
        XCTAssertEqual(
            hex(expanded),
            "d82aa074539a46804330e42695a043bdf77974a82e20cf12663c0debec725532"
                + "787d80bf93ba40dcb583e3d3c99b6669d422b4dbaaf5efb249b15c2b401bc933"
        )
    }
}

func bytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var text = Substring(hex)
    while !text.isEmpty {
        out.append(UInt8(text.prefix(2), radix: 16)!)
        text = text.dropFirst(2)
    }
    return out
}

func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}
