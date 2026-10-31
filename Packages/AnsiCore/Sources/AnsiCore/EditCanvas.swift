import Foundation

/// A rectangle of cells, in column and row units.
public struct CellRect: Equatable {
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

    /// The rectangle with `a` and `b` as opposite corners (both included).
    public static func spanning(_ a: (Int, Int), _ b: (Int, Int)) -> CellRect {
        CellRect(x: min(a.0, b.0), y: min(a.1, b.1), width: abs(a.0 - b.0) + 1, height: abs(a.1 - b.1) + 1)
    }

    public func contains(x: Int, y: Int) -> Bool {
        x >= self.x && x < self.x + width && y >= self.y && y < self.y + height
    }
}

/// A copied block of cells.
public struct CanvasRegion: Equatable {
    public let width: Int
    public let height: Int
    public let cells: [[AnsiCell]]

    public init(cells: [[AnsiCell]]) {
        self.cells = cells
        height = cells.count
        width = cells.map(\.count).max() ?? 0
    }
}

/// The upper or lower half of a character cell, for half block drawing.
public enum HalfBlock { case top, bottom }

extension Palette {
    /// The VGA attribute index of `color`, when it is one of the 16 VGA colours.
    public static func vgaIndex(of color: RGB) -> Int? {
        vga.firstIndex(of: color)
    }

    /// The VGA index in `allowed` nearest to `color` (squared RGB distance).
    public static func nearestVGA(_ color: RGB, allowed: ClosedRange<Int> = 0...15) -> Int {
        if let exact = vgaIndex(of: color), allowed.contains(exact) { return exact }
        var best = allowed.lowerBound, bestDistance = Int.max
        for index in allowed {
            let distance = TextConvert.squaredDistance(vga[index], color)
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        return best
    }
}

/// The art being edited: a grid of cells plus the SAUCE facts that are saved with it.
/// A value type, so an undo step is a copy (unchanged rows share their storage).
public struct EditCanvas: Equatable {
    public static let maxColumns = 1000
    public static let blockFull: UInt8 = 219
    public static let blockUpper: UInt8 = 223
    public static let blockLower: UInt8 = 220

    public internal(set) var columns: Int
    public internal(set) var rows: [[AnsiCell]]
    /// The blink bit selects bright backgrounds instead of blinking.
    public private(set) var iceColors = false
    public var title = ""
    public var author = ""
    public var group = ""
    public var comments: [String] = []
    /// SAUCE font name; the canvas is drawn with this font.
    public var fontName = "IBM VGA"
    /// SAUCE flags other than iCE (letter spacing, aspect ratio) kept from an opened file.
    public var sauceFlags: UInt8 = 0
    /// A 16 colour palette other than VGA (an image import's fitted palette). XBin saves it;
    /// ANSI writes those colours as truecolor.
    public var palette: [RGB]?
    /// SAUCE TInfo3 and TInfo4 of an opened file, written back by ANSI and XBin saves.
    public var sauceTInfo34: [UInt16] = [0, 0]
    /// The SAUCE creation date of an opened file, kept on save (new art is dated when saved).
    public var sauceDate: DateComponents?

    /// The font an XBin, ADF or IDF file brought with it (final gaps ruling 7): drawn instead of
    /// `fontName`'s font and written back by XBin, ADF and IDF saves.
    public var embeddedFont: BitmapFont?

    public var height: Int { rows.count }
    public var font: BitmapFont { embeddedFont ?? BitmapFont.named(fontName) }

    public init(columns: Int = 80, height: Int = 25) {
        self.columns = Self.clampColumns(columns)
        rows = Array(repeating: Array(repeating: AnsiCell(), count: self.columns),
                     count: Self.clampHeight(height))
    }

