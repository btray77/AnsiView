import Foundation
import Testing
@testable import AnsiCore

private func account(_ name: String, user: String = "bob") -> BBSEntry {
    var e = BBSEntry(name: name, host: "bbs.x.example", port: 23)
    e.username = user
    return e
}

/// Review Important 1: a new entry for the same account with an empty password field must not
/// delete the other entry's password.
@Test func emptyPasswordDoesNotDeleteSharedAccount() throws {
    let store = MemoryPasswordStore()
    let a = account("A")
    try store.setPassword("secret", for: a.credentialKey!, label: "x")
    let directory = DialingDirectory(entries: [a])
    let b = account("B")
    try DialingDirectory.saveCredential(password: "", for: b, original: nil, in: directory, store: store)
    #expect(store.password(for: a.credentialKey!) == "secret")
    // Clearing the password of the entry that owns it (and nobody shares) removes it.
    try DialingDirectory.saveCredential(password: "", for: a, original: a, in: directory, store: store)
    #expect(store.password(for: a.credentialKey!) == nil)
}

/// Review Important 2: moving to a new key writes the new item before removing the old one, so a
/// failed write keeps the old password.
@Test func failedMoveKeepsOldPassword() throws {
    final class FailingStore: PasswordStore {
        var items: [CredentialKey: String] = [:]
        var failWrites = false
        func password(for key: CredentialKey) -> String? { items[key] }
        func setPassword(_ password: String, for key: CredentialKey, label: String) throws {
            if failWrites { throw KeychainError(status: -25308) }
            items[key] = password
        }
        func removePassword(for key: CredentialKey) throws { items[key] = nil }
    }
    let store = FailingStore()
    let old = account("A")
    store.items[old.credentialKey!] = "secret"
    var moved = old
    moved.username = "robert"
    store.failWrites = true
    #expect(throws: (any Error).self) {
        try DialingDirectory.saveCredential(password: "secret", for: moved, original: old, in: DialingDirectory(entries: [old]), store: store)
    }
    #expect(store.items[old.credentialKey!] == "secret")
    store.failWrites = false
    try DialingDirectory.saveCredential(password: "secret", for: moved, original: old, in: DialingDirectory(entries: [old]), store: store)
    #expect(store.items[old.credentialKey!] == nil)
    #expect(store.items[moved.credentialKey!] == "secret")
}

/// Moving away from a key another entry still uses keeps that item.
@Test func moveAwayFromSharedKeyKeepsIt() throws {
    let store = MemoryPasswordStore()
    let a = account("A"), b = account("B")
    try store.setPassword("secret", for: a.credentialKey!, label: "x")
    var moved = b
    moved.username = "carol"
    try DialingDirectory.saveCredential(password: "pw2", for: moved, original: b, in: DialingDirectory(entries: [a, b]), store: store)
    #expect(store.password(for: a.credentialKey!) == "secret")
    #expect(store.password(for: moved.credentialKey!) == "pw2")
}

/// Review Important 4: one bad entry no longer empties the whole directory, and fully
/// unreadable data is reported so the app can keep a backup.
@Test func badEntryIsSkippedNotEverything() throws {
    let good = DialingDirectory(entries: [BBSEntry(name: "Good", host: "g.example.com")])
    var json = String(decoding: good.encoded(), as: UTF8.self)
    json = json.replacingOccurrences(of: "\"entries\":[", with: "\"entries\":[{\"id\":\"9E2B1C1A-0000-4000-8000-000000000001\",\"port\":23},")
    let loaded = DialingDirectory.load(stored: Data(json.utf8), legacy: nil)
    #expect(loaded.directory.entries.map(\.name) == ["Good"])
    #expect(!loaded.unreadable)
    let garbage = DialingDirectory.load(stored: Data("garbage".utf8), legacy: nil)
    #expect(garbage.directory.entries.isEmpty && garbage.unreadable)
    // The plan 7 array also keeps its good entries.
    let legacy = #"[{"name":"Old","host":"old.example.com"},{"port":5}]"#
    #expect(DialingDirectory.load(stored: nil, legacy: Data(legacy.utf8)).directory.entries.map(\.name) == ["Old"])
}

/// Review Minor 8: saving an edit keeps calls recorded while the editor was open.
@Test func savingAnEditKeepsNewerCallHistory() {
    var stored = account("A")
    stored.totalCalls = 5
    stored.lastCalled = Date(timeIntervalSince1970: 1_800_000_000)
    var draft = stored
    draft.totalCalls = 4
    draft.lastCalled = Date(timeIntervalSince1970: 1_700_000_000)
    draft.notes = "edited"
    let merged = DialingDirectory(entries: [stored]).keepingHistory(draft)
    #expect(merged.notes == "edited")
    #expect(merged.totalCalls == 5 && merged.lastCalled == stored.lastCalled)
}
