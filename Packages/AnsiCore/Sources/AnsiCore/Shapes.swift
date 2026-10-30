import Foundation

/// How a shape's edges are drawn (editor tools plan, ruling 4).
public enum ShapeStyle: Equatable {
    /// Box drawing lines that join with other lines.
    case line(LineStyle)
    /// Full blocks.
    case solid
    /// Half blocks: ▀ along the top, ▄ along the bottom, ▌ and ▐ at the sides, █ corners.
    case halfBlock
    /// Shade 1 to 3: ░ ▒ ▓.
    case shade(Int)
    /// Any character (the brush character).
    case character(UInt8)

    /// The character a block style draws with (nil for box lines).
    public var blockCode: UInt8? {
        switch self {
        case .line: return nil
        case .solid, .halfBlock: return EditCanvas.blockFull
        case .shade(let level): return UInt8(175 + min(3, max(1, level)))
        case .character(let code): return code
        }
    }
}

extension EditCanvas {
    /// The perimeter of a rectangle as a closed path, clockwise from the top left.
    static func perimeter(_ rect: CellRect) -> [(Int, Int)] {
        let x0 = rect.x, y0 = rect.y, x1 = rect.x + rect.width - 1, y1 = rect.y + rect.height - 1
        if rect.width == 1 || rect.height == 1 { return BoxDrawing.manhattanPath(from: (x0, y0), to: (x1, y1)) }
        var path: [(Int, Int)] = []
        for x in x0...x1 { path.append((x, y0)) }
        for y in (y0 + 1)...y1 { path.append((x1, y)) }
        for x in stride(from: x1 - 1, through: x0, by: -1) { path.append((x, y1)) }
        for y in stride(from: y1 - 1, through: y0, by: -1) { path.append((x0, y)) }
        return path
    }

    /// Draws a rectangle (ruling 4): the outline in `style`, optionally filled with `fillCode`
    /// (block styles fill with their own character), a drop shadow and a title in the top edge.
    public mutating func drawRectangle(_ rect: CellRect, style: ShapeStyle, fg: RGB, bg: RGB, filled: Bool = false,
                                       fillCode: UInt8 = 0x20, shadow: Bool = false, title: String = "") {
        guard rect.width > 0, rect.height > 0 else { return }
        let x0 = rect.x, y0 = rect.y, x1 = rect.x + rect.width - 1, y1 = rect.y + rect.height - 1
        if filled {
            let code = style.blockCode ?? fillCode
            let inner = style.blockCode == nil
                ? CellRect(x: x0 + 1, y: y0 + 1, width: rect.width - 2, height: rect.height - 2) : rect
            if inner.width > 0, inner.height > 0 {
                for y in inner.y..<inner.y + inner.height {
                    for x in inner.x..<inner.x + inner.width { set(AnsiCell(code: code, fg: fg, bg: bg), x: x, y: y) }
                }
            }
        }
        switch style {
        case .line(let lineStyle):
            drawLine(path: Self.perimeter(rect), style: lineStyle, fg: fg, bg: bg)
        case .halfBlock:
            for (x, y) in Self.perimeter(rect) {
                let corner = (x == x0 || x == x1) && (y == y0 || y == y1)
                var code = Self.blockFull
                if !corner && rect.width > 1 && rect.height > 1 {
                    if y == y0 { code = Self.blockUpper } else if y == y1 { code = Self.blockLower }
                    else if x == x0 { code = 221 } else { code = 222 }
                }
                set(AnsiCell(code: code, fg: fg, bg: bg), x: x, y: y)
            }
        default:
            let code = style.blockCode ?? Self.blockFull
            for (x, y) in Self.perimeter(rect) { set(AnsiCell(code: code, fg: fg, bg: bg), x: x, y: y) }
        }
        if !title.isEmpty, rect.width >= 5 {
            let text = Array((" " + title + " ").unicodeScalars.prefix(rect.width - 4))
            for (index, scalar) in text.enumerated() {
                set(AnsiCell(code: CP437.code(for: scalar) ?? 0x3F, fg: fg, bg: bg), x: x0 + 2 + index, y: y0)
            }
        }
        if shadow { dropShadow(rect) }
    }