    /// A canvas holding `screen`. iCE is on when asked, or when a cell has a bright VGA background.
    public init(screen: AnsiScreen, iceColors: Bool) {
        columns = Self.clampColumns(screen.columns)
        let width = columns
        rows = screen.rows.prefix(AnsiTerminal.maxRows).map { row in
            var cells = Array(row.prefix(width))
            if cells.count < width { cells += Array(repeating: AnsiCell(), count: width - cells.count) }
            return cells
        }
        if rows.isEmpty { rows = [Array(repeating: AnsiCell(), count: width)] }
        self.iceColors = iceColors || rows.contains { $0.contains { Self.isBrightVGA($0.bg) } }
        if let palette = screen.palette, palette.count == 16 { self.palette = palette }
        if screen.font.name == BitmapFont.embeddedName { embeddedFont = screen.font }
        if let sauce = screen.sauce {
            title = sauce.title
            author = sauce.author
            group = sauce.group
            comments = sauce.comments
            if !sauce.fontName.isEmpty { fontName = sauce.fontName }
            sauceFlags = sauce.flags & ~0x01
            sauceTInfo34 = [sauce.tInfo.count > 2 ? sauce.tInfo[2] : 0, sauce.tInfo.count > 3 ? sauce.tInfo[3] : 0]
            sauceDate = sauce.date
        } else if let screenTitle = screen.title {
            title = screenTitle
        }
    }

    /// The finished screen of an opened file (the final frame of an animation).
    public init(file: ArtFile) {
        self.init(screen: AnsiAnalysis(file).finalScreen, iceColors: file.iceColors)
    }

    public subscript(x: Int, y: Int) -> AnsiCell {
        guard y >= 0, y < rows.count, x >= 0, x < columns else { return AnsiCell() }
        return rows[y][x]
    }

    /// Writes one cell, adding rows when `y` is below the last one. Positions outside the
    /// width, above the top or past the row limit are ignored.
    public mutating func set(_ cell: AnsiCell, x: Int, y: Int) {
        guard x >= 0, x < columns, y >= 0, y < AnsiTerminal.maxRows else { return }
        ensureHeight(y + 1)
        rows[y][x] = cell
    }

    /// Adds blank rows until there are `count` (at most `AnsiTerminal.maxRows`).
    public mutating func ensureHeight(_ count: Int) {
        let target = min(AnsiTerminal.maxRows, count)
        while rows.count < target { rows.append(Array(repeating: AnsiCell(), count: columns)) }
    }

    public mutating func resize(columns newColumns: Int, height newHeight: Int) {
        let width = Self.clampColumns(newColumns)
        let rowCount = Self.clampHeight(newHeight)
        if rows.count > rowCount { rows.removeSubrange(rowCount...) }
        for index in rows.indices {
            if rows[index].count > width {
                rows[index].removeSubrange(width...)
            } else if rows[index].count < width {
                rows[index] += Array(repeating: AnsiCell(), count: width - rows[index].count)
            }
        }
        columns = width
        ensureHeight(rowCount)
    }

    /// A copy of the cells inside `rect`, clipped to the canvas.
    public func region(_ rect: CellRect) -> CanvasRegion {
        guard let clipped = clip(rect) else { return CanvasRegion(cells: []) }
        return CanvasRegion(cells: (clipped.y..<clipped.y + clipped.height).map { y in
            Array(rows[y][clipped.x..<clipped.x + clipped.width])
        })
    }

    /// Characters a transparent paste does not write: the blanks (space, NUL, 255).
    public static let transparentCodes: Set<UInt8> = [0x00, 0x20, 0xFF]

    /// Places `region` with its top left at (`x`, `y`); what falls outside the width is dropped.
    /// Transparent leaves the cell underneath wherever the pasted character is a blank.
    public mutating func paste(_ region: CanvasRegion, x: Int, y: Int, transparent: Bool = false) {
        for (dy, line) in region.cells.enumerated() {
            for (dx, cell) in line.enumerated() {
                if transparent, Self.transparentCodes.contains(cell.code), cell.scalar == nil { continue }
                set(cell, x: x + dx, y: y + dy)
            }
        }
    }

    /// Replaces every cell in `rect` (clipped) with `transform` of it.
    public mutating func fill(_ rect: CellRect, transform: (AnsiCell) -> AnsiCell) {
        guard let clipped = clip(rect) else { return }
        for y in clipped.y..<clipped.y + clipped.height {
            for x in clipped.x..<clipped.x + clipped.width { rows[y][x] = transform(rows[y][x]) }
        }
    }

