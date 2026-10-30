import Foundation
import Testing
@testable import AnsiCore

struct ArtEditorsTests {
    @Test func knownEditors() {
        #expect(ArtEditor.all.map(\.name) == ["Moebius", "PabloDraw"])
        #expect(ArtEditor.moebius.bundleIdentifier == "org.andyherbert.moebius")
        #expect(ArtEditor.pabloDraw.bundleIdentifier == "ca.picoe.pablodraw")
        #expect(ArtEditor.moebius.downloadPage.absoluteString == "https://github.com/blocktronics/moebius/releases")
        #expect(ArtEditor.pabloDraw.downloadPage.absoluteString == "https://github.com/cwensley/pablodraw/releases")
        #expect(ArtEditor.moebius.menuTitle == "Open in Moebius")
    }

    @Test func notInstalledMessage() {
        let message = ArtEditor.pabloDraw.notInstalledMessage
        #expect(message.title == "PabloDraw is not installed")
        #expect(message.detail.contains("ca.picoe.pablodraw") == false)
        #expect(message.detail.contains("PabloDraw"))
    }
}
