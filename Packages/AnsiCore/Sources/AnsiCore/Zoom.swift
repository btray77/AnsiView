import CoreGraphics

/// How a window sizes its art.
public enum ZoomMode: Equatable {
    /// Fill the window keeping proportions (scrollers fit the width and scroll).
    case fit
    /// Like `fit`, but only whole device pixels per font pixel, so every pixel is the same size.
    case integerFit
    /// A fixed size: this many points per font pixel.
    case scale(Int)

    public var label: String {
        switch self {
        case .fit: return "Fit to Window"
        case .integerFit: return "Integer Fit"
        case .scale(let n): return "\(n)x"
        }
    }
}

public enum Zoom {
    /// The canvas size in points for art `artPixels` font pixels in size (before the CRT aspect
    /// stretch) in a view of `available` points. `scroller` allows tall art to fit the width and
    /// scroll instead of shrinking to fit the height.
    public static func canvasSize(artPixels: CGSize, aspect: CGFloat, available: CGSize, mode: ZoomMode,
                                  scroller: Bool, backingScale: CGFloat) -> CGSize {
        let width = artPixels.width, height = artPixels.height
        guard width > 0, height > 0 else { return .zero }
        let stretched = (height * aspect).rounded()
        let backing = max(1, backingScale)
        // Fitting the width would leave the art taller than the window: it scrolls instead.
        let scrolls = available.width > 0
            && scroller && stretched * (available.width / width) > available.height

        switch mode {
        case .fit:
            guard available.width > 0, available.height > 0 else { return .zero }
            let widthScale = available.width / width
            let scale = scrolls ? widthScale : min(widthScale, available.height / stretched)
            return CGSize(width: (width * scale).rounded(), height: (stretched * scale).rounded())
        case .integerFit:
            // Whole device pixels per font pixel: k across, round(k * aspect) down.
            func vertical(_ k: Int) -> CGFloat { (CGFloat(k) * aspect).rounded() }
            var k = max(1, Int((available.width * backing / width).rounded(.down)))
            if !scrolls {
                while k > 1, height * vertical(k) > available.height * backing { k -= 1 }
            }
            return CGSize(width: width * CGFloat(k) / backing, height: height * vertical(k) / backing)
        case .scale(let n):
            let n = CGFloat(max(1, n))
            return CGSize(width: width * n, height: (stretched * n).rounded())
        }
    }
}
