import Foundation
import Security

/// Identifies one BBS account's password: host (trimmed, lowercased), port and username.
public struct CredentialKey: Hashable, Codable {
    public let host: String
    public let port: Int
    public let account: String

    public init(host: String, port: Int, account: String) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
        self.account = account
    }
}

/// Where BBS passwords live. The app uses `KeychainPasswordStore`; tests use `MemoryPasswordStore`.
public protocol PasswordStore: AnyObject {
    func password(for key: CredentialKey) -> String?
    /// Adds or replaces the password; `label` is what Keychain Access shows.
    func setPassword(_ password: String, for key: CredentialKey, label: String) throws
    /// Removes the password; a missing item is not an error.
    func removePassword(for key: CredentialKey) throws
}

public final class MemoryPasswordStore: PasswordStore {
    public private(set) var items: [CredentialKey: String] = [:]

    public init() {}

    public func password(for key: CredentialKey) -> String? { items[key] }

    public func setPassword(_ password: String, for key: CredentialKey, label: String) throws {
        items[key] = password
    }

    public func removePassword(for key: CredentialKey) throws {
        items[key] = nil
    }
}

public struct KeychainError: LocalizedError, Equatable {
    public let status: OSStatus

    public var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The Keychain could not save the password: \(text)"
    }
}

/// Internet password items in the user's login Keychain (`kSecClassInternetPassword`, keyed by
/// server, port, account and the telnet protocol). Sandboxed apps may use these with no
/// keychain entitlement; the item's access list names the app that created it.
public final class KeychainPasswordStore: PasswordStore {
    public init() {}

    private func query(_ key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: key.host,
            kSecAttrPort as String: key.port,
            kSecAttrAccount as String: key.account,
            kSecAttrProtocol as String: kSecAttrProtocolTelnet,
        ]
    }

    public func password(for key: CredentialKey) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, for key: CredentialKey, label: String) throws {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        let status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrComment as String] = "Saved by AnsiView's dialing directory"
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    public func removePassword(for key: CredentialKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
