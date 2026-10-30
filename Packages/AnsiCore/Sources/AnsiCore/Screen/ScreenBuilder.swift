import Foundation

/// Drawing helpers the templates and components use: VGA colour indexes, text in CP437, boxes
/// with the box tool's styles, gradients and hotkey items. Everything lands in an ordinary
/// `EditCanvas`, so a template is fully editable once created.
public struct ScreenBuilder {
    public var canvas: EditCanvas

    public init(columns: Int, rows: Int, iceColors: Bool = false) {
        canvas = EditCanvas(columns: columns, height: rows)
        if iceColors { canvas.setIceColors(true) }
    }

    public var width: Int { canvas.columns }
    public var height: Int { canvas.height }

    public static func cell(_ code: UInt8, _ fg: Int, _ bg: Int = 0) -> AnsiCell {
        AnsiCell(code: code, fg: Palette.vga[fg & 15], bg: Palette.vga[bg & 15])
    }

    /// CP437 codes for `text`; characters with no CP437 form become "?".
    public static func codes(_ text: String) -> [UInt8] {
        text.unicodeScalars.map { CP437.code(for: $0) ?? 0x3F }
    }

    /// Writes `text` from (`x`, `y`); returns the column after it. Off canvas parts are dropped.
    @discardableResult
    public mutating func text(_ text: String, x: Int, y: Int, fg: Int, bg: Int = 0) -> Int {
        var column = x
        for code in Self.codes(text) {
            canvas.set(Self.cell(code, fg, bg), x: column, y: y)
            column += 1
        }
        return column
    }

    /// Writes `text` centred in the canvas width (or in `within`).
    @discardableResult
    public mutating func centred(_ text: String, y: Int, fg: Int, bg: Int = 0, within range: Range<Int>? = nil) -> Int {
        let span = range ?? 0..<width
        let length = Self.codes(text).count
        let x = span.lowerBound + max(0, (span.count - length) / 2)
        return self.text(text, x: x, y: y, fg: fg, bg: bg)
    }

    /// Fills a rectangle with one character.
    public mutating func fill(_ rect: CellRect, code: UInt8 = 0x20, fg: Int = 7, bg: Int = 0) {
        canvas.fill(rect) { _ in Self.cell(code, fg, bg) }
    }

    /// A box outline in the box tool's styles, optionally filled and with a title in its top edge.
    public mutating func box(_ rect: CellRect, style: ShapeStyle = .line(.double), fg: Int, bg: Int = 0,
                             filled: Bool = false, title: String = "", titleColour: Int? = nil) {
        canvas.drawRectangle(rect, style: style, fg: Palette.vga[fg & 15], bg: Palette.vga[bg & 15], filled: filled)
        if !title.isEmpty, rect.width > 4 {
            let label = " \(title) "
            let x = rect.x + max(1, (rect.width - Self.codes(label).count) / 2)
            text(label, x: x, y: rect.y, fg: titleColour ?? fg, bg: bg)
        }
    }

    /// A horizontal line of one character from `x` for `length` cells.
    public mutating func hline(x: Int, y: Int, length: Int, code: UInt8 = 0xC4, fg: Int, bg: Int = 0) {
        for column in x..<max(x, x + length) { canvas.set(Self.cell(code, fg, bg), x: column, y: y) }
    }

    /// A shaded bar: ░▒▓ rising to `body` and falling again, `length` cells long.
    public mutating func gradientBar(x: Int, y: Int, length: Int, fg: Int, bg: Int = 0, body: UInt8 = 0xDB) {
        let ramp: [UInt8] = [0xB0, 0xB1, 0xB2]
        for offset in 0..<max(0, length) {
            let fromEdge = min(offset, length - 1 - offset)
            let code = fromEdge < ramp.count ? ramp[fromEdge] : body
            canvas.set(Self.cell(code, fg, bg), x: x + offset, y: y)
        }
    }

    /// "[A] Label": brackets dim, the key bright, the label in `fg`. Returns the next column.
    @discardableResult
    public mutating func hotkey(_ key: String, _ label: String, x: Int, y: Int, keyColour: Int = 15,
                                bracketColour: Int = 8, fg: Int = 7, bg: Int = 0) -> Int {
        var column = text("[", x: x, y: y, fg: bracketColour, bg: bg)
        column = text(key, x: column, y: y, fg: keyColour, bg: bg)
        column = text("] ", x: column, y: y, fg: bracketColour, bg: bg)
        return text(label, x: column, y: y, fg: fg, bg: bg)
    }

    /// Stamps a region (a font rendering, a component) with its top left at (`x`, `y`); blanks
    /// in the region leave the cells under them.
    public mutating func stamp(_ region: CanvasRegion, x: Int, y: Int) {
        canvas.paste(region, x: x, y: y, transparent: true)
    }

    /// The whole canvas as a region (for components).
    public var region: CanvasRegion { canvas.region(CellRect(x: 0, y: 0, width: width, height: height)) }
}
