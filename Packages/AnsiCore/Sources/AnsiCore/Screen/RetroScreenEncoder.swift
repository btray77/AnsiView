import Foundation

/// A home computer or videotex platform a designed screen can be exported for (final gaps ruling 8).
/// The terminal emulations for them are in `TerminalEngines`; this is the other direction.
public enum RetroPlatform: String, CaseIterable, Codable {
    case petscii64, petscii128, atascii, viewdata

    public var emulation: TerminalEmulation {
        switch self {
        case .petscii64: return .petscii64
        case .petscii128: return .petscii128
        case .atascii: return .atascii
        case .viewdata: return .viewdata
        }
    }

    public var label: String { emulation.label }
    public var columns: Int { self == .petscii128 ? 80 : 40 }
    public var rows: Int { self == .atascii || self == .viewdata ? 24 : 25 }

    /// `.seq` is Synchronet's PETSCII display file type; `.ata` the usual ATASCII extension
    /// (no BBS package documents one); Viewdata is written as a Telstar frame.
    public var fileExtension: String {
        switch self {
        case .petscii64, .petscii128: return "seq"
        case .atascii: return "ata"
        case .viewdata: return "json"
        }
    }

    /// The documented file name for a screen called `base`: Synchronet looks for
    /// `name.80col.seq` for an 80 column (C128) PETSCII terminal before `name.seq`.
    public func suggestedName(base: String) -> String {
        self == .petscii128 ? "\(base).80col.seq" : "\(base).\(fileExtension)"
    }

    /// BBS packages with a documented display file for the platform, and the source.
    public var documentedPackages: [(name: String, how: String, source: String)] {
        switch self {
        case .petscii64, .petscii128:
            return [("Synchronet", "text/menu/<name>.seq (or <name>.40col.seq, <name>.80col.seq); menu() picks .seq for a PETSCII terminal",
                     "wiki.synchro.net howto:petscii, custom:menu_files; sbbs3 prntfile.cpp")]
        case .atascii:
            return []
        case .viewdata:
            return [("Telstar", "a frame JSON file with content type rawV, added with Telstar's API or utilities",
                     "github.com/johnnewcombe/telstar-2/wiki Frames, FrameSchema")]
        }
    }
}

/// The bytes for a platform and what the caller sees.
public struct RetroScreen {
    public let platform: RetroPlatform
    public let bytes: [UInt8]
    /// The screen the platform's terminal shows after the bytes (AnsiView's own emulation).
    public let screen: [[AnsiCell]]
    /// Cells drawn with a nearer character or colours than the design asked for.
    public let approximatedCells: Int
    /// Cells that came out other than the encoder chose (Viewdata attribute cells, the corner).
    public let lostCells: Int
    public let warnings: [PreviewWarning]
}

/// Turns an `EditCanvas` into PETSCII, ATASCII or Viewdata bytes. Each cell's CP437 glyph is
/// sampled to the platform font's size and matched against every character the platform's own
/// terminal engine draws (found by feeding it each byte), together with the colours the platform
/// can put on that cell; text characters with a direct equivalent are kept as text.
public enum RetroScreenEncoder {
    public static func encode(_ canvas: EditCanvas, for platform: RetroPlatform) -> RetroScreen {
        var encoder = Encoder(platform: platform, canvas: canvas)
        encoder.run()
        let played = play(encoder.out, on: platform)
        var lost = 0
        for (y, row) in encoder.intended.enumerated() where y < played.rows.count {
            for (x, wanted) in row.enumerated() where x < played.rows[y].count {
                if !encoder.matches(wanted, played.rows[y][x]) { lost += 1 }
            }
        }
        var warnings = encoder.warnings
        if encoder.approximated > 0 {
            warnings.append(PreviewWarning(kind: .platformApproximated, message:
                "\(encoder.approximated) \(encoder.approximated == 1 ? "cell is" : "cells are") drawn with the nearest \(platform.label) character or colours."))
        }
        if lost > 0 {
            warnings.append(PreviewWarning(kind: .platformLost, message:
                "\(lost) \(lost == 1 ? "cell does" : "cells do") not show as designed on \(platform.label)\(platform == .viewdata ? ": each colour change takes a cell" : "")."))
        }
        return RetroScreen(platform: platform, bytes: encoder.out, screen: played.rows,
                           approximatedCells: encoder.approximated, lostCells: lost, warnings: warnings)
    }

