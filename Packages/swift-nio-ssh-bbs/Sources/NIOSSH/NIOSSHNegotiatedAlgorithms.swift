//===----------------------------------------------------------------------===//
//
// AnsiView patch (see PATCHES.md): what a key exchange agreed on, reported to the client.
//
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

import Foundation

/// The algorithms chosen in one key exchange (client to server and server to client are always the
/// same in this package), and which of them are weak by today's standards.
public struct NIOSSHNegotiatedAlgorithms: Sendable, Hashable {
    public var serverVersion: String
    public var keyExchange: String
    public var hostKey: String
    public var cipher: String
    /// Nil for AEAD ciphers (AES-GCM), which ignore the MAC.
    public var mac: String?

    public init(serverVersion: String, keyExchange: String, hostKey: String, cipher: String, mac: String?) {
        self.serverVersion = serverVersion
        self.keyExchange = keyExchange
        self.hostKey = hostKey
        self.cipher = cipher
        self.mac = mac
    }

    /// The negotiated names that are weak: SHA-1 or 1024 bit key exchange, SHA-1 RSA or DSA host
    /// signatures, CBC mode or 3DES, SHA-1 or MD5 MACs.
    public var weakAlgorithms: [String] {
        var weak: [String] = []
        if self.keyExchange.hasSuffix("-sha1") { weak.append(self.keyExchange) }
        if ["ssh-rsa", "ssh-dss"].contains(self.hostKey) { weak.append(self.hostKey) }
        if self.cipher.hasSuffix("-cbc") { weak.append(self.cipher) }
        if let mac = self.mac, mac.contains("sha1") || mac.contains("md5") { weak.append(mac) }
        return weak
    }

    public var isLegacy: Bool { !self.weakAlgorithms.isEmpty }
}
