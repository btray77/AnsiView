import CoreGraphics
import Testing
@testable import AnsiCore

private let dos = CGSize(width: 640, height: 400)

@Test func requestedScaleFits() {
    #expect(SizeFit.scale(artPixels: dos, requestedScale: 2, maxPixels: CGSize(width: 1280, height: 800)) == 2)
}

@Test func largestIntegerScaleThatFits() {
    #expect(SizeFit.scale(artPixels: dos, requestedScale: 3, maxPixels: CGSize(width: 1300, height: 900)) == 2)
}

@Test func resampleBelowOne() {
    #expect(SizeFit.scale(artPixels: dos, requestedScale: 2, maxPixels: CGSize(width: 320, height: 320)) == 0.5)
}

@Test func ladderOrder() {
    let ladder = SizeFit.ladder(requestedScale: 2, fps: 15, animated: true)
    let pairs = ladder.map { [$0.scale, $0.fps] }
    #expect(Array(pairs.prefix(7)) == [[2, 15], [2, 10], [2, 5], [1, 15], [1, 10], [1, 5], [0.75, 15]])
    #expect(pairs.last == [0.25, 5])
    #expect(SizeFit.ladder(requestedScale: 1, fps: 8, animated: true).map(\.fps).prefix(2) == [8, 5])
}

@Test func stillLadderHasNoFrameRates() {
    let ladder = SizeFit.ladder(requestedScale: 2, fps: 15, animated: false)
    #expect(ladder.map(\.scale) == [2, 1, 0.75, 0.5, 0.25])
    #expect(ladder.allSatisfy { $0.fps == 0 })
}

@Test func nextTriesFrameRateWhenClose() {
    let ladder = SizeFit.ladder(requestedScale: 2, fps: 15, animated: true)
    #expect(SizeFit.next(after: ladder[0], bytes: 110_000, target: 100_000, ladder: ladder) == ExportAttempt(scale: 2, fps: 10))
}

@Test func nextSkipsHopelessRungs() {
    let ladder = SizeFit.ladder(requestedScale: 2, fps: 15, animated: true)
    #expect(SizeFit.next(after: ladder[0], bytes: 400_000, target: 100_000, ladder: ladder) == ExportAttempt(scale: 1, fps: 15))
}

@Test func ladderEndsWhenNothingFits() {
    let ladder = SizeFit.ladder(requestedScale: 2, fps: 15, animated: true)
    // Nothing is predicted to fit: the smallest rung is tried, then there is nothing left.
    #expect(SizeFit.next(after: ladder[0], bytes: 50_000_000, target: 1, ladder: ladder) == ladder.last)
    #expect(SizeFit.next(after: ladder.last!, bytes: 50_000, target: 1, ladder: ladder) == nil)
}
