import Foundation

/// Art as a chat code block (plan 10 rulings 1 to 3). Discord's ```ansi blocks show only SGR 0,
/// 1, 4, 30 to 37 and 40 to 47, in its own Solarized style colours; Slack's code blocks show no
/// colour, so Slack gets the plain characters. See docs/CHAT-COLOURS.md for the table.
public enum ChatCodeBlock {
    /// Characters in one Discord message (4,000 with Nitro).
    public static let discordLimit = 2000

    /// A ```ansi block with colour codes Discord understands, written only where the colour changes.
    public static func discord(_ screen: AnsiScreen) -> String {
        var lines: [String] = []
        for row in TextConvert.trimmedRows(screen) {
            let cells = trimmed(row, columns: screen.columns)
            var line = String.UnicodeScalarView()
            var current: [Int] = []
            for cell in cells {
                // A space shows only its background, so its foreground never needs a code.
                var codes = discordCodes(fg: cell.fg, bg: cell.bg)
                if isSpace(cell) { codes = codes.filter { (40...47).contains($0) } + current.filter { !(40...47).contains($0) } }
                codes = normalised(codes)
                if codes != current {
                    line.append(contentsOf: ("\u{1B}[" + ([0] + codes).map(String.init).joined(separator: ";") + "m").unicodeScalars)
                    current = codes
                }
                line.append(character(cell))
            }
            if !current.isEmpty { line.append(contentsOf: "\u{1B}[0m".unicodeScalars) }
            lines.append(String(line))
        }
        return "```ansi\n" + lines.joined(separator: "\n") + "\n```"
    }

    /// A plain ``` block of the characters (Slack shows no colour in code blocks).
    public static func slack(_ screen: AnsiScreen) -> String {
        let lines = TextConvert.trimmedRows(screen).map { row -> String in
            var scalars = String.UnicodeScalarView()
            for cell in trimmed(row, columns: screen.columns) { scalars.append(character(cell)) }
            return String(scalars)
        }
        return "```\n" + lines.joined(separator: "\n") + "\n```"
    }

    /// Characters as a chat app counts them.
    public static func characterCount(_ text: String) -> Int { text.count }

    /// Discord codes for a cell's colours: foreground by ANSI hue (bold for the bright half, light
    /// grey left as Discord's own text colour), background by hue with black left as Discord's own.
    public static func discordCodes(fg: RGB, bg: RGB) -> [Int] {
        var codes: [Int] = []
        let f = nearestVGA(fg)
        if f >= 8 { codes.append(1) }
        if f != 7 { codes.append(30 + vgaToANSI[f % 8]) }
        let b = nearestVGA(bg) % 8
        if b != 0 { codes.append(40 + vgaToANSI[b]) }
        return codes
    }

    /// The VGA index (0 to 15) nearest to `color`.
    public static func nearestVGA(_ color: RGB) -> Int {
        if let exact = Palette.vga.firstIndex(of: color) { return exact }
        var best = 0, bestDistance = Int.max
        for (index, vga) in Palette.vga.enumerated() {
            let distance = TextConvert.squaredDistance(vga, color)
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        return best
    }

    // MARK: Helpers

    /// VGA attribute order to ANSI order (blue 1 is ANSI 4, red 4 is ANSI 1).
    static let vgaToANSI: [Int] = (0..<8).map { vga in Palette.ansiToVGA.firstIndex(of: vga)! }

    /// Bold first, then foreground, then background.
    private static func normalised(_ codes: [Int]) -> [Int] {
        Array(Set(codes)).sorted()
    }

    private static func isSpace(_ cell: AnsiCell) -> Bool {
        cell.scalar == nil && (cell.code == 0x20 || cell.code == 0 || cell.code == 0xFF)
    }

    /// The row without trailing spaces on Discord's own background.
    private static func trimmed(_ row: [AnsiCell], columns: Int) -> [AnsiCell] {
        var cells = Array(row.prefix(columns))
        while let last = cells.last, isSpace(last), nearestVGA(last.bg) % 8 == 0 { cells.removeLast() }
        return cells
    }

    /// The cell's character; a backtick becomes a lookalike so the art cannot close the fence.
    private static func character(_ cell: AnsiCell) -> Unicode.Scalar {
        let scalar = TextConvert.scalar(cell)
        return scalar == "`" ? "\u{02CB}" : scalar
    }
}
