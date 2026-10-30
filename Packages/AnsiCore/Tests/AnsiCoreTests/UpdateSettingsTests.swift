import Foundation
import Testing
@testable import AnsiCore

/// Whether a build can turn on Sparkle updates (item 29).
struct UpdateSettingsTests {
    let realKey = Data(repeating: 7, count: 32).base64EncodedString()

    @Test func placeholderIsNotAKey() {
        #expect(UpdateSettings.placeholderKey == "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY")
        #expect(UpdateSettings.problem(publicKey: UpdateSettings.placeholderKey, feedURL: "https://example.com/a.xml")
                == "SUPublicEDKey is a placeholder")
        #expect(UpdateSettings.problem(publicKey: nil, feedURL: "https://example.com/a.xml") == "SUPublicEDKey is missing")
        #expect(UpdateSettings.problem(publicKey: "", feedURL: "https://example.com/a.xml") == "SUPublicEDKey is missing")
    }

    @Test func realKeyIsAccepted() {
        #expect(UpdateSettings.problem(publicKey: realKey, feedURL: UpdateSettings.feedURL) == nil)
        #expect(UpdateSettings.problem(publicKey: " \(realKey)\n", feedURL: UpdateSettings.feedURL) == nil)
    }

    @Test func wrongLengthRejected() {
        let short = Data(repeating: 7, count: 31).base64EncodedString()
        #expect(UpdateSettings.problem(publicKey: short, feedURL: UpdateSettings.feedURL)
                == "SUPublicEDKey is not a 32 byte EdDSA public key")
        #expect(UpdateSettings.problem(publicKey: "not base64!", feedURL: UpdateSettings.feedURL)
                == "SUPublicEDKey is not a 32 byte EdDSA public key")
    }

    @Test func feedMustBeHTTPS() {
        #expect(UpdateSettings.problem(publicKey: realKey, feedURL: "http://example.com/a.xml") == "SUFeedURL is not https")
        #expect(UpdateSettings.problem(publicKey: realKey, feedURL: nil) == "SUFeedURL is not https")
        #expect(UpdateSettings.feedURL == "https://raw.githubusercontent.com/btray77/AnsiView/main/docs/appcast.xml")
    }
}
