import Foundation

/// A text art font of either kind (TheDraw or FIGlet).
public enum TextArtFont: Equatable {
    case tdf(TDFFont)
    case figlet(FIGletFont)

    public var name: String {
        switch self {
        case .tdf(let font): return font.name
        case .figlet(let font): return font.name
        }
    }

    public var category: TextArtCategory {
        switch self {
        case .tdf(let font):
            switch font.type {
            case .outline: return .tdfOutline
            case .block: return .tdfBlock
            case .color: return .tdfColor
            }
        case .figlet: return .figlet
        }
    }

    /// Fonts that draw in the chosen colours (everything except TDF colour fonts).
    public var isMonochrome: Bool { category != .tdfColor }
}

public enum TextArtCategory: String, CaseIterable, Codable {
    case figlet, tdfOutline, tdfBlock, tdfColor

    public var label: String {
        switch self {
        case .figlet: return "FIGlet"
        case .tdfOutline: return "TDF outline"
        case .tdfBlock: return "TDF block"
        case .tdfColor: return "TDF colour"
        }
    }
}

public enum TextArtAlignment: String, CaseIterable, Codable {
    case left, center, right
}

/// Colours across the art for monochrome fonts (an extra of ruling 20).
public struct TextArtGradient: Equatable, Codable {
    public enum Direction: String, Codable, CaseIterable { case columns, rows }
    /// VGA colour indexes, spread evenly from the first column (or row) to the last.
    public var colors: [Int]
    public var direction: Direction

    public init(colors: [Int], direction: Direction) {
        self.colors = colors
        self.direction = direction
    }
}

public struct TextArtOptions: Equatable {
    /// TheDraw outline style, 0 to 18.
    public var outlineStyle = 0
    /// VGA colour indexes used by monochrome fonts and for gaps.
    public var foreground = 7
    public var background = 0
    /// Letter spacing for TDF fonts; nil uses the font's own.
    public var spacing: Int?
    /// Wrap words to this many columns; nil does not wrap.
    public var wrapWidth: Int?
    /// Colour fonts: blink becomes a bright background.
    public var iceColors = false
    public var horizontalLayout = FIGletLayout.fontDefault
    public var verticalLayout = FIGletLayout.fontDefault
    public var alignment = TextArtAlignment.left
    public var gradient: TextArtGradient?

    public init() {}
}

public struct TextArtResult: Equatable {
    public var region: CanvasRegion
    /// Characters the font does not have (after the case fallback), in order of appearance.
    public var missing: [Character]
}

public enum TextArt {
    public static let maxTextLength = 4000

    /// TheDraw's 19 outline styles as CP437 codes, 17 per style for the letters A to Q
    /// (converted from retrofont's table, "copied from TheDraw"; plan ruling 7).
    public static let outlineStyles: [[UInt8]] = [
        "──││┌┐┌┐└┘└┘┤├   ", "═─││╒╕┌┐╘╛└┘╡├   ", "─═││┌┐╒╕└┘╘╛┤╞   ", "══││╒╕╒╕╘╛╘╛╡╞   ",
        "──║│╓┐┌╖└╜╙┘╢├   ", "═─║│╔╕┌╖╘╝╙┘╣├   ", "─═║│╓┐╒╗└╜╚╛╢╞   ", "══║│╔╕╒╗╘╝╚╛╣╞   ",
        "──│║┌╖╓┐╙┘└╜┤╟   ", "═─│║╒╗╓┐╚╛└╜╡╟   ", "─═│║┌╖╔╕╙┘╘╝┤╠   ", "══│║╒╗╔╕╚╛╘╝╡╠   ",
        "──║║╓╖╓╖╙╜╙╜╢╟   ", "═─║║╔╗╓╖╚╝╙╜╣╟   ", "─═║║╓╖╔╗╙╜╚╝╢╠   ", "══║║╔╗╔╗╚╝╚╝╣╠   ",
        "▄▄██▄▄▄▄██████   ", "▀▀██████▀▀▀▀██   ", "▀▄▐▌▐▌▄▄▀▀▐▌██   ",
    ].map { style in style.unicodeScalars.map { CP437.code(for: $0) ?? 0x20 } }

    /// The characters of an outline style, for menus ("─│┌┐└┘").
    public static func outlineSample(_ style: Int) -> String {
        let codes = outlineStyles[min(18, max(0, style))]
        return String(String.UnicodeScalarView([0, 2, 4, 5, 8, 9].map { CP437.unicode[Int(codes[$0])] }))
    }

