import CoreGraphics
import Foundation
import Testing
@testable import AnsiCore

struct ThumbnailTests {
    func lines(_ count: Int) -> ArtFile {
        let text = (0..<count).map { "LINE \($0)" }.joined(separator: "\r\n")
        return ArtFile(data: Data(text.utf8), fileExtension: "ans")
    }

    @Test func normalScreenKeepsAllRows() {
        let file = lines(25)
        #expect(Thumbnail.rows(for: file, screen: AnsiAnalysis(file).finalScreen) == 25)
    }

    @Test func tallArtIsCroppedSquare() {
        let file = lines(2000)
        #expect(Thumbnail.rows(for: file, screen: AnsiAnalysis(file).finalScreen) == 40)
        let image = Thumbnail.render(file, maximum: CGSize(width: 512, height: 512))
        #expect(image?.width == 512)
        #expect(image?.height == 512)
    }

    @Test func sizeFitsAndLimitsUpscale() {
        #expect(Thumbnail.size(artPoints: CGSize(width: 640, height: 400), maximum: CGSize(width: 256, height: 256))
                == CGSize(width: 256, height: 160))
        #expect(Thumbnail.size(artPoints: CGSize(width: 64, height: 32), maximum: CGSize(width: 1024, height: 1024))
                == CGSize(width: 128, height: 64))
        #expect(Thumbnail.size(artPoints: CGSize(width: 2000, height: 1), maximum: CGSize(width: 10, height: 10))
                == CGSize(width: 10, height: 1))
    }

    @Test func renderHasRequestedSize() throws {
        let image = try #require(Thumbnail.render(lines(25), maximum: CGSize(width: 256, height: 256)))
        #expect(image.width == 256)
        #expect(image.height == 160)
    }

    @Test func emptyFileThumbnail() throws {
        let image = try #require(Thumbnail.render(ArtFile(data: Data()), maximum: CGSize(width: 64, height: 64)))
        #expect(image.width >= 1 && image.height >= 1)
        #expect(Thumbnail.render(ArtFile(data: Data()), maximum: .zero) == nil)
    }

    @Test func renderFromAKnownScreenMatches() throws {
        let file = lines(40)
        let screen = AnsiAnalysis(file).finalScreen
        let a = try #require(Thumbnail.render(file, maximum: CGSize(width: 128, height: 128)))
        let b = try #require(Thumbnail.render(file, screen: screen, maximum: CGSize(width: 128, height: 128)))
        #expect(a.width == b.width && a.height == b.height)
        #expect(a.dataProvider?.data as Data? == b.dataProvider?.data as Data?)
    }
}
