import Foundation

/// Sparkle update settings of the direct download build (item 29). Updates stay off until the
/// owner puts a real EdDSA public key in `SUPublicEDKey`.
public enum UpdateSettings {
    /// What `SUPublicEDKey` holds until the owner runs Sparkle's `generate_keys`.
    public static let placeholderKey = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"
    /// The appcast: `docs/appcast.xml` on `main` in the public repository.
    public static let feedURL = "https://raw.githubusercontent.com/btray77/AnsiView/main/docs/appcast.xml"

    /// Why updates cannot be turned on, or nil when the key and feed look usable.
    public static func problem(publicKey: String?, feedURL: String?) -> String? {
        let key = (publicKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "SUPublicEDKey is missing" }
        if key == placeholderKey { return "SUPublicEDKey is a placeholder" }
        guard let data = Data(base64Encoded: key), data.count == 32 else {
            return "SUPublicEDKey is not a 32 byte EdDSA public key"
        }
        guard let feed = feedURL.flatMap(URL.init(string:)), feed.scheme == "https", feed.host != nil else {
            return "SUFeedURL is not https"
        }
        return nil
    }
}