    /// TheDraw style drop shadow: two columns right of the box from its second row, and the row
    /// below it from its third column, keep their characters in dark grey on black.
    public mutating func dropShadow(_ rect: CellRect) {
        let x1 = rect.x + rect.width, y1 = rect.y + rect.height
        var cells: [(Int, Int)] = []
        for y in (rect.y + 1)...y1 { cells += [(x1, y), (x1 + 1, y)] }
        if rect.x + 2 < x1 { for x in (rect.x + 2)..<x1 { cells.append((x, y1)) } }
        for (x, y) in cells where x >= 0 && x < columns && y >= 0 && y < AnsiTerminal.maxRows {
            var cell = self[x, y]
            cell.fg = Palette.vga[8]
            cell.bg = Palette.vga[0]
            cell.blink = false
            set(cell, x: x, y: y)
        }
    }

    /// A straight line: box styles snap to horizontal or vertical (the longer axis) and join;
    /// half blocks draw in half block pixels; other block styles step over cells (Bresenham).
    public mutating func drawStraightLine(from a: (Int, Int), to b: (Int, Int), style: ShapeStyle, fg: RGB, bg: RGB) {
        switch style {
        case .line(let lineStyle):
            let end = abs(b.0 - a.0) >= abs(b.1 - a.1) ? (b.0, a.1) : (a.0, b.1)
            drawLine(path: BoxDrawing.manhattanPath(from: a, to: end), style: lineStyle, fg: fg, bg: bg)
        case .halfBlock:
            for (x, y) in Self.bresenham(from: (a.0, a.1 * 2), to: (b.0, b.1 * 2)) {
                paintHalf(x: x, y: y / 2, half: y % 2 == 0 ? .top : .bottom, color: fg)
            }
        default:
            let code = style.blockCode ?? Self.blockFull
            for (x, y) in Self.bresenham(from: a, to: b) { set(AnsiCell(code: code, fg: fg, bg: bg), x: x, y: y) }
        }
    }

    /// An ellipse outline inside `rect` in half block pixels (two per cell, one above the other).
    public mutating func drawEllipse(in rect: CellRect, color: RGB) {
        guard rect.width > 0, rect.height > 0 else { return }
        // Pixel space: columns as they are, rows doubled.
        let cx = Double(rect.x) + Double(rect.width - 1) / 2
        let cy = Double(rect.y * 2) + Double(rect.height * 2 - 1) / 2
        let rx = Double(rect.width - 1) / 2, ry = Double(rect.height * 2 - 1) / 2
        var pixels = Set<[Int]>()
        func plot(_ x: Double, _ y: Double) { pixels.insert([Int(x.rounded(.toNearestOrEven)), Int(y.rounded())]) }
        if rx == 0 || ry == 0 {
            for x in rect.x..<rect.x + rect.width { for y in rect.y * 2..<(rect.y + rect.height) * 2 { pixels.insert([x, y]) } }
        } else {
            // Sample along both axes so steep and shallow parts stay connected; each point is
            // mirrored into the four quadrants so the outline is symmetric.
            let quadrants: [(Double, Double)] = [(1, 1), (-1, 1), (1, -1), (-1, -1)]
            for i in 0...Int(rx * 2) {
                let dx = Double(i) / 2
                let dy = ry * (1 - min(1, (dx * dx) / (rx * rx))).squareRoot()
                for (sx, sy) in quadrants { plot(cx + sx * dx, cy + sy * dy) }
            }
            for i in 0...Int(ry * 2) {
                let dy = Double(i) / 2
                let dx = rx * (1 - min(1, (dy * dy) / (ry * ry))).squareRoot()
                for (sx, sy) in quadrants { plot(cx + sx * dx, cy + sy * dy) }
            }
        }
        for pixel in pixels where pixel[0] >= 0 && pixel[0] < columns && pixel[1] >= 0 && pixel[1] < AnsiTerminal.maxRows * 2 {
            paintHalf(x: pixel[0], y: pixel[1] / 2, half: pixel[1] % 2 == 0 ? .top : .bottom, color: color)
        }
    }

    /// Cells on the line from `a` to `b` (both included).
    public static func bresenham(from a: (Int, Int), to b: (Int, Int)) -> [(Int, Int)] {
        var (x, y) = a
        let dx = abs(b.0 - a.0), dy = -abs(b.1 - a.1)
        let sx = a.0 < b.0 ? 1 : -1, sy = a.1 < b.1 ? 1 : -1
        var error = dx + dy
        var cells: [(Int, Int)] = []
        while true {
            cells.append((x, y))
            if x == b.0 && y == b.1 { break }
            let e2 = 2 * error
            if e2 >= dy { error += dy; x += sx }
            if e2 <= dx { error += dx; y += sy }
        }
        return cells
    }
}
