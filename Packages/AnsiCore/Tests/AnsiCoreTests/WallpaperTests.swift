import Testing
@testable import AnsiCore

@Suite struct WallpaperTests {
    @Test func centredPicksLargestWholeScale() {
        // 640x400 art on a 2880x1800 screen: 4x is 2560x1600, 5x would be too tall.
        let layout = Wallpaper.layout(artWidth: 640, artHeight: 400, screenWidth: 2880, screenHeight: 1800, mode: .centred)
        #expect(layout.scale == 4)
        #expect(layout.tiles == [PixelRect(x: 160, y: 100, width: 2560, height: 1600)])
    }

    @Test func centredTallArtShowsTop() {
        let layout = Wallpaper.layout(artWidth: 640, artHeight: 4000, screenWidth: 1920, screenHeight: 1080, mode: .centred)
        #expect(layout.scale == 1)
        #expect(layout.tiles == [PixelRect(x: 640, y: 0, width: 640, height: 4000)])
    }

    @Test func centredWiderThanScreenStaysCentred() {
        let layout = Wallpaper.layout(artWidth: 1280, artHeight: 400, screenWidth: 1024, screenHeight: 768, mode: .centred)
        #expect(layout.scale == 1)
        #expect(layout.tiles == [PixelRect(x: -128, y: 184, width: 1280, height: 400)])
    }

    @Test func tiledCoversScreen() {
        let layout = Wallpaper.layout(artWidth: 640, artHeight: 400, screenWidth: 1500, screenHeight: 900, mode: .tiled, scale: 1)
        #expect(layout.scale == 1)
        #expect(layout.tiles.count == 3 * 3)
        #expect(layout.tiles.first == PixelRect(x: 0, y: 0, width: 640, height: 400))
        #expect(layout.tiles.last == PixelRect(x: 1280, y: 800, width: 640, height: 400))
        let scaled = Wallpaper.layout(artWidth: 640, artHeight: 400, screenWidth: 1500, screenHeight: 900, mode: .tiled, scale: 2)
        #expect(scaled.tiles.count == 2 * 2)
    }

    @Test func backgroundIsTopLeftCell() {
        let blue = AnsiScreen(columns: 2, rows: [[AnsiCell(code: 0x20, bg: Palette.vga[1]), AnsiCell(code: 0x41)]])
        #expect(Wallpaper.background(blue) == Palette.vga[1])
        #expect(Wallpaper.background(AnsiScreen(columns: 2, rows: [])) == Palette.vga[0])
        // A full block shows its foreground.
        let block = AnsiScreen(columns: 1, rows: [[AnsiCell(code: 0xDB, fg: Palette.vga[4])]])
        #expect(Wallpaper.background(block) == Palette.vga[4])
    }

    @Test func parsesSize() {
        #expect(Wallpaper.parseSize("2560x1440").map { [$0.0, $0.1] } == [2560, 1440])
        #expect(Wallpaper.parseSize("12X8").map { [$0.0, $0.1] } == [12, 8])
        #expect(Wallpaper.parseSize("0x8") == nil)
        #expect(Wallpaper.parseSize("big") == nil)
    }
}
