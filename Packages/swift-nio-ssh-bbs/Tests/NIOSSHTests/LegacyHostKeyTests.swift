// AnsiView patch (see PATCHES.md): RSA (RFC 4253 ssh-rsa, RFC 8332 rsa-sha2-256/512) and DSA
// (RFC 4253 ssh-dss) host key verification. The keys and signatures were made with OpenSSL 3.6
// (an independent implementation): the exchange hash H is SHA-256("exchange hash") and each
// signature was made with `openssl dgst -<hash> -sign` over H's bytes, as an SSH server signs H.

import Crypto
import NIOCore
import XCTest

@testable import NIOSSH

final class LegacyHostKeyTests: XCTestCase {
    static let rsaPublic =
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDfiL4juz/NuzXGA2ZDEootTIAA7GzlpRRDAZlSo95TmJu+HZOqz4qT+pHspgq2GgRwrC1r+lh9ImsyznwzR8CZZnkGC4iWMv45pKC5BzZ88FFPE6MNZcPU2JpmtENGBMssSQS3FpqNzUngdblhxEq/vR9wj71HS9xa7ibKmGzN7eAT9Hq22QsJM27UwZuynbpntwFPfWbGeZ7bXDYhTUrVOOkPbo79swzosLyFkiTZGN//4iv+YNLIfUb7XDHyXEp995cn27NZHIydwNHAmlyYKtjtv7f6yMkI9DzfnbWfSw4+LzwhiKd3lhHTl2SXhvixAQuzPnCeZJZzcZyGojRZ"
    static let rsaSHA1 =
        "jjhbIGNI51NFh1fv94anwPrWn6eyjCePoPDOEt+by0TBWQfcaEZglOEZwNdijRPBbsbsNuMY4YLH3KDCsqdjAHnD+XnnFGfDCKEiTXMxUQFpUXZ+y5+H1x0I5tUpr3w31QIZPftXt44ZfGfSaWZg0fi+/BiDGiNPcGjwcIr6dc1NAbAiz6RVMiS6DtqecNgX8fet17rpxrKruJyuHVtVTQ7Zua//kpazWW9Qr8J9zOZgRzQXT67MkxLvef49rTSvbGwkiLgCjeTyx7A0n4OApU1fO38Pg3u/fDLGPa+QCYHeCqgfOYdfZGMsHRHX4cXB1d0q9eIHEj2HUg0+TDBRjQ=="
    static let rsaSHA256 =
        "patb0HkYodMLJYgoZJCCp6inG0G2JEQDVKUkfCk3a9wc8HfzC2HVMVyZEsJXJHw6GFpKiy0XMo+NvUJWBY11jWvRmtoj7eU245z7t4kthGqKJ197kHjJom0nKTRNjbmvt2Wgl0Uik9Kwe7QmUC0K7rXEPrEWuJg9J3Lz/1UnFk6tcQ3Rr5HCBEFlKbC0C8n5wMMAIw8AcivUrA9NZJFdhISk9se+nxq7e8/uGJHJPD6HW33dJFckAIZyNI6RT4A7NwDhF3pULHhpMErG4SSuR6nGNrkONeA68H+CHb9Uzbdn4eyvi83X19yWjHvEKZcGyarW+i5SZ0v2K0JFxGOc3g=="
    static let rsaSHA512 =
        "ZWVAkmGHVgRPkblXK+zp56QRy7sv/VdauvJljdnu4yQ5AZu1T4kjKQOZ3iJ7rMHVqYF7JdsW6amQjF/BL6zwaeo4wjSop5ntjDjIj02IJsBlKOfXyKWtzKJ4Bdi589RhEGleZ4qQ53eDkzP1dnf6Pq9ujvE44MKKodcJo3j6Ci4pOpUDqv3eCBkL1HMLb4ZfGBV/9/tTytF8BBGyTnF2W3hOxD+9zNuPErxYRXOqXtLsqYWR84uVcuClge7+TQj5jUicd97+5ALKtsGmYDRARaDFlWDrsuJGiwhNJ41+UjL+/0slWBHS1n5cTXtyyfXG61OpIt+bsfdkdFpqeqpBlg=="
    static let smallModulus =
        "D56E4AC379B937F88071A91E29575CEDBA653012CD25EA872AFF8C73C42EA93585F4A59483457D297D6E09BFF251E5D19CDBB8C38F47F970821A9FF2B9CB2D25F0309068BBF9C0E690B8BC86A9E761CC8ABB38135F198D5895C87F7A86BF6815"
    static let dsaPublic =
        "ssh-dss AAAAB3NzaC1kc3MAAACBAKRjNw5OlIe5t/h1MWW0jMNcadD8qcm0c8DnUxeGLeMDzye14/WLxW8dh4iOcyqviZniKycyggtoeMj508TAto60K0wf7aj9dKhgTzgefhloOwJFqLxMyqwwYVZmDKO6hUhvP65pAOF7kFzvd0LoyfTBSVkFrVlMPLYGdT5SUPHdAAAAFQDqlzL4oQVFj9tbvK0WUEzz8xu2YwAAAIEAnE2YHTDAj2qDZR5vUVS83WI2BxARjKloKnQew19/6RpoR1sEf4lOmLlgkIasDdo6EN2e0wYy1/1loP9lT+seYA2XcVfTv5aZoapY7swnTO/of8J2gAwIj4/sOoE5Btu2YZI8p/1lokeFKJqWiMCswQCnKbK1frALZ2QSC6fb3VIAAACBAJBa3ju+SQ1HqC9K5NcqiyHWs1CERvlQiKKyeTT+oAftcy2x/jxFSTmFMSHOQhNe/SinpCHUkZAsMLm9y4RGaZ64ATu7V2VKzAmOPpytrWSgw+xdIDuqIxp5/FP21gKb2Rx4jlOUR5viroFOjJ4Ovdm3Tjp1tDJrbzEZA3nMIBOu"
    static let dsaSignature = "d1b99470ce999b62c4dfd682e7c2a433de2299d6491fd2f70372e478c66e5d47467cb5bdaff08966"

