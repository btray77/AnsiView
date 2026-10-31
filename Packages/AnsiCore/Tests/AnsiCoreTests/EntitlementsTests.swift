import Foundation
import Testing

/// The sandbox entitlements of both app variants and every extension (final gaps ruling 10).
@Suite struct EntitlementsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func bothAppVariantsKeepAppScopedBookmarks() throws {
        for path in ["App/AnsiView.entitlements", "Packaging/appstore/AnsiView.entitlements"] {
            let e = try Self.plist(path)
            #expect(e["com.apple.security.app-sandbox"] as? Bool == true, "\(path)")
            #expect(e["com.apple.security.files.bookmarks.app-scope"] as? Bool == true, "\(path)")
            #expect(e["com.apple.security.files.user-selected.read-write"] as? Bool == true, "\(path)")
            #expect(e["com.apple.security.network.client"] as? Bool == true, "\(path)")
        }
        let spec = try String(contentsOf: Self.root.appendingPathComponent("Packaging/appstore/project-appstore.yml"), encoding: .utf8)
        #expect(spec.contains("com.apple.security.files.bookmarks.app-scope: true"))
    }

    @Test func theStoreVariantHasNoTemporaryExceptions() throws {
        let e = try Self.plist("Packaging/appstore/AnsiView.entitlements")
        #expect(!e.keys.contains { $0.contains("temporary-exception") })
    }

    @Test func noExtensionHasNetworkAccess() throws {
        let extensions = ["Preview/AnsiPreview.entitlements", "QuickAction/AnsiConvertGIF.entitlements",
                          "QuickAction/AnsiConvertPNG.entitlements", "Spotlight/AnsiSpotlight.entitlements",
                          "Thumbnail/AnsiThumbnail.entitlements"]
        for path in extensions {
            let e = try Self.plist(path)
            #expect(e["com.apple.security.app-sandbox"] as? Bool == true, "\(path)")
            #expect(!e.keys.contains { $0.hasPrefix("com.apple.security.network") }, "\(path)")
        }
    }
}
