import Foundation

/// Per cell glyph search (image import ruling 6): for one character cell of source pixels, the
/// glyph and colour pair whose rendering is closest in OKLab.
///
/// Each glyph's font mask is reduced to blocks (2x2 by default, so an 8x16 cell becomes 4x8
/// coverage values). The eye blends a shade pattern at that scale, so `░` counts as a 25% mix
/// rather than as scattered dots. For a pair (fg, bg) a block with coverage `k` shows the linear
/// light mix `fg * k + bg * (1 - k)`. The error is the sum of squared OKLab distances, which
/// splits per coverage group into `Σ|p|² - 2 Σp · c + n |c|²`, so each glyph and pair costs a
/// few multiplications instead of one per pixel.
struct GlyphSearch {
    /// Space, full block, the four half blocks, the three shades.
    static let basicGlyphs: [UInt8] = [32, 219, 223, 220, 221, 222, 176, 177, 178]
    /// ■ ─ │ ┼ / \ _ ═ ║ ∙
    static let extendedGlyphs: [UInt8] = [254, 196, 179, 197, 47, 92, 95, 205, 186, 249]

    struct Match: Equatable {
        let code: UInt8
        let fg: Int
        let bg: Int
        /// Sum of squared OKLab distances over the cell's sub pixels.
        let error: Float
        /// The cell's average colour as drawn, in linear light.
        let rendered: SIMD3<Float>
    }

    private struct Group {
        let level: Int
        let indexes: [Int]
    }

    let subWidth: Int
    let subHeight: Int
    let glyphCodes: [UInt8]
    private let coverages: [[Float]]
    private let groups: [[Group]]
    private let levels: [Float]
    private let colorCount: Int
    private let backgrounds: ClosedRange<Int>
    private let linear: [SIMD3<Float>]
    /// OKLab of the mix of fg and bg at each level, index `(fg * colorCount + bg) * levels.count + level`.
    private let mixLab: [SIMD3<Float>]
    private let mixNorm: [Float]

    init(font: BitmapFont, glyphs: [UInt8], palette: [RGB], allowedBackgrounds: ClosedRange<Int>, block: Int = 2) {
        let block = max(1, block)
        subWidth = max(1, font.width / block)
        subHeight = max(1, font.height / block)
        glyphCodes = glyphs
        colorCount = palette.count
        backgrounds = allowedBackgrounds.clamped(to: 0...(palette.count - 1))
        linear = palette.map { OKLab.linear($0) }
        var coverages: [[Float]] = []
        for code in glyphs {
            let pixels = font.pixels(for: code)
            var coverage = [Float](repeating: 0, count: subWidth * subHeight)
            for y in 0..<(subHeight * block) {
                for x in 0..<(subWidth * block) where pixels[y * font.width + x] {
                    coverage[(y / block) * subWidth + x / block] += 1
                }
            }
            coverages.append(coverage.map { $0 / Float(block * block) })
        }
        self.coverages = coverages
        let levels = Array(Set(coverages.flatMap { $0 })).sorted()
        self.levels = levels
        groups = coverages.map { coverage in
            levels.indices.compactMap { level in
                let indexes = coverage.indices.filter { coverage[$0] == levels[level] }
                return indexes.isEmpty ? nil : Group(level: level, indexes: indexes)
            }
        }
        var mixLab: [SIMD3<Float>] = []
        mixLab.reserveCapacity(palette.count * palette.count * levels.count)
        for fg in 0..<palette.count {
            for bg in 0..<palette.count {
                for k in levels { mixLab.append(OKLab.match(linear: linear[fg] * k + linear[bg] * (1 - k))) }
            }
        }
        self.mixLab = mixLab
        mixNorm = mixLab.map { ($0 * $0).sum() }
    }


    /// A glyph's coverage per sub pixel (row major), for tests.
    func coverage(_ code: UInt8) -> [Float] {
        glyphCodes.firstIndex(of: code).map { coverages[$0] } ?? []
    }

    /// The best glyph and pair for `cell`: `subWidth * subHeight` linear RGB sub pixels, row major.
    /// Ties keep the earlier glyph, then the lower fg, then the lower bg.
    func best(cell: [SIMD3<Float>]) -> Match {
        let labs = cell.map { OKLab.match(linear: $0) }
        let total = labs.reduce(Float(0)) { $0 + ($1 * $1).sum() }
        let levelCount = levels.count
        var bestError = Float.greatestFiniteMagnitude
        var best = (glyph: 0, fg: 7, bg: backgrounds.lowerBound)
        var sums: [(level: Int, n: Float, p: SIMD3<Float>)] = []
        for (g, glyphGroups) in groups.enumerated() {
            sums.removeAll(keepingCapacity: true)
            for group in glyphGroups {
                var p = SIMD3<Float>.zero
                for i in group.indexes { p += labs[i] }
                sums.append((group.level, Float(group.indexes.count), p))
            }
            let onlyBackground = sums.count == 1 && levels[sums[0].level] == 0
            let onlyForeground = sums.count == 1 && levels[sums[0].level] == 1
            let fgs = onlyBackground ? 7...7 : 0...(colorCount - 1)
            let bgs = onlyForeground ? backgrounds.lowerBound...backgrounds.lowerBound : backgrounds
            for fg in fgs {
                for bg in bgs {
                    if sums.count > 1, fg == bg { continue }
                    let base = (fg * colorCount + bg) * levelCount
                    var e = total
                    for s in sums {
                        let c = mixLab[base + s.level]
                        e += s.n * mixNorm[base + s.level] - 2 * (s.p * c).sum()
                    }
                    if e < bestError { bestError = e; best = (g, fg, bg) }
                }
            }
        }
        var rendered = SIMD3<Float>.zero
        for k in coverages[best.glyph] { rendered += linear[best.fg] * k + linear[best.bg] * (1 - k) }
        rendered /= Float(max(1, cell.count))
        return Match(code: glyphCodes[best.glyph], fg: best.fg, bg: best.bg, error: max(0, bestError), rendered: rendered)
    }

    /// Truecolor: the binary glyphs only, each side drawn in the linear mean of its pixels.
    static let trueColorGlyphs: [UInt8] = [219, 223, 220, 221, 222]

    /// The best binary glyph with free colours for a truecolor cell; `fg`/`bg` are linear RGB.
    func bestTrueColor(cell: [SIMD3<Float>]) -> (code: UInt8, fg: SIMD3<Float>, bg: SIMD3<Float>) {
        let labs = cell.map { OKLab.lab(linear: $0) }
        var best: (code: UInt8, fg: SIMD3<Float>, bg: SIMD3<Float>) = (219, .zero, .zero)
        var bestError = Float.greatestFiniteMagnitude
        for (g, code) in glyphCodes.enumerated() {
            var fgSum = SIMD3<Float>.zero, bgSum = SIMD3<Float>.zero
            var fgCount: Float = 0, bgCount: Float = 0
            for (i, k) in coverages[g].enumerated() {
                if k >= 0.5 { fgSum += cell[i]; fgCount += 1 } else { bgSum += cell[i]; bgCount += 1 }
            }
            let fg = fgCount > 0 ? fgSum / fgCount : .zero
            let bg = bgCount > 0 ? bgSum / bgCount : .zero
            let fgLab = OKLab.lab(linear: fg), bgLab = OKLab.lab(linear: bg)
            var e: Float = 0
            for (i, k) in coverages[g].enumerated() {
                let d = labs[i] - (k >= 0.5 ? fgLab : bgLab)
                e += (d * d).sum()
            }
            if e < bestError { bestError = e; best = (code, fg, bg) }
        }
        return best
    }
}