    /// The exchange hash every fixture signature covers.
    let exchangeHash = SHA256.hash(data: Array("exchange hash".utf8))

    private func signature(_ name: String, _ raw: [UInt8]) throws -> NIOSSHSignature {
        var buffer = ByteBuffer()
        buffer.writeSSHString(Array(name.utf8))
        buffer.writeSSHString(raw)
        return try XCTUnwrap(try buffer.readSSHSignature())
    }

    func testRSAKeyRoundTripsExactly() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: Self.rsaPublic)
        XCTAssertEqual(String(openSSHPublicKey: key), Self.rsaPublic)
        XCTAssertEqual(String(key.keyPrefix), "ssh-rsa")
        XCTAssertEqual(key, try NIOSSHPublicKey(openSSHPublicKey: Self.rsaPublic))
    }

    func testRSASignaturesFromOpenSSLVerify() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: Self.rsaPublic)
        for (name, sig) in [("ssh-rsa", Self.rsaSHA1), ("rsa-sha2-256", Self.rsaSHA256), ("rsa-sha2-512", Self.rsaSHA512)] {
            let signature = try self.signature(name, Array(Data(base64Encoded: sig)!))
            XCTAssertEqual(signature.algorithmName, name)
            XCTAssertTrue(key.isValidSignature(signature, for: self.exchangeHash), name)
        }
    }

    func testRSASignatureUnderTheWrongAlgorithmNameFails() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: Self.rsaPublic)
        let sha256 = Array(Data(base64Encoded: Self.rsaSHA256)!)
        XCTAssertFalse(key.isValidSignature(try self.signature("rsa-sha2-512", sha256), for: self.exchangeHash))
        XCTAssertFalse(key.isValidSignature(try self.signature("ssh-rsa", sha256), for: self.exchangeHash))
    }

    func testTamperedRSASignatureFails() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: Self.rsaPublic)
        var sha256 = Array(Data(base64Encoded: Self.rsaSHA256)!)
        sha256[100] ^= 0x01
        XCTAssertFalse(key.isValidSignature(try self.signature("rsa-sha2-256", sha256), for: self.exchangeHash))
        XCTAssertFalse(key.isValidSignature(try self.signature("rsa-sha2-256", []), for: self.exchangeHash))
    }

    func testRSAKeyBelow1024BitsIsRefused() {
        var buffer = ByteBuffer()
        buffer.writeSSHString(Array("ssh-rsa".utf8))
        buffer.writeSSHString([0x01, 0x00, 0x01])
        buffer.writeSSHString([0x00] + bytes(Self.smallModulus.lowercased()))
        XCTAssertThrowsError(try buffer.readSSHHostKey())
    }

    func testRSAWireToPKCS1() {
        // SEQUENCE { INTEGER n, INTEGER e } with n = 0x80 (needs a leading zero) and e = 3.
        XCTAssertEqual(NIOSSHRSAPublicKey.pkcs1DER(modulus: [0x80], exponent: [0x03]), [0x30, 0x07, 0x02, 0x02, 0x00, 0x80, 0x02, 0x01, 0x03])
        // A 300 byte integer uses the long length form.
        let der = NIOSSHRSAPublicKey.pkcs1DER(modulus: [UInt8](repeating: 0x11, count: 300), exponent: [0x01, 0x00, 0x01])
        XCTAssertEqual(Array(der.prefix(8)), [0x30, 0x82, 0x01, 0x35, 0x02, 0x82, 0x01, 0x2C])
    }

    func testDSAKeyAndSignatureFromOpenSSL() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: Self.dsaPublic)
        XCTAssertEqual(String(openSSHPublicKey: key), Self.dsaPublic)
        let good = try self.signature("ssh-dss", bytes(Self.dsaSignature))
        XCTAssertTrue(key.isValidSignature(good, for: self.exchangeHash))
        var tampered = bytes(Self.dsaSignature)
        tampered[39] ^= 0x01
        XCTAssertFalse(key.isValidSignature(try self.signature("ssh-dss", tampered), for: self.exchangeHash))
        // r = 0 and s >= q are invalid by definition.
        XCTAssertFalse(key.isValidSignature(try self.signature("ssh-dss", [UInt8](repeating: 0, count: 20) + bytes(Self.dsaSignature).suffix(20)), for: self.exchangeHash))
        XCTAssertFalse(key.isValidSignature(try self.signature("ssh-dss", [UInt8](repeating: 0xFF, count: 40)), for: self.exchangeHash))
    }

    func testHostKeyAlgorithmToKeyType() {
        XCTAssertEqual(NIOSSHPublicKey.keyType(forHostKeyAlgorithm: "rsa-sha2-256"), "ssh-rsa")
        XCTAssertEqual(NIOSSHPublicKey.keyType(forHostKeyAlgorithm: "rsa-sha2-512"), "ssh-rsa")
        XCTAssertEqual(NIOSSHPublicKey.keyType(forHostKeyAlgorithm: "ssh-rsa"), "ssh-rsa")
        XCTAssertEqual(NIOSSHPublicKey.keyType(forHostKeyAlgorithm: "ssh-ed25519"), "ssh-ed25519")
        XCTAssertEqual(NIOSSHPublicKey.keyType(forHostKeyAlgorithm: "ssh-dss"), "ssh-dss")
    }
}