    /// `bytes` played through the platform's terminal.
    public static func play(_ bytes: [UInt8], on platform: RetroPlatform) -> AnsiScreen {
        var engine = TerminalEngines.make(platform.emulation, columns: platform.columns, rows: platform.rows,
                                          encoding: .cp437, iceColors: false)
        engine.feed(bytes)
        var screen = engine.screen(scrollOffset: 0)
        if let font = engine.font { screen.font = font }
        return screen
    }

    // MARK: Glyphs

    /// A character the platform can draw: the bytes that print it and its pixels.
    struct Candidate {
        let bytes: [UInt8]
        let mask: [UInt64]
        let glyph: UInt16
        /// Viewdata: a mosaic (graphics) character rather than text.
        let mosaic: Bool
        var isBlank: Bool { mask.allSatisfy { $0 == 0 } }
    }

    struct Glyphs {
        let width: Int
        let height: Int
        let candidates: [Candidate]
        /// The candidate index for a byte value printed directly.
        let byByte: [UInt8: Int]
        let space: Int
    }

    static func mask(_ pixels: [Bool]) -> [UInt64] {
        var words = [UInt64](repeating: 0, count: (pixels.count + 63) / 64)
        for (i, on) in pixels.enumerated() where on { words[i / 64] |= 1 << UInt64(i % 64) }
        return words
    }

    static func count(_ words: [UInt64]) -> Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [RetroPlatform: Glyphs] = [:]

    /// Every character of the platform, found by feeding each byte to a fresh terminal.
    static func glyphs(_ platform: RetroPlatform) -> Glyphs {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[platform] { return cached }
        var engineFont: BitmapFont = .vga
        var list: [Candidate] = []
        var byByte: [UInt8: Int] = [:]
        func probe(_ bytes: [UInt8], at column: Int, mosaic: Bool = false, key: UInt8? = nil) {
            var engine = TerminalEngines.make(platform.emulation, columns: platform.columns, rows: platform.rows,
                                              encoding: .cp437, iceColors: false)
            engine.feed(bytes)
            engineFont = engine.font ?? .vga
            let cell = engine.screen(scrollOffset: 0).rows[0][column]
            let glyph = cell.glyph ?? UInt16(cell.code)
            if let key { byByte[key] = list.count }
            list.append(Candidate(bytes: Array(bytes.suffix(bytes.count - (mosaic ? 2 : 0))),
                                  mask: mask(engineFont.pixels(glyph: Int(glyph))), glyph: glyph, mosaic: mosaic))
        }
        switch platform {
        case .petscii64, .petscii128:
            for b in Array(UInt8(0x20)...0x7F) + Array(UInt8(0xA0)...0xFF) { probe([b], at: 0, key: b) }
        case .atascii:
            for code in UInt8(0)...0x7F {
                probe(atasciiEscaped(code) ? [0x1B, code] : [code], at: 0, key: code)
            }
        case .viewdata:
            for b in UInt8(0x20)...0x7F { probe([b], at: 0, key: b) }
            for b in Array(UInt8(0x20)...0x3F) + Array(UInt8(0x60)...0x7F) {
                probe([0x1B, 0x57, b], at: 1, mosaic: true)
            }
        }
        let result = Glyphs(width: engineFont.width, height: engineFont.height, candidates: list, byByte: byByte,
                            space: byByte[0x20] ?? 0)
        cache[platform] = result
        return result
    }

    /// ATASCII codes that are screen editor commands and print only after ESC (also with bit 7).
    static func atasciiEscaped(_ code: UInt8) -> Bool { (0x1B...0x1F).contains(code) || (0x7D...0x7F).contains(code) }

