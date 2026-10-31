import Foundation

/// Saves a canvas in a format, opens the bytes again the way AnsiView opens a file, and counts the
/// cells that differ from what the format can hold (final gaps T6). The losses each format reports
/// in `SaucePreservation.saveReport` (nearest VGA colour, iCE, PCBoard's @X00, lookalikes for
/// control codes) are applied to the expected cells first, so any count above zero is a bug.
public enum SaveRoundTrip {
    public struct Result: Equatable {
        public var bytes = 0
        public var cells = 0
        public var differing = 0
        /// Why the format refused the art (too wide), when it did.
        public var refused: String?
    }

    public static func check(_ canvas: EditCanvas, format: SaveFormat) -> Result {
        var result = Result()
        if format == .wildcat, canvas.columns > 80 {
            // Reported on save: Wildcat files carry no width, so such art opens 80 columns wide.
            result.refused = "not checked: Wildcat files carry no width (art \(canvas.columns) columns wide)"
            return result
        }
        let data: Data
        do { data = try ArtWriter.data(canvas, format: format) } catch {
            result.refused = error.localizedDescription
            return result
        }
        result.bytes = data.count
        let back = EditCanvas(file: ArtFile(data: data, fileExtension: format.fileExtension))
        let rows = max(canvas.screen(trimmed: true).rows.count, back.screen(trimmed: true).rows.count)
        for y in 0..<rows {
            for x in 0..<canvas.columns {
                result.cells += 1
                if normalized(expected(canvas[x, y], canvas: canvas, format: format), format: format)
                    != normalized(back[x, y], format: format) {
                    result.differing += 1
                }
            }
        }
        return result
    }

    /// The cell a format can hold for `cell`.
    static func expected(_ cell: AnsiCell, canvas: EditCanvas, format: SaveFormat) -> AnsiCell {
        var cell = cell
        if cell.scalar != nil { cell.scalar = nil; cell.code = 0x3F }
        let stream = ![SaveFormat.bin, .xbin, .adf, .idf].contains(format)
        if stream, let lookalike = TextConvert.lookalikes[cell.code] { cell.code = lookalike }
        if [.ice, .adf, .idf].contains(format) { cell = EditCanvas.cell(cell, iceColors: true) }
        guard ![SaveFormat.ansi, .ice].contains(format) else { return cell }
        // Through the attribute byte, in the canvas's palette where the format stores it.
        let ice = canvas.iceColors || [.adf, .idf].contains(format)
        let palette = [SaveFormat.xbin, .adf, .idf].contains(format) ? canvas.palette : nil
        var attribute = ArtWriter.attribute(cell, ice: ice, palette: palette)
        if format == .pcboard {
            if attribute == 0x00 { attribute = cell.code == 0x20 || cell.code == 0 ? 0x07 : 0x08 }
            if attribute == 0xFF { attribute = 0x7F }
        }
        let colours = palette ?? Palette.vga
        let high = attribute & 0x80 != 0
        cell.fg = colours[Int(attribute & 0x0F)]
        cell.bg = colours[Int(attribute >> 4 & 7) + (ice && high ? 8 : 0)]
        cell.blink = high && !ice
        if stream, cell.code == 0 { cell.code = 0x20 }
        return cell
    }

    /// Wildcat files carry no iCE flag, so both sides are compared as blink cells (ruling 5).
    static func normalized(_ cell: AnsiCell, format: SaveFormat) -> AnsiCell {
        format == .wildcat ? EditCanvas.cell(cell, iceColors: false) : cell
    }
}
