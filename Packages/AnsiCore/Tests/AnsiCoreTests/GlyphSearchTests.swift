import CoreGraphics
import Testing
@testable import AnsiCore

private func cell(_ color: (Int, Int) -> RGB) -> [SIMD3<Float>] {
    (0..<32).map { OKLab.linear(color($0 % 4, $0 / 4)) }
}

private func search(ice: Bool = true, extended: Bool = false) -> GlyphSearch {
    GlyphSearch(font: .vga, glyphs: GlyphSearch.basicGlyphs + (extended ? GlyphSearch.extendedGlyphs : []),
                palette: Palette.vga, allowedBackgrounds: ice ? 0...15 : 0...7)
}

@Suite struct GlyphSearchTests {
    @Test func coverageLevelsFromTheFont() {
        let s = search(extended: true)
        #expect(s.subWidth == 4 && s.subHeight == 8)
        #expect(s.coverage(32).allSatisfy { $0 == 0 } && s.coverage(219).allSatisfy { $0 == 1 })
        #expect(s.coverage(176).allSatisfy { $0 == 0.25 })
        #expect(s.coverage(177).allSatisfy { $0 == 0.5 })
        #expect(s.coverage(178).allSatisfy { $0 == 0.75 })
        // The VGA font's upper half block is 7 rows of 16 and the lower one 9: they still tile the cell.
        let upper = s.coverage(223), lower = s.coverage(220)
        #expect((0..<32).allSatisfy { upper[$0] + lower[$0] == 1 })
        #expect(upper[0..<12].allSatisfy { $0 == 1 } && upper[16...].allSatisfy { $0 == 0 })
        let left = s.coverage(221)
        #expect((0..<32).allSatisfy { left[$0] == ($0 % 4 < 2 ? 1 : 0) })
    }

    @Test func flatColourPicksSolid() {
        let match = search().best(cell: cell { _, _ in Palette.vga[12] })
        #expect((match.code == 32 && match.bg == 12) || (match.code == 219 && match.fg == 12))
        #expect(match.error < 1e-4)
    }

    @Test func topBottomSplit() {
        let match = search().best(cell: cell { _, y in y < 4 ? Palette.vga[12] : Palette.vga[1] })
        let ok = (match.code == 223 && match.fg == 12 && match.bg == 1) || (match.code == 220 && match.fg == 1 && match.bg == 12)
        #expect(ok, "\(match)")
    }

    @Test func leftRightSplit() {
        let match = search().best(cell: cell { x, _ in x < 2 ? Palette.vga[10] : Palette.vga[4] })
        let ok = (match.code == 221 && match.fg == 10 && match.bg == 4) || (match.code == 222 && match.fg == 4 && match.bg == 10)
        #expect(ok, "\(match)")
    }

    @Test func fiftyPercentMixPicksMediumShade() {
        let mix = (OKLab.linear(Palette.vga[1]) + OKLab.linear(Palette.vga[0])) * 0.5
        let match = search().best(cell: [SIMD3<Float>](repeating: mix, count: 32))
        #expect(match.code == 177 && Set([match.fg, match.bg]) == Set([1, 0]), "\(match)")
        #expect(((match.rendered - mix) * (match.rendered - mix)).sum() < 1e-6)
    }

    @Test func noIceKeepsDarkBackgrounds() {
        var seed: UInt64 = 7
        func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(seed >> 56) }
        let s = search(ice: false)
        for _ in 0..<40 {
            let match = s.best(cell: (0..<32).map { _ in OKLab.linear(RGB(r: next(), g: next(), b: next())) })
            #expect(match.bg < 8)
        }
    }

    @Test func matchesBruteForce() {
        var seed: UInt64 = 99
        func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(seed >> 56) }
        let s = search(extended: true)
        let linear = Palette.vga.map { OKLab.linear($0) }
        for _ in 0..<50 {
            let pixels = (0..<32).map { _ in OKLab.linear(RGB(r: next(), g: next(), b: next())) }
            let labs = pixels.map { OKLab.match(linear: $0) }
            var best = Float.greatestFiniteMagnitude
            for code in s.glyphCodes {
                let coverage = s.coverage(code)
                for fg in 0..<16 {
                    for bg in 0..<16 {
                        var e: Float = 0
                        for i in 0..<32 {
                            let d = labs[i] - OKLab.match(linear: linear[fg] * coverage[i] + linear[bg] * (1 - coverage[i]))
                            e += (d * d).sum()
                        }
                        best = min(best, e)
                    }
                }
            }
            let match = s.best(cell: pixels)
            #expect(abs(match.error - best) <= 1e-3 * max(1, best), "\(match.error) vs \(best)")
        }
    }

    @Test func extendedFindsHorizontalLine() {
        // A one pixel high bright line across the middle of a dark cell: row 8 of the 8x16 cell.
        let font = BitmapFont.vga
        let line = font.pixels(for: 196)
        var pixels = [SIMD3<Float>](repeating: .zero, count: 32)
        for y in 0..<16 { for x in 0..<8 where line[y * 8 + x] { pixels[(y / 2) * 4 + x / 2] += OKLab.linear(Palette.vga[15]) * 0.25 } }
        #expect(search(extended: true).best(cell: pixels).code == 196)
        #expect(search(extended: false).best(cell: pixels).code != 196)
    }

    /// Anti-aliased grey edges stay grey: chroma counts double when matching (OKLab.chromaWeight).
    @Test func greysStayGrey() {
        let s = search(extended: true)
        for level in Swift.stride(from: 20, through: 240, by: 10) {
            for split in [0, 2, 4, 6] {
                let pixels = (0..<32).map { i -> SIMD3<Float> in
                    i / 4 < split ? OKLab.linear(Palette.vga[15]) : OKLab.linear(RGB(r: UInt8(level), g: UInt8(level), b: UInt8(level)))
                }
                let match = s.best(cell: pixels)
                let greys: Set<Int> = [0, 7, 8, 15]
                #expect(greys.contains(match.fg) || match.code == 32, "\(level) \(split) \(match)")
                #expect(greys.contains(match.bg) || match.code == 219, "\(level) \(split) \(match)")
            }
        }
    }
}