    /// The platform byte for a CP437 text character with a direct equivalent.
    static func directText(_ code: UInt8, platform: RetroPlatform) -> UInt8? {
        switch platform {
        case .petscii64, .petscii128:
            // The lower and upper case set (what C64 terminal programs start in).
            switch code {
            case 0x61...0x7A: return code - 0x20
            case 0x41...0x5A: return code + 0x80
            case 0x20...0x40, 0x5B, 0x5D: return code
            default: return nil
            }
        case .atascii:
            switch code {
            case 0x20...0x5F, 0x61...0x7A, 0x7C: return code
            default: return nil
            }
        case .viewdata:
            // The UK teletext set: # is at 0x5F and the pound sign at 0x23.
            switch code {
            case 0x23: return 0x5F
            case 0x9C: return 0x23
            // UK teletext has arrows and fractions where ASCII has brackets: the nearest readable ones.
            case 0x5B, 0x7B: return 0x28
            case 0x5D, 0x7D: return 0x29
            case 0x5C: return 0x2F
            case 0x5F: return 0x2D
            case 0x60: return 0x27
            case 0x20...0x22, 0x24...0x5A, 0x61...0x7A: return code
            default: return nil
            }
        }
    }

    // MARK: Encoding

    struct Wanted {
        var blank: Bool
        var glyph: UInt16
        var fg: RGB
        var bg: RGB
    }

    struct Encoder {
        let platform: RetroPlatform
        let canvas: EditCanvas
        let glyphs: Glyphs
        var out: [UInt8] = []
        var intended: [[Wanted]] = []
        var warnings: [PreviewWarning] = []
        var approximated = 0
        var targetMasks: [UInt8: [UInt64]] = [:]

        init(platform: RetroPlatform, canvas: EditCanvas) {
            self.platform = platform
            self.canvas = canvas
            glyphs = RetroScreenEncoder.glyphs(platform)
        }

        func matches(_ wanted: Wanted, _ cell: AnsiCell) -> Bool {
            if wanted.blank {
                let pixels = RetroScreenEncoder.mask(fontPixels(cell))
                let lit = RetroScreenEncoder.count(pixels), total = glyphs.width * glyphs.height
                return lit == 0 && cell.bg == wanted.bg || (lit == total && cell.fg == wanted.bg)
            }
            return cell.glyph == wanted.glyph && cell.fg == wanted.fg && cell.bg == wanted.bg
        }

        private func fontPixels(_ cell: AnsiCell) -> [Bool] {
            let font: BitmapFont
            switch platform {
            case .petscii64, .petscii128: font = PlatformFonts.petscii
            case .atascii: font = PlatformFonts.atascii
            case .viewdata: font = PlatformFonts.teletext
            }
            return font.pixels(glyph: Int(cell.glyph ?? UInt16(cell.code)))
        }

