import Testing
@testable import AnsiCore

@Suite struct OKLabTests {
    @Test func whiteAndBlack() {
        let white = OKLab.lab(RGB(r: 255, g: 255, b: 255))
        #expect(abs(white.x - 1) < 0.001 && abs(white.y) < 0.001 && abs(white.z) < 0.001)
        let black = OKLab.lab(RGB(r: 0, g: 0, b: 0))
        #expect(black.x == 0 && black.y == 0 && black.z == 0)
    }

    @Test func roundTrip() {
        for color in Palette.vga {
            let linear = OKLab.linearRGB(lab: OKLab.lab(color))
            #expect(OKLab.rgb(linear: linear) == color)
        }
        for v in [0, 1, 10, 11, 128, 254, 255] as [UInt8] {
            #expect(OKLab.byte(srgb: OKLab.srgb(linear: OKLab.linear(v))) == v)
        }
    }

    /// The old converter's squared RGB distance turned this mustard yellow into VGA brown.
    @Test func darkYellowNotBrown() {
        let mustard = RGB(r: 210, g: 190, b: 0)
        func rgbNearest(_ c: RGB) -> Int {
            func d(_ i: Int) -> Int {
                let k = Palette.vga[i]
                let dr = Int(c.r) - Int(k.r), dg = Int(c.g) - Int(k.g), db = Int(c.b) - Int(k.b)
                return dr * dr + dg * dg + db * db
            }
            return (0..<16).min { d($0) < d($1) }!
        }
        #expect(rgbNearest(mustard) == 6)
        #expect(OKLab.nearest(OKLab.lab(mustard), in: OKLab.vga, allowed: 0...15) != 6)
        #expect(OKLab.nearest(OKLab.lab(RGB(r: 250, g: 240, b: 40)), in: OKLab.vga, allowed: 0...15) == 14)
    }

    @Test func nearestRespectsAllowed() {
        let bright = OKLab.lab(Palette.vga[12])
        #expect(OKLab.nearest(bright, in: OKLab.vga, allowed: 0...15) == 12)
        #expect(OKLab.nearest(bright, in: OKLab.vga, allowed: 0...7) < 8)
    }
}
