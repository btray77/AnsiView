import CoreGraphics
import Testing
@testable import AnsiCore

struct ZoomTests {
    let screen = CGSize(width: 640, height: 400)

    @Test func fitMatchesOldBehaviour() {
        #expect(Zoom.canvasSize(artPixels: screen, aspect: 1, available: CGSize(width: 960, height: 600),
                                mode: .fit, scroller: false, backingScale: 1) == CGSize(width: 960, height: 600))
        let tall = CGSize(width: 640, height: 1600)
        #expect(Zoom.canvasSize(artPixels: tall, aspect: 1, available: CGSize(width: 960, height: 600),
                                mode: .fit, scroller: true, backingScale: 1) == CGSize(width: 960, height: 2400))
        // Not a scroller: the whole thing fits the height.
        #expect(Zoom.canvasSize(artPixels: tall, aspect: 1, available: CGSize(width: 960, height: 600),
                                mode: .fit, scroller: false, backingScale: 1) == CGSize(width: 240, height: 600))
    }

    @Test func integerFitSnaps() {
        let available = CGSize(width: 1000, height: 700)
        #expect(Zoom.canvasSize(artPixels: screen, aspect: 1, available: available,
                                mode: .integerFit, scroller: false, backingScale: 1) == CGSize(width: 640, height: 400))
        #expect(Zoom.canvasSize(artPixels: screen, aspect: 1, available: available,
                                mode: .integerFit, scroller: false, backingScale: 2) == CGSize(width: 960, height: 600))
    }

    @Test func integerFitKeepsAspectWhole() {
        #expect(Zoom.canvasSize(artPixels: screen, aspect: 1.2, available: CGSize(width: 2000, height: 2000),
                                mode: .integerFit, scroller: false, backingScale: 1) == CGSize(width: 1920, height: 1600))
    }

    @Test func integerFitScrollerFitsWidth() {
        let tall = CGSize(width: 640, height: 1600)
        #expect(Zoom.canvasSize(artPixels: tall, aspect: 1, available: CGSize(width: 1300, height: 600),
                                mode: .integerFit, scroller: true, backingScale: 1) == CGSize(width: 1280, height: 3200))
    }

    @Test func scaleKeepsExactAspect() {
        #expect(Zoom.canvasSize(artPixels: screen, aspect: 1.2, available: CGSize(width: 100, height: 100),
                                mode: .scale(2), scroller: false, backingScale: 2) == CGSize(width: 1280, height: 960))
    }

    @Test func zeroAvailableKeepsMinimum() {
        #expect(Zoom.canvasSize(artPixels: screen, aspect: 1, available: .zero,
                                mode: .fit, scroller: false, backingScale: 1) == .zero)
        #expect(Zoom.canvasSize(artPixels: screen, aspect: 1, available: .zero,
                                mode: .integerFit, scroller: false, backingScale: 2) == CGSize(width: 320, height: 200))
    }

    @Test func integerFitNeverBelowOnePixel() {
        let big = CGSize(width: 2000, height: 2000)
        #expect(Zoom.canvasSize(artPixels: big, aspect: 1, available: CGSize(width: 100, height: 100),
                                mode: .integerFit, scroller: false, backingScale: 1) == big)
    }

    @Test func labels() {
        #expect(ZoomMode.fit.label == "Fit to Window")
        #expect(ZoomMode.integerFit.label == "Integer Fit")
        #expect(ZoomMode.scale(2).label == "2x")
    }
}
