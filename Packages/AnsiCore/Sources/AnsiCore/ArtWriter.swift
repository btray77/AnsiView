import Foundation

/// File formats the editor saves.
public enum SaveFormat: String, CaseIterable {
    case ansi, bin, xbin

    public var fileExtension: String {
        switch self {
        case .ansi: return "ans"
        case .bin: return "bin"
        case .xbin: return "xb"
        }
    }

    public var label: String {
        switch self {
        case .ansi: return "ANSI (.ans)"
        case .bin: return "BinaryText (.bin)"
        case .xbin: return "XBin (.xb)"
        }
    }

    /// The format an opened file is saved in by default: binary formats keep theirs.
    public static func suggested(for format: ArtFormat) -> SaveFormat {
        switch format {
        case .bin: return .bin
        case .xbin: return .xbin
        default: return .ansi
        }
    }
}

/// Writes an `EditCanvas` as an art file that AnsiView (and other viewers) read back as the
/// same picture (plan 6 rulings 3 to 5).
public enum ArtWriter {
    public enum WriteError: Error, LocalizedError {
        case tooWideForBinaryText(columns: Int)

        public var errorDescription: String? {
            switch self {
            case .tooWideForBinaryText(let columns):
                return "BinaryText files can be at most 510 columns wide; this art is \(columns). Save it as ANSI or XBin."
            }
        }
    }

    public static func data(_ canvas: EditCanvas, format: SaveFormat, date: Date = Date()) throws -> Data {
        let body: [UInt8]
        var sauce = baseSauce(canvas, date: date)
        switch format {
        case .ansi:
            body = ansiBody(canvas)
            sauce.dataType = 1
            sauce.fileType = 1
            sauce.tInfo = [UInt16(canvas.columns), UInt16(canvas.screen(trimmed: true).rows.count)] + canvas.sauceTInfo34.prefix(2)
        case .bin:
            let width = canvas.columns + canvas.columns % 2
            guard width <= 510 else { throw WriteError.tooWideForBinaryText(columns: canvas.columns) }
            body = pairs(canvas, columns: width)
            sauce.dataType = 5
            sauce.fileType = UInt8(width / 2)
            sauce.tInfo = [0, 0, 0, 0]
        case .xbin:
            var header = Array("XBIN".utf8) + [0x1A]
            header += le16(canvas.columns) + le16(canvas.height)
            let palette = canvas.palette.flatMap { $0.count == 16 ? $0 : nil }
            header += [16, (canvas.iceColors ? 0x08 : 0x00) | (palette != nil ? 0x01 : 0x00)]
            if let palette {
                for c in palette { header += [c.r, c.g, c.b].map { UInt8((Int($0) * 63 + 127) / 255) } }
            }
            body = header + pairs(canvas, columns: canvas.columns, palette: palette)
            sauce.dataType = 6
            sauce.fileType = 0
            sauce.tInfo = [UInt16(canvas.columns), UInt16(canvas.height)] + canvas.sauceTInfo34.prefix(2)
        }
        return Data(body + sauce.encoded(fileSize: body.count))
    }

    /// The ANSI escape stream for the canvas, without SAUCE.
    public static func ansiBody(_ canvas: EditCanvas) -> [UInt8] {
        var out: [UInt8] = Array("\u{1B}[0m".utf8)
        var state = SGRState()
        let blank = AnsiCell()
        for row in canvas.screen(trimmed: true).rows {
            var cells = row
            while let last = cells.last, last == blank { cells.removeLast() }
            for cell in cells {
                let wanted = SGRState.wanted(for: cell, ice: canvas.iceColors)
                out += state.transition(to: wanted)
                out.append(TextConvert.lookalikes[cell.code] ?? cell.code)
            }
            out += [0x0D, 0x0A]
        }
        out += Array("\u{1B}[0m".utf8)
        return out
    }

    // MARK: Helpers

    private static func baseSauce(_ canvas: EditCanvas, date: Date) -> Sauce {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return Sauce(title: canvas.title, author: canvas.author, group: canvas.group,
                     date: canvas.sauceDate ?? DateComponents(year: parts.year, month: parts.month, day: parts.day),
                     dataType: 1, fileType: 1, tInfo: [0, 0, 0, 0],
                     flags: (canvas.sauceFlags & ~0x01) | (canvas.iceColors ? 0x01 : 0),
                     fontName: canvas.fontName, comments: canvas.comments)
    }

