import Foundation

/// A rectangle in pixels, origin at the top left.
public struct PixelRect: Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// How art fills a desktop picture.
public enum WallpaperMode: String, CaseIterable {
    case centred, tiled

    public var label: String { self == .centred ? "Centred" : "Tiled" }
}

/// Desktop pictures from art (plan 10 ruling 4).
public enum Wallpaper {
    public struct Layout: Equatable {
        /// Pixels per font pixel.
        public let scale: Int
        /// Where each copy of the art goes on the screen.
        public let tiles: [PixelRect]
    }

    /// Centred: the largest whole scale that fits (at least 1), centred, with tall art showing its
    /// top. Tiled: copies at `scale` from the top left until the screen is covered.
    public static func layout(artWidth: Int, artHeight: Int, screenWidth: Int, screenHeight: Int,
                              mode: WallpaperMode, scale: Int = 1) -> Layout {
        let aw = max(1, artWidth), ah = max(1, artHeight)
        switch mode {
        case .centred:
            let fit = max(1, min(screenWidth / aw, screenHeight / ah))
            let width = aw * fit, height = ah * fit
            let y = height > screenHeight ? 0 : (screenHeight - height) / 2
            return Layout(scale: fit, tiles: [PixelRect(x: (screenWidth - width) / 2, y: y, width: width, height: height)])
        case .tiled:
            let s = max(1, scale)
            let width = aw * s, height = ah * s
            var tiles: [PixelRect] = []
            var y = 0
            repeat {
                var x = 0
                repeat {
                    tiles.append(PixelRect(x: x, y: y, width: width, height: height))
                    x += width
                } while x < screenWidth
                y += height
            } while y < screenHeight
            return Layout(scale: s, tiles: tiles)
        }
    }

    /// The colour around centred art: what its top left cell shows (black for empty art).
    public static func background(_ screen: AnsiScreen) -> RGB {
        guard let cell = screen.rows.first?.first else { return Palette.vga[0] }
        return cell.code == 0xDB && cell.scalar == nil ? cell.fg : cell.bg
    }

    /// "2560x1440" as a width and height.
    public static func parseSize(_ text: String) -> (Int, Int)? {
        let parts = text.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return (parts[0], parts[1])
    }
}
