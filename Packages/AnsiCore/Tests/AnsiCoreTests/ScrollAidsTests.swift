import CoreGraphics
import Testing
@testable import AnsiCore

struct ScrollAidsTests {
    @Test func autoScrollMovesAtSpeed() {
        let step = AutoScroll.offset(from: 100, elapsed: 0.5, linesPerSecond: 8, pointsPerLine: 16, maxOffset: 1000)
        #expect(step.offset == 164)
        #expect(!step.atEnd)
    }

    @Test func autoScrollClampsAtEnd() {
        let step = AutoScroll.offset(from: 990, elapsed: 1, linesPerSecond: 8, pointsPerLine: 16, maxOffset: 1000)
        #expect(step.offset == 1000)
        #expect(step.atEnd)
        // A long stall (the window was hidden) never jumps more than half a second's worth.
        let stalled = AutoScroll.offset(from: 0, elapsed: 30, linesPerSecond: 8, pointsPerLine: 16, maxOffset: 1000)
        #expect(stalled.offset == 64)
    }

    @Test func speedSteps() {
        #expect(AutoScroll.step(8, by: 1) == 12)
        #expect(AutoScroll.step(8, by: -1) == 4)
        #expect(AutoScroll.step(48, by: 1) == 48)
        #expect(AutoScroll.step(2, by: -1) == 2)
        #expect(AutoScroll.step(5, by: 1) == 12)
        #expect(AutoScroll.isUseful(documentHeight: 900, visibleHeight: 600))
        #expect(!AutoScroll.isUseful(documentHeight: 600, visibleHeight: 600))
    }

    @Test func minimapIndicatorAndJump() {
        let map = MinimapGeometry(documentHeight: 4000, visibleHeight: 500, stripHeight: 400)
        let box = map.indicator(offset: 1000)
        #expect(box.y == 100)
        #expect(box.height == 50)
        // Clicking at 75% centres the view there.
        #expect(map.offset(forStripY: 300) == 2750)
        #expect(map.offset(forStripY: 0) == 0)
        #expect(map.offset(forStripY: 400) == 3500)
        // The box stays big enough to grab.
        #expect(MinimapGeometry(documentHeight: 400_000, visibleHeight: 500, stripHeight: 400).indicator(offset: 0).height == 6)
    }

    @Test func minimapShownForTallArtOnly() {
        #expect(MinimapGeometry.isShown(documentHeight: 1000, visibleHeight: 500))
        #expect(!MinimapGeometry.isShown(documentHeight: 999, visibleHeight: 500))
        #expect(!MinimapGeometry.isShown(documentHeight: 1000, visibleHeight: 0))
    }
}
