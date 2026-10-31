import Foundation
import ImageIO
import Testing
@testable import AnsiCore

/// PNG and GIF files for the iPhone and iPad share sheet (plan 8).
@Suite struct ArtShareExportTests {
    private var animated: ArtFile {
        art(bytes(String(repeating: "A", count: 200) + "\u{1B}[2J" + String(repeating: "B", count: 200)))
    }

    private func source(_ data: Data) throws -> CGImageSource {
        try #require(CGImageSourceCreateWithData(data as CFData, nil))
    }

    @Test func pngHasSignatureAndSize() throws {
        let data = try #require(ArtShareExport.png(art(bytes("Hello")), scale: 2))
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let image = try #require(CGImageSourceCreateImageAtIndex(try source(data), 0, nil))
        #expect(image.width == 80 * 8 * 2)
        #expect(image.height == 16 * 2)
    }

    @Test func gifIsAnimated() throws {
        let data = try #require(ArtShareExport.gif(animated, baud: 2400))
        #expect(Array(data.prefix(6)) == Array("GIF89a".utf8))
        #expect(CGImageSourceGetCount(try source(data)) > 1)
    }

    @Test func staticFramesHoldThreeSeconds() {
        let frames = ArtShareExport.frames(art(bytes("Hello")), baud: 0)
        #expect(frames.count == 1)
        #expect(frames.first?.duration == ArtShareExport.holdSeconds)
    }

    @Test func blinkFramesAlternate() {
        let frames = ArtShareExport.frames(art(bytes("\u{1B}[5mBlink")), baud: 0)
        #expect(frames.count >= 2)
        #expect(frames[0].blinkVisible != frames[1].blinkVisible)
    }

    @Test func framesMatchBaud() {
        let file = animated
        let fps = 10.0
        let frames = ArtShareExport.frames(file, baud: 2400, fps: fps)
        // The drawing time at 240 bytes a second, then the hold on the finished art.
        let total = frames.reduce(0) { $0 + $1.duration }
        let expected = Double(file.stream.count) * 10 / 2400 + ArtShareExport.holdSeconds
        #expect(abs(total - expected) <= 1 / fps + 1e-9)
        #expect(frames.count > 2)
        #expect(frames.last?.screen.rows == ArtPlayback(file).finalScreen.rows)
    }

    /// A long stream is sampled less often so a share GIF stays bounded (review finding 3):
    /// About 6,100 bytes at 300 baud is over 200 s, more than 2,000 samples at 10 a second.
    @Test func longStreamIsCapped() throws {
        let line = String(repeating: "A", count: 79) + "\r\n"
        let body = (0..<75).map { i in (i % 20 == 19 ? "\u{1B}[2J" : "") + line }.joined()
        let file = art(bytes(body))
        let drawSeconds = Double(file.stream.count) * 10 / 300
        #expect(drawSeconds > 200)
        let frames = ArtShareExport.frames(file, baud: 300)
        #expect(frames.count <= ArtShareExport.maxFrames + 1)
        let total = frames.reduce(0) { $0 + $1.duration }
        let step = drawSeconds / Double(ArtShareExport.maxFrames)
        #expect(abs(total - (drawSeconds + ArtShareExport.holdSeconds)) <= step + 1e-6)
        // The GIF holds the same frames (gifFrameCountMatchesFrames); encoding 600 frames in a debug
        // build takes about a minute, so it is measured in release by a harness instead.
    }

    /// The streamed GIF has the same frames and timing as `frames` describes.
    @Test func gifFrameCountMatchesFrames() throws {
        let frames = ArtShareExport.frames(animated, baud: 2400)
        let data = try #require(ArtShareExport.gif(animated, baud: 2400))
        #expect(CGImageSourceGetCount(try source(data)) == frames.count)
    }

    @Test func fileNameReplacesExtension() {
        #expect(ArtShareExport.fileName(for: "WELCOME.ANS", extension: "png") == "WELCOME.png")
        #expect(ArtShareExport.fileName(for: "", extension: "gif") == "AnsiView.gif")
        #expect(ArtShareExport.fileName(for: "a/b", extension: "png") == "a-b.png")
    }
}
