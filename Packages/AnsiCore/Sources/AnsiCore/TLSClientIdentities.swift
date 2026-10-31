import Foundation
import Security

/// Client certificates (identities: a certificate with its private key) in the user's Keychain,
/// offered to telnet over TLS boards that ask for one.
public enum TLSClientIdentities {
    public struct Item: Equatable {
        public let name: String
        /// A persistent reference, stored in the dialing directory entry.
        public let reference: Data
    }

    /// Every identity the Keychain holds, by label, sorted.
    public static func list() -> [Item] {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecReturnPersistentRef as String: true,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let reference = row[kSecValuePersistentRef as String] as? Data, !reference.isEmpty else { return nil }
            let name = (row[kSecAttrLabel as String] as? String) ?? "Certificate"
            return Item(name: name, reference: reference)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The identity for a stored reference; nil when it is gone from the Keychain.
    public static func identity(reference: Data) -> SecIdentity? {
        let query: [String: Any] = [kSecValuePersistentRef as String: reference, kSecReturnRef as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result,
              CFGetTypeID(result) == SecIdentityGetTypeID() else { return nil }
        return (result as! SecIdentity)
    }
}