    /// Renders `text` (lines separated by line breaks) with `font` (rulings 7 to 11, 13 and 20).
    public static func render(_ text: String, font: TextArtFont, options: TextArtOptions) -> TextArtResult {
        let source = String(text.prefix(maxTextLength)).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var missing: [Character] = []
        func note(_ list: [Character]) {
            for ch in list where !missing.contains(ch) { missing.append(ch) }
        }
        let paragraphs = source.isEmpty ? [] : source.components(separatedBy: "\n")
        var cells: [[AnsiCell?]]
        switch font {
        case .tdf(let tdf):
            let lines = paragraphs.flatMap { wrap($0, width: options.wrapWidth) { tdfLine($0, tdf, options).figure.first?.count ?? 0 } }
            var figures = lines.map { line -> [[AnsiCell?]] in
                let (figure, lost) = tdfLine(line, tdf, options)
                note(lost)
                return figure
            }
            figures = align(figures, options.alignment, blank: nil)
            cells = []
            for (index, figure) in figures.enumerated() {
                if index > 0 { cells.append(Array(repeating: nil, count: figure.first?.count ?? 0)) }
                cells += figure
            }
        case .figlet(let fig):
            let horizontal = options.horizontalLayout.mode(fontMode: fig.horizontalMode, fontRules: fig.horizontalRules)
            let vertical = options.verticalLayout.mode(fontMode: fig.verticalMode, fontRules: fig.verticalRules)
            let lines = paragraphs.flatMap { wrap($0, width: options.wrapWidth) { fig.renderLine($0, mode: horizontal).rows.first?.count ?? 0 } }
            var figures = lines.map { line -> [[Unicode.Scalar]] in
                let (rows, lost) = fig.renderLine(line, mode: horizontal)
                note(lost)
                return rows
            }
            figures = align(figures, options.alignment, blank: " ")
            var stacked: [[Unicode.Scalar]] = []
            for figure in figures { stacked = FIGletFont.stack(stacked, figure, mode: vertical) }
            let fg = Palette.vga[clampColor(options.foreground)], bg = Palette.vga[clampColor(options.background)]
            cells = stacked.map { row in
                row.map { scalar -> AnsiCell? in
                    if scalar == " " { return nil }
                    if scalar == fig.hardblank { return AnsiCell(code: 0x20, fg: fg, bg: bg) }
                    return AnsiCell(code: CP437.code(for: scalar) ?? 0x3F, fg: fg, bg: bg)
                }
            }
        }
        // Gradient (monochrome fonts), then gaps become spaces in the current colours, clipped.
        let height = min(cells.count, AnsiTerminal.maxRows)
        let width = min(cells.map(\.count).max() ?? 0, EditCanvas.maxColumns)
        if let gradient = options.gradient, font.isMonochrome, !gradient.colors.isEmpty, width > 0 {
            for y in 0..<height {
                for x in 0..<min(width, cells[y].count) where cells[y][x] != nil {
                    let position = gradient.direction == .columns ? x * gradient.colors.count / width
                        : y * gradient.colors.count / height
                    cells[y][x]?.fg = Palette.vga[clampColor(gradient.colors[min(gradient.colors.count - 1, position)])]
                }
            }
        }
        let gap = AnsiCell(code: 0x20, fg: Palette.vga[clampColor(options.foreground)], bg: Palette.vga[clampColor(options.background)])
        let rows = (0..<height).map { y in
            (0..<width).map { x in x < cells[y].count ? (cells[y][x] ?? gap) : gap }
        }
        return TextArtResult(region: CanvasRegion(cells: rows), missing: missing)
    }

    static func clampColor(_ index: Int) -> Int { min(15, max(0, index)) }

    // MARK: TDF lines

    static func tdfGlyph(_ font: TDFFont, _ ch: Character) -> TDFGlyph? {
        guard let ascii = ch.asciiValue else { return nil }
        if let glyph = font.glyphs[ascii] { return glyph }
        for other in [ch.uppercased(), ch.lowercased()] {
            if let code = other.first?.asciiValue, other.count == 1, let glyph = font.glyphs[code] { return glyph }
        }
        return nil
    }