    /// The part of `rect` inside the canvas, or nil when none is.
    public func clip(_ rect: CellRect) -> CellRect? {
        let x0 = max(0, rect.x), y0 = max(0, rect.y)
        let x1 = min(columns, rect.x + rect.width), y1 = min(rows.count, rect.y + rect.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return CellRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Whether `color` can be a background: anything with iCE, otherwise not a bright VGA colour.
    public func canBeBackground(_ color: RGB) -> Bool {
        iceColors || !Self.isBrightVGA(color)
    }

    /// Paints `color` into one half of a cell, as half block drawing does (plan 6 ruling 8).
    public mutating func paintHalf(x: Int, y: Int, half: HalfBlock, color: RGB) {
        guard x >= 0, x < columns, y >= 0, y < AnsiTerminal.maxRows else { return }
        var (top, bottom) = Self.halves(self[x, y])
        // Already that colour: leave the cell (and its character) alone.
        if (half == .top ? top : bottom) == color { return }
        if half == .top { top = color } else { bottom = color }
        set(encodeHalves(top: top, bottom: bottom, keepingBackground: self[x, y].bg), x: x, y: y)
    }

    /// The colours of a cell's upper and lower halves when seen as half block pixels.
    static func halves(_ cell: AnsiCell) -> (RGB, RGB) {
        switch cell.code {
        case blockUpper: return (cell.fg, cell.bg)
        case blockLower: return (cell.bg, cell.fg)
        case blockFull: return (cell.fg, cell.fg)
        default: return (cell.bg, cell.bg)
        }
    }

    /// A cell showing `top` over `bottom` with half blocks, keeping both exact when the
    /// background rules allow, else darkening the lower half.
    func encodeHalves(top: RGB, bottom: RGB, keepingBackground background: RGB) -> AnsiCell {
        if top == bottom {
            return AnsiCell(code: Self.blockFull, fg: top, bg: background)
        }
        if canBeBackground(bottom) { return AnsiCell(code: Self.blockUpper, fg: top, bg: bottom) }
        if canBeBackground(top) { return AnsiCell(code: Self.blockLower, fg: bottom, bg: top) }
        return AnsiCell(code: Self.blockUpper, fg: top, bg: Self.darkened(bottom))
    }

    /// Turns iCE colours on or off, converting cells the way their bytes would read.
    public mutating func setIceColors(_ on: Bool) {
        guard on != iceColors else { return }
        iceColors = on
        for y in rows.indices {
            for x in rows[y].indices { rows[y][x] = Self.cell(rows[y][x], iceColors: on) }
        }
    }

    /// A cell as a canvas with or without iCE colours holds it: with iCE, blink on a dark VGA
    /// background becomes the bright background; without, a bright VGA background becomes the
    /// dark one plus blink.
    public static func cell(_ cell: AnsiCell, iceColors on: Bool) -> AnsiCell {
        var cell = cell
        if on {
            if cell.blink, let index = Palette.vgaIndex(of: cell.bg), index < 8 {
                cell.bg = Palette.vga[index + 8]
            }
            cell.blink = false
        } else if isBrightVGA(cell.bg) {
            cell.bg = darkened(cell.bg)
            cell.blink = true
        }
        return cell
    }

    /// The canvas as a screen for rendering and saving. Trimmed drops trailing blank rows,
    /// as an ANSI file does.
    public func screen(trimmed: Bool) -> AnsiScreen {
        var result = rows
        if trimmed {
            while let last = result.last, last.allSatisfy({ $0 == AnsiCell() }) { result.removeLast() }
        }
        var screen = AnsiScreen(columns: columns, rows: result, title: title.isEmpty ? nil : title)
        screen.font = font
        screen.sauce = Sauce(title: title, author: author, group: group, date: nil, dataType: 1, fileType: 1,
                             tInfo: [UInt16(columns), UInt16(min(rows.count, 65535)), 0, 0],
                             flags: (sauceFlags & ~0x01) | (iceColors ? 0x01 : 0),
                             fontName: fontName, comments: comments)
        return screen
    }

    // MARK: Helpers

    static func isBrightVGA(_ color: RGB) -> Bool {
        (Palette.vgaIndex(of: color) ?? 0) >= 8
    }

    /// A bright VGA colour's dark half; other colours unchanged.
    static func darkened(_ color: RGB) -> RGB {
        guard let index = Palette.vgaIndex(of: color), index >= 8 else { return color }
        return Palette.vga[index - 8]
    }

    private static func clampColumns(_ value: Int) -> Int { min(maxColumns, max(1, value)) }
    private static func clampHeight(_ value: Int) -> Int { min(AnsiTerminal.maxRows, max(1, value)) }
}
