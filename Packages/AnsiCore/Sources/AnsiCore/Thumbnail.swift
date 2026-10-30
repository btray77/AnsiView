import CoreGraphics
import Foundation

/// Small pictures of art for the gallery and Finder: the finished art from the top, cropped to at
/// most a square, fitted to the requested size.
public enum Thumbnail {
    /// Thumbnails never enlarge art past this many pixels per font pixel.
    public static let maxUpscale: CGFloat = 2

    /// Rows to show: all of them, or as many as fit in a square as wide as the art.
    public static func rows(for file: ArtFile, screen: AnsiScreen) -> Int {
        let cellWidth = screen.font.width + (file.ninePixel ? 1 : 0)
        let rowHeight = CGFloat(screen.font.height) * AnsiRenderer.pixelAspect(for: screen, ninePixel: file.ninePixel)
        let square = Int((CGFloat(screen.columns * cellWidth) / rowHeight).rounded(.down))
        return max(1, min(screen.rows.count, square))
    }

    /// `artPoints` fitted inside `maximum`, keeping proportions, at most `maxUpscale` times larger.
    public static func size(artPoints: CGSize, maximum: CGSize) -> CGSize {
        guard artPoints.width > 0, artPoints.height > 0 else { return .zero }
        let scale = min(maximum.width / artPoints.width, maximum.height / artPoints.height, maxUpscale)
        return CGSize(width: max(1, (artPoints.width * scale).rounded()),
                      height: max(1, (artPoints.height * scale).rounded()))
    }

    /// The thumbnail image, `size(...)` pixels in size; nil when `maximum` is empty.
    public static func render(_ file: ArtFile, maximum: CGSize) -> CGImage? {
        guard maximum.width >= 1, maximum.height >= 1 else { return nil }
        return render(file, screen: AnsiAnalysis(file).finalScreen, maximum: maximum)
    }

    /// The same, from the file's finished screen when the caller already played it (the library indexer).
    public static func render(_ file: ArtFile, screen finalScreen: AnsiScreen, maximum: CGSize) -> CGImage? {
        guard maximum.width >= 1, maximum.height >= 1 else { return nil }
        var screen = finalScreen
        let rowCount = rows(for: file, screen: screen)
        screen.rows = Array(screen.rows.prefix(rowCount))
        var options = RenderOptions(for: screen, scale: 1)
        options.ninePixel = file.ninePixel
        guard let rendered = AnsiRenderer.render(screen, options: options) else { return nil }
        let points = CGSize(width: CGFloat(rendered.image.width),
                            height: (CGFloat(rendered.image.height) * rendered.pixelAspect).rounded())
        let target = size(artPoints: points, maximum: maximum)
        let width = Int(target.width), height = Int(target.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // Enlarging keeps hard pixel edges; shrinking averages so text does not shimmer.
        context.interpolationQuality = target.width >= points.width ? .none : .high
        context.draw(rendered.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