    static func spaceWidth(_ font: TDFFont) -> Int {
        let widths = font.glyphs.values.map(\.columns)
        guard !widths.isEmpty else { return 1 }
        let average = Double(widths.reduce(0, +)) / Double(widths.count)
        return max(1, Int((average / 2).rounded(.up)))
    }

    static func tdfLine(_ text: String, _ font: TDFFont, _ options: TextArtOptions) -> (figure: [[AnsiCell?]], missing: [Character]) {
        let spacing = max(0, options.spacing ?? font.spacing)
        let space = spaceWidth(font)
        let fg = Palette.vga[clampColor(options.foreground)], bg = Palette.vga[clampColor(options.background)]
        let style = outlineStyles[min(18, max(0, options.outlineStyle))]
        var placed: [(x: Int, glyph: TDFGlyph)] = []
        var missing: [Character] = []
        var x = 0
        for (index, ch) in text.enumerated() {
            if index > 0 { x += spacing }
            if x > EditCanvas.maxColumns { break }
            if ch == " " { x += space; continue }
            guard let glyph = tdfGlyph(font, ch) else {
                missing.append(ch)
                x += space
                continue
            }
            placed.append((x, glyph))
            x += glyph.columns
        }
        let height = placed.map(\.glyph.rows.count).max() ?? (text.isEmpty ? 0 : 1)
        var figure = Array(repeating: [AnsiCell?](repeating: nil, count: x), count: height)
        for (left, glyph) in placed {
            for (y, row) in glyph.rows.enumerated() {
                for (dx, cell) in row.cells.enumerated() where left + dx < x {
                    figure[y][left + dx] = tdfCell(cell, font.type, style: style, fg: fg, bg: bg, ice: options.iceColors)
                }
            }
        }
        return (figure, missing)
    }

    static func tdfCell(_ cell: TDFCell, _ type: TDFFontType, style: [UInt8], fg: RGB, bg: RGB, ice: Bool) -> AnsiCell? {
        switch type {
        case .outline:
            switch cell.code {
            case UInt8(ascii: "@"): return nil
            case UInt8(ascii: "O"): return AnsiCell(code: 0x20, fg: fg, bg: bg)
            case UInt8(ascii: "A")...UInt8(ascii: "Q"): return AnsiCell(code: style[Int(cell.code) - 65], fg: fg, bg: bg)
            case UInt8(ascii: "R"): return AnsiCell(code: 0x20, fg: fg, bg: bg)
            default: return AnsiCell(code: cell.code, fg: fg, bg: bg)
            }
        case .block:
            return AnsiCell(code: cell.code == 0xFF ? 0x20 : cell.code, fg: fg, bg: bg)
        case .color:
            let a = cell.attribute
            let colored = AnsiCell(code: cell.code == 0xFF ? 0x20 : cell.code, fg: Palette.vga[Int(a & 15)],
                                   bg: Palette.vga[Int((a >> 4) & 7)], blink: a & 0x80 != 0)
            return ice ? EditCanvas.cell(colored, iceColors: true) : colored
        }
    }

    // MARK: Layout helpers

    /// Splits `text` into lines no wider than `width` (as measured), moving whole words and
    /// cutting words that do not fit on a line of their own (ruling 11).
    static func wrap(_ text: String, width: Int?, measure: (String) -> Int) -> [String] {
        guard let width, width > 0, measure(text) > width else { return [text] }
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if measure(candidate) <= width { current = candidate; continue }
            if !current.isEmpty { lines.append(current) }
            current = ""
            if measure(word) <= width { current = word; continue }
            // Cut a long word between letters.
            var piece = ""
            for ch in word {
                if !piece.isEmpty, measure(piece + String(ch)) > width {
                    lines.append(piece)
                    piece = ""
                }
                piece.append(ch)
            }
            current = piece
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    /// Pads figures to one width with the alignment.
    static func align<T>(_ figures: [[[T]]], _ alignment: TextArtAlignment, blank: T) -> [[[T]]] {
        let width = figures.map { $0.map(\.count).max() ?? 0 }.max() ?? 0
        return figures.map { figure in
            let own = figure.map(\.count).max() ?? 0
            let extra = width - own
            let left = alignment == .left ? 0 : alignment == .right ? extra : extra / 2
            return figure.map { row in
                Array(repeating: blank, count: left) + row + Array(repeating: blank, count: width - left - row.count)
            }
        }
    }
}