        /// The CP437 glyph sampled to the platform's glyph size.
        mutating func target(_ code: UInt8) -> [UInt64] {
            if let m = targetMasks[code] { return m }
            let font = canvas.font
            let source = font.pixels(for: code)
            let w = glyphs.width, h = glyphs.height
            var pixels = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let sx = (2 * x + 1) * font.width / (2 * w), sy = (2 * y + 1) * font.height / (2 * h)
                    pixels[y * w + x] = source[sy * font.width + sx]
                }
            }
            let m = RetroScreenEncoder.mask(pixels)
            targetMasks[code] = m
            return m
        }

        /// Pixel counts of candidate `m` against target `t`: both on, candidate only, target only, both off.
        func counts(_ m: [UInt64], _ t: [UInt64]) -> (Int, Int, Int, Int) {
            var a = 0, b = 0, c = 0
            for i in m.indices {
                a += (m[i] & t[i]).nonzeroBitCount
                b += (m[i] & ~t[i]).nonzeroBitCount
                c += (~m[i] & t[i]).nonzeroBitCount
            }
            let total = glyphs.width * glyphs.height
            return (a, b, c, total - a - b - c)
        }

        static func d(_ x: RGB, _ y: RGB) -> Int { TextConvert.squaredDistance(x, y) }

        static func nearest(_ c: RGB, in palette: [RGB]) -> RGB {
            palette.min { d($0, c) < d($1, c) } ?? c
        }

        /// The candidates worth trying for a cell: its direct text equivalent, else every character.
        mutating func options(for cell: AnsiCell) -> [Int] {
            let code = cell.scalar == nil ? cell.code : 0x3F
            if let byte = RetroScreenEncoder.directText(code, platform: platform), let index = glyphs.byByte[byte] {
                return [index]
            }
            return Array(glyphs.candidates.indices)
        }

        func isBlank(_ cell: AnsiCell) -> Bool {
            cell.code == 0x20 || cell.code == 0 || cell.code == 0xFF || cell.fg == cell.bg
        }

        /// The art's area on the platform screen, with warnings when it is cut.
        mutating func area() -> (columns: Int, rows: Int) {
            let used = canvas.screen(trimmed: true).rows
            let lastColumn = used.map { row in row.lastIndex { $0 != AnsiCell() } ?? -1 }.max() ?? -1
            let columns = min(platform.columns, canvas.columns), rows = min(platform.rows, used.count)
            if lastColumn >= platform.columns || used.count > platform.rows {
                warnings.append(PreviewWarning(kind: .platformCropped, message:
                    "The art uses \(max(lastColumn + 1, 1)) columns and \(used.count) rows; a \(platform.label) screen is \(platform.columns) x \(platform.rows), so the rest is not exported."))
            }
            return (columns, rows)
        }

        mutating func run() {
            switch platform {
            case .petscii64, .petscii128: runPETSCII()
            case .atascii: runATASCII()
            case .viewdata: runViewdata()
            }
        }

        /// Best (candidate, foreground, background) from a list of colour pairs, with its error.
        mutating func best(_ cell: AnsiCell, pairs: [(on: RGB, off: RGB, tag: Int)], penalty: ((Candidate, Int) -> Int)? = nil) -> (Int, Int, Int) {
            let t = target(cell.scalar == nil ? cell.code : 0x3F)
            var bestCost = Int.max, bestError = Int.max, bestCandidate = glyphs.space, bestPair = 0
            let blank = isBlank(cell)
            let list = blank ? [glyphs.space] : options(for: cell)
            // Text keeps its character, so only its colours are weighed (as if the shapes were the
            // same); other characters are weighed pixel by pixel, which also finds reversed blocks.
            let text = !blank && list.count == 1
            let on = count(t), total = glyphs.width * glyphs.height
            for index in list {
                let (a, b, c, d) = blank ? (0, 0, 0, total) : text ? (on, 0, 0, total - on) : counts(glyphs.candidates[index].mask, t)
                for (p, pair) in pairs.enumerated() {
                    let e = a * Self.d(pair.on, cell.fg) + b * Self.d(pair.on, cell.bg) + c * Self.d(pair.off, cell.fg) + d * Self.d(pair.off, cell.bg)
                    let cost = e + (penalty?(glyphs.candidates[index], pair.tag) ?? 0)
                    if cost < bestCost { bestCost = cost; bestError = e; bestCandidate = index; bestPair = p }
                }
            }
            return (bestCandidate, bestPair, bestError)
        }

        /// The error of the ideal: the exact glyph in the nearest colours of `palette`.
        mutating func ideal(_ cell: AnsiCell, palette: [RGB]) -> Int {
            let on = count(target(cell.code)), total = glyphs.width * glyphs.height
            if isBlank(cell) { return total * Self.d(Self.nearest(cell.bg, in: palette), cell.bg) }
            return on * Self.d(Self.nearest(cell.fg, in: palette), cell.fg) + (total - on) * Self.d(Self.nearest(cell.bg, in: palette), cell.bg)
        }

        func count(_ m: [UInt64]) -> Int { RetroScreenEncoder.count(m) }

        // MARK: PETSCII

        mutating func runPETSCII() {
            let c64 = platform == .petscii64
            let palette = c64 ? PETSCIITerminal.c64Palette : PETSCIITerminal.c128Palette
            let codes = c64 ? PETSCIITerminal.c64ColourCodes : PETSCIITerminal.c128ColourCodes
            var codeFor: [Int: UInt8] = [:]
            for (code, index) in codes { codeFor[index] = code }
            let black = palette[0]
            // Normal: the colour on the screen background; reversed: the background colour on the colour.
            var pairs: [(on: RGB, off: RGB, tag: Int)] = []
            for i in 0..<16 { pairs.append((palette[i], black, i)) }
            for i in 0..<16 { pairs.append((black, palette[i], 16 + i)) }
            out = [0x93, 0x0E]
            var colour: Int? = nil, reverse = false
            let (columns, rows) = area()
            for y in 0..<rows {
                var wantedRow: [Wanted] = []
                let row = (0..<columns).map { canvas[$0, y] }
                let last = row.lastIndex { $0 != AnsiCell() } ?? -1
                for x in 0..<(last + 1) {
                    let cell = row[x]
                    if y == platform.rows - 1, x == platform.columns - 1 {
                        warnings.append(PreviewWarning(kind: .bottomRightScroll, row: y + 1, message:
                            "The bottom right cell is left out: writing it scrolls a \(platform.label) screen up one row."))
                        break
                    }
                    let (index, p, error) = best(cell, pairs: pairs)
                    if error > ideal(cell, palette: palette) { approximated += 1 }
                    let candidate = glyphs.candidates[index]
                    let rev = p >= 16, ink = p % 16
                    let blankNormal = candidate.isBlank && !rev
                    if !blankNormal, colour != ink, let code = codeFor[ink] { out.append(code); colour = ink }
                    if rev != reverse { out.append(rev ? 0x12 : 0x92); reverse = rev }
                    out += candidate.bytes
                    let on = rev ? black : palette[ink], off = rev ? palette[ink] : black
                    wantedRow.append(Wanted(blank: candidate.isBlank, glyph: candidate.glyph, fg: on, bg: off))
                }
                intended.append(wantedRow)
                if last + 1 < platform.columns, y < rows - 1 { out.append(0x0D); reverse = false }
            }
        }

        // MARK: ATASCII

        mutating func runATASCII() {
            let fg = ATASCIITerminal.foreground, bg = ATASCIITerminal.background
            let pairs: [(on: RGB, off: RGB, tag: Int)] = [(fg, bg, 0), (bg, fg, 1)]
            out = [0x7D]
            let (columns, rows) = area()
            for y in 0..<rows {
                var wantedRow: [Wanted] = []
                let row = (0..<columns).map { canvas[$0, y] }
                let last = row.lastIndex { $0 != AnsiCell() } ?? -1
                for x in 0..<(last + 1) {
                    if y == platform.rows - 1, x == platform.columns - 1 {
                        warnings.append(PreviewWarning(kind: .bottomRightScroll, row: y + 1, message:
                            "The bottom right cell is left out: writing it scrolls an Atari screen up one row."))
                        break
                    }
                    let cell = row[x]
                    let (index, p, error) = best(cell, pairs: pairs)
                    if error > ideal(cell, palette: [fg, bg]) || !isBlank(cell) && (Palette.vgaIndex(of: cell.fg).map { $0 != 7 && $0 != 15 } ?? true) {
                        approximated += 1
                    }
                    let candidate = glyphs.candidates[index]
                    var bytes = candidate.bytes
                    if p == 1 { bytes[bytes.count - 1] |= 0x80 }
                    out += bytes
                    wantedRow.append(Wanted(blank: candidate.isBlank, glyph: candidate.glyph, fg: p == 1 ? bg : fg, bg: p == 1 ? fg : bg))
                }
                intended.append(wantedRow)
                if last + 1 < platform.columns, y < rows - 1 { out.append(0x9B) }
            }
        }

        // MARK: Viewdata

        mutating func runViewdata() {
            let colours = TeletextTerminal.colours
            var pairs: [(on: RGB, off: RGB, tag: Int)] = []
            for f in 1...7 { for b in 0...7 { pairs.append((colours[f], colours[b], f * 8 + b)) } }
            out = [0x0C]
            let (columns, rows) = area()
            for y in 0..<rows {
                var memory = [UInt8](repeating: 0x20, count: platform.columns)
                var wantedRow = [Wanted](repeating: Wanted(blank: true, glyph: 0, fg: colours[7], bg: colours[0]), count: columns)
                var fg = 7, bg = 0, mosaic = false
                var blankRun = 0
                var x = 0
                while x < columns {
                    let cell = canvas[x, y]
                    let blank = isBlank(cell)
                    var choice = (index: glyphs.space, f: fg, b: bg)
                    if blank {
                        var bestB = 0
                        for b in 0...7 where Self.d(colours[b], cell.bg) < Self.d(colours[bestB], cell.bg) { bestB = b }
                        choice = (glyphs.space, fg, bestB)
                        if ideal(cell, palette: colours) < Self.d(colours[bestB], cell.bg) * glyphs.width * glyphs.height { approximated += 1 }
                    } else {
                        // Prefer the current colours on a tie, so no attribute cell is spent.
                        let current = pairs.firstIndex { $0.tag == fg * 8 + bg }
                        var ordered = pairs
                        if let current { ordered.swapAt(0, current) }
                        // Each attribute cell a choice needs costs a little, so colours change only when it is worth it.
                        let (curFg, curBg, curMosaic) = (fg, bg, mosaic)
                        let unit = glyphs.width * glyphs.height * 2_000
                        let (index, p, error) = best(cell, pairs: ordered) { candidate, tag in
                            let f = tag / 8, b = tag % 8
                            var codes = 0, newFg = curFg, newMosaic = curMosaic
                            if b != curBg { codes += b == 0 ? 1 : 2; if b != 0 { newFg = b; newMosaic = false } }
                            if f != newFg || candidate.mosaic != newMosaic { codes += 1 }
                            return codes * unit
                        }
                        if error > ideal(cell, palette: colours) { approximated += 1 }
                        choice = (index, ordered[p].tag / 8, ordered[p].tag % 8)
                    }
                    let candidate = glyphs.candidates[choice.index]
                    var codes: [UInt8] = []
                    var newFg = fg, newMosaic = mosaic
                    if choice.b != bg {
                        if choice.b == 0 { codes.append(0x1C) } else {
                            codes += [UInt8(choice.b), 0x1D]
                            newFg = choice.b
                            newMosaic = false
                        }
                    }
                    if !blank, choice.f != newFg || candidate.mosaic != newMosaic {
                        codes.append(UInt8(choice.f) + (candidate.mosaic ? 0x10 : 0))
                        newFg = choice.f
                        newMosaic = candidate.mosaic
                    }
                    if !codes.isEmpty {
                        let back = min(codes.count, blankRun)
                        let start = x - back
                        for (i, code) in codes.enumerated() where start + i < platform.columns { memory[start + i] = code }
                        fg = newFg; bg = choice.b; mosaic = newMosaic
                        blankRun = 0
                        let next = start + codes.count
                        if next > x {
                            // Cells taken by attribute codes: their design is lost (measured by playing).
                            for i in x..<min(next, columns) {
                                wantedRow[i] = isBlank(canvas[i, y])
                                    ? Wanted(blank: true, glyph: 0, fg: colours[fg], bg: colours[bg])
                                    : Wanted(blank: false, glyph: UInt16.max, fg: colours[fg], bg: colours[bg])
                            }
                            x = next
                            continue
                        }
                    }
                    if x < platform.columns { memory[x] = candidate.bytes.last ?? 0x20 }
                    wantedRow[x] = Wanted(blank: candidate.isBlank, glyph: candidate.glyph, fg: colours[choice.f], bg: colours[choice.b])
                    blankRun = blank ? blankRun + 1 : 0
                    x += 1
                }
                intended.append(wantedRow)
                var length = platform.columns
                if bg == 0 { while length > 0, memory[length - 1] == 0x20 { length -= 1 } }
                for code in memory.prefix(length) { out += code < 0x20 ? [0x1B, code + 0x40] : [code] }
                if length < platform.columns, y < rows - 1 { out += [0x0D, 0x0A] }
            }
        }
    }
}

/// A Telstar 2 frame (github.com/johnnewcombe/telstar-2/wiki/Frames): the page number and frame
/// letter, visible, and the screen as 7 bit videotex in `content.data` with type "rawV".
public enum TelstarFrame {
    public static func json(_ bytes: [UInt8], page: Int, frame: String = "a") throws -> Data {
        let object: [String: Any] = [
            "pid": ["page-no": page, "frame-id": frame],
            "visible": true,
            // Telstar draws the frame on a cleared page under its own header (inferred from the
            // wiki's header-text field): the leading clear screen is left out.
            "content": ["data": String(decoding: (bytes.first == 0x0C ? Array(bytes.dropFirst()) : bytes).map { $0 & 0x7F }, as: UTF8.self),
                        "type": "rawV"],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