    private static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
    }

    /// Character and attribute pairs for every row, `columns` wide (extra columns blank).
    private static func pairs(_ canvas: EditCanvas, columns: Int, palette: [RGB]? = nil) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(columns * canvas.height * 2)
        for y in 0..<canvas.height {
            for x in 0..<columns {
                let cell = canvas[x, y]
                out += [cell.code, attribute(cell, ice: canvas.iceColors, palette: palette)]
            }
        }
        return out
    }

    /// VGA attribute byte; colours outside the palette become the nearest VGA colour.
    /// With a custom palette the colours are looked up in it (nearest in OKLab when not exact).
    static func attribute(_ cell: AnsiCell, ice: Bool, palette: [RGB]? = nil) -> UInt8 {
        let fg: Int, bg: Int
        if let palette {
            let labs = palette.map { OKLab.lab($0) }
            fg = palette.firstIndex(of: cell.fg) ?? OKLab.nearest(OKLab.lab(cell.fg), in: labs, allowed: 0...15)
            let exact = palette.firstIndex(of: cell.bg).flatMap { ice || $0 < 8 ? $0 : nil }
            bg = exact ?? OKLab.nearest(OKLab.lab(cell.bg), in: labs, allowed: ice ? 0...15 : 0...7)
        } else {
            fg = Palette.nearestVGA(cell.fg)
            bg = Palette.nearestVGA(cell.bg, allowed: ice ? 0...15 : 0...7)
        }
        let high = (ice && bg >= 8) || (!ice && cell.blink)
        return UInt8(fg) | UInt8(bg & 7) << 4 | (high ? 0x80 : 0)
    }
}

/// The attributes an ANSI stream has set, and the shortest SGR to reach others.
struct SGRState: Equatable {
    enum Color: Equatable { case index(Int), rgb(RGB) }

    var fg = Color.index(7)
    var bg = Color.index(0)
    var bold = false
    var blink = false

    /// What a cell needs. Bold and blink stay as they are when they would not matter
    /// (a truecolor foreground ignores bold; with iCE a truecolor background ignores blink).
    struct Wanted {
        var fg: Color
        var bg: Color
        var bold: Bool?
        var blink: Bool?
    }

    static func wanted(for cell: AnsiCell, ice: Bool) -> Wanted {
        var wanted = Wanted(fg: .rgb(cell.fg), bg: .rgb(cell.bg), bold: nil, blink: nil)
        if let index = Palette.vgaIndex(of: cell.fg) {
            wanted.fg = .index(vgaToAnsi[index % 8])
            wanted.bold = index >= 8
        }
        if let index = Palette.vgaIndex(of: cell.bg), index < 8 || ice {
            wanted.bg = .index(vgaToAnsi[index % 8])
            if ice { wanted.blink = index >= 8 }
        }
        if !ice { wanted.blink = cell.blink }
        return wanted
    }

    /// VGA attribute order to ANSI colour order.
    static let vgaToAnsi: [Int] = (0..<8).map { Palette.ansiToVGA.firstIndex(of: $0)! }

    mutating func transition(to wanted: Wanted) -> [UInt8] {
        let bold = wanted.bold ?? self.bold
        let blink = wanted.blink ?? self.blink
        if wanted.fg == fg, wanted.bg == bg, bold == self.bold, blink == self.blink { return [] }
        var codes: [String] = []
        if (self.bold && !bold) || (self.blink && !blink) {
            codes.append("0")
            self = SGRState()
        }
        if bold && !self.bold { codes.append("1") }
        if blink && !self.blink { codes.append("5") }
        if wanted.fg != fg { codes.append(Self.code(wanted.fg, base: 30, extended: 38)) }
        if wanted.bg != bg { codes.append(Self.code(wanted.bg, base: 40, extended: 48)) }
        fg = wanted.fg
        bg = wanted.bg
        self.bold = bold
        self.blink = blink
        return Array("\u{1B}[\(codes.joined(separator: ";"))m".utf8)
    }

    private static func code(_ color: Color, base: Int, extended: Int) -> String {
        switch color {
        case .index(let i): return "\(base + i)"
        case .rgb(let c): return "\(extended);2;\(c.r);\(c.g);\(c.b)"
        }
    }
}
