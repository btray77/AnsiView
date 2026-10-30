import CoreGraphics
import Foundation

/// Smooth auto scroll for tall art (plan 9 ruling 4): the view moves down at a steady number of
/// art lines per second.
public enum AutoScroll {
    public static let speeds = [2, 4, 8, 12, 16, 24, 32, 48]
    public static let defaultSpeed = 8
    /// The longest gap between two ticks that still moves the view (a hidden window or a stall
    /// does not make it jump).
    public static let maxElapsed: TimeInterval = 0.5

    /// The next speed up (+1) or down (-1); a speed not in the list is treated as the default.
    public static func step(_ speed: Int, by direction: Int) -> Int {
        let index = speeds.firstIndex(of: speed) ?? speeds.firstIndex(of: defaultSpeed)!
        return speeds[min(speeds.count - 1, max(0, index + direction))]
    }

    /// Where the view's top goes after `elapsed` seconds, and whether it reached the bottom.
    public static func offset(from current: CGFloat, elapsed: TimeInterval, linesPerSecond: Int,
                              pointsPerLine: CGFloat, maxOffset: CGFloat) -> (offset: CGFloat, atEnd: Bool) {
        let seconds = min(max(0, elapsed), maxElapsed)
        let next = min(maxOffset, current + CGFloat(seconds) * CGFloat(linesPerSecond) * pointsPerLine)
        return (max(0, next), next >= maxOffset)
    }

    /// Auto scroll is offered only when there is something to scroll to.
    public static func isUseful(documentHeight: CGFloat, visibleHeight: CGFloat) -> Bool {
        documentHeight > visibleHeight + 1
    }
}

/// The minimap strip for tall art (plan 9 ruling 5): the whole art squeezed into the strip, with a
/// box over the part on screen.
public struct MinimapGeometry {
    public static let minimumBox: CGFloat = 6
    public let documentHeight: CGFloat
    public let visibleHeight: CGFloat
    public let stripHeight: CGFloat

    public init(documentHeight: CGFloat, visibleHeight: CGFloat, stripHeight: CGFloat) {
        self.documentHeight = max(1, documentHeight)
        self.visibleHeight = max(0, visibleHeight)
        self.stripHeight = max(0, stripHeight)
    }

    private var scale: CGFloat { stripHeight / documentHeight }
    private var maxOffset: CGFloat { max(0, documentHeight - visibleHeight) }

    /// The box for the view whose top is at `offset`, in strip points from the top.
    public func indicator(offset: CGFloat) -> (y: CGFloat, height: CGFloat) {
        let height = min(stripHeight, max(Self.minimumBox, visibleHeight * scale))
        let y = min(stripHeight - height, max(0, offset * scale))
        return (y, height)
    }

    /// The view's top that centres it on the art at strip point `y`, kept inside the art.
    public func offset(forStripY y: CGFloat) -> CGFloat {
        guard stripHeight > 0 else { return 0 }
        let centre = y / stripHeight * documentHeight
        return min(maxOffset, max(0, centre - visibleHeight / 2))
    }

    /// The strip appears for art at least twice as tall as the window.
    public static func isShown(documentHeight: CGFloat, visibleHeight: CGFloat) -> Bool {
        visibleHeight > 0 && documentHeight >= visibleHeight * 2
    }
}
