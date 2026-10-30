import Foundation
import Testing
@testable import AnsiCore

/// Ruling 8: padding pauses make a stream count as animated.
@Suite struct AnimationPauseTests {
    private func analysis(_ text: String) -> AnsiAnalysis {
        AnsiAnalysis(ArtFile(data: Data(text.utf8), fileExtension: "ans"))
    }

    @Test func eightCarriageReturnsAfterDrawingArePause() {
        let cr = String(repeating: "\r", count: 8)
        #expect(analysis("Hello" + cr + "\u{1B}[1;1HJ").isAnimated)
        #expect(!analysis("Hello" + String(repeating: "\r", count: 7) + "\u{1B}[1;1HJ").isAnimated)
        #expect(!analysis(cr + "Hello").isAnimated)
        var terminal = AnsiTerminal(ArtFile(data: Data(("Hi" + cr + cr).utf8), fileExtension: "ans"))
        terminal.runToEnd()
        #expect(terminal.pauses == 1)
    }

    @Test func aThreeFrameExportReadsAsAnimated() {
        let stream = AnimationEncoder.encode(AnimationTestKit.movingBox(), options: AnimationExportOptions(order: .asDrawn))
        #expect(AnsiAnalysis(ArtFile(data: stream.data, fileExtension: "ans")).isAnimated)
    }
}
