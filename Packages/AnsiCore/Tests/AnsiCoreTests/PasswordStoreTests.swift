import Foundation
import Testing
@testable import AnsiCore

@Test func credentialKeyNormalizesHost() {
    #expect(CredentialKey(host: " BBS.Example.COM ", port: 23, account: "Me") ==
            CredentialKey(host: "bbs.example.com", port: 23, account: "Me"))
    // Accounts stay case sensitive (some BBSes care).
    #expect(CredentialKey(host: "h", port: 23, account: "me") != CredentialKey(host: "h", port: 23, account: "Me"))
}

@Test func memoryStoreRoundTrip() throws {
    let store = MemoryPasswordStore()
    let key = CredentialKey(host: "h.example.com", port: 23, account: "me")
    #expect(store.password(for: key) == nil)
    try store.setPassword("one", for: key, label: "x")
    try store.setPassword("two", for: key, label: "x")
    #expect(store.password(for: key) == "two")
    try store.removePassword(for: key)
    #expect(store.password(for: key) == nil)
    // Removing a missing item is not an error.
    try store.removePassword(for: key)
}

/// A real round trip through the login Keychain with a host that cannot exist; always cleaned up.
@Test func keychainRoundTrip() throws {
    let store = KeychainPasswordStore()
    let key = CredentialKey(host: "ansiview-test-\(UUID().uuidString.lowercased()).invalid", port: 2323, account: "tester")
    defer { try? store.removePassword(for: key) }
    #expect(store.password(for: key) == nil)
    try store.setPassword("first pass", for: key, label: "AnsiView BBS: test")
    #expect(store.password(for: key) == "first pass")
    try store.setPassword("second ünïcode", for: key, label: "AnsiView BBS: test")
    #expect(store.password(for: key) == "second ünïcode")
    // Another port or account is another item.
    #expect(store.password(for: CredentialKey(host: key.host, port: 23, account: "tester")) == nil)
    #expect(store.password(for: CredentialKey(host: key.host, port: 2323, account: "other")) == nil)
    try store.removePassword(for: key)
    #expect(store.password(for: key) == nil)
}
