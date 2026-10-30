import AnsiCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws art as a desktop picture of an exact pixel size (plan 10 ruling 4). Used by File >
/// Export Wallpaper and `ansirender --wallpaper`.
enum WallpaperRenderer {
    static func image(_ screen: AnsiScreen, width: Int, height: Int, mode: WallpaperMode, scale: Int = 1) throws -> CGImage {
        let one = AnsiExporter.onePixelSize(screen)
        let layout = Wallpaper.layout(artWidth: Int(one.width), artHeight: Int(one.height),
                                      screenWidth: width, screenHeight: height, mode: mode, scale: scale)
        let art = try AnsiExporter.renderImage(screen, scale: Double(layout.scale), blinkVisible: true)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw AnsiExportError.renderFailed }
        let background = Wallpaper.background(screen)
        context.setFillColor(red: CGFloat(background.r) / 255, green: CGFloat(background.g) / 255,
                             blue: CGFloat(background.b) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        for tile in layout.tiles {
            // Core Graphics counts from the bottom; the layout from the top.
            context.draw(art, in: CGRect(x: tile.x, y: height - tile.y - art.height, width: art.width, height: art.height))
        }
        guard let image = context.makeImage() else { throw AnsiExportError.renderFailed }
        return image
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw AnsiExportError.encodeFailed("image destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AnsiExportError.encodeFailed("finalize") }
    }
}
