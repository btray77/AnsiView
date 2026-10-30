import Foundation

/// How the HTML export writes colours.
public enum HTMLStyle {
    /// VGA colours as classes in a style block (smaller files); other colours inline.
    case classes
    /// A `style` attribute on every span (survives pasting into other pages).
    case inline
}

/// Coloured text HTML of a screen: a `pre` block of spans, CP437 mapped to Unicode.
public enum HTMLExport {
    /// The bundled Px437 font for a font's height, its family name and TTF bytes.
    public static func fontData(for font: BitmapFont) -> (name: String, data: Data)? {
        let file: String
        switch font.height {
        case 14: file = "Px437_IBM_EGA_8x14"
        case 8: file = "Px437_IBM_EGA_8x8"
        default: file = "Px437_IBM_VGA_8x16"
        }
        guard let url = Bundle.module.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts"),
              let data = try? Data(contentsOf: url) else { return nil }
        return (file.replacingOccurrences(of: "_", with: " "), data)
    }

    public static func document(_ screen: AnsiScreen, style: HTMLStyle = .classes, embedFont: Bool = true,
                                title: String? = nil) -> String {
        let font = embedFont ? fontData(for: screen.font) : nil
        let size = font == nil ? 16 : (screen.font.height == 14 || screen.font.height == 8 ? screen.font.height : 16)
        var css = ""
        if let font {
            css += "/* \(font.name) font from the Oldschool PC Font Pack by VileR (int10h.org), "
                + "licensed under CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/). */\n"
            css += "@font-face{font-family:\"AnsiView Px437\";src:url(data:font/ttf;base64,"
                + font.data.base64EncodedString() + ") format(\"truetype\");}\n"
        }
        let family = (font == nil ? "" : "\"AnsiView Px437\",") + "ui-monospace,Menlo,monospace"
        css += "body{background:#000;margin:0;padding:16px}\n"
        css += "pre.ansi{font-family:\(family);font-size:\(size)px;line-height:1;margin:0;"
            + "color:\(hex(Palette.vga[7]));background:\(hex(Palette.vga[0]));display:inline-block;"
            + "font-variant-ligatures:none;-webkit-font-smoothing:none}\n"
        if style == .classes {
            for (index, color) in Palette.vga.enumerated() { css += ".f\(index){color:\(hex(color))}" }
            css += "\n"
            for (index, color) in Palette.vga.enumerated() { css += ".b\(index){background:\(hex(color))}" }
            css += "\n"
        }
        css += ".blink{animation:ansiblink 0.92s steps(1) infinite}@keyframes ansiblink{50%{color:transparent}}\n"

        var body = ""
        for row in TextConvert.trimmedRows(screen) {
            var cells = Array(row.prefix(screen.columns))
            while cells.count < screen.columns { cells.append(AnsiCell()) }
            var start = 0
            while start < cells.count {
                var end = start + 1
                let first = cells[start]
                while end < cells.count, cells[end].fg == first.fg, cells[end].bg == first.bg,
                      cells[end].blink == first.blink { end += 1 }
                var text = ""
                for cell in cells[start..<end] { text += escape(TextConvert.scalar(cell)) }
                body += span(first, style: style, text: text)
                start = end
            }
            body += "\n"
        }

        return "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
            + "<meta name=\"generator\" content=\"AnsiView\">"
            + "<title>\(escape(title ?? screen.title ?? "ANSI Art"))</title>\n<style>\n\(css)</style></head>\n"
            + "<body><pre class=\"ansi\">\(body)</pre></body></html>\n"
    }

    // MARK: Helpers

    private static func span(_ cell: AnsiCell, style: HTMLStyle, text: String) -> String {
        var classes: [String] = []
        var styles: [String] = []
        let defaultFG = cell.fg == Palette.vga[7], defaultBG = cell.bg == Palette.vga[0]
        if style == .classes, let index = Palette.vga.firstIndex(of: cell.fg) {
            if !defaultFG { classes.append("f\(index)") }
        } else if !defaultFG {
            styles.append("color:\(hex(cell.fg))")
        }
        if style == .classes, let index = Palette.vga.firstIndex(of: cell.bg) {
            if !defaultBG { classes.append("b\(index)") }
        } else if !defaultBG {
            styles.append("background:\(hex(cell.bg))")
        }
        if cell.blink { classes.append("blink") }
        if classes.isEmpty && styles.isEmpty { return text }
        var attributes = ""
        if !classes.isEmpty { attributes += " class=\"\(classes.joined(separator: " "))\"" }
        if !styles.isEmpty { attributes += " style=\"\(styles.joined(separator: ";"))\"" }
        return "<span\(attributes)>\(text)</span>"
    }

    private static func hex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", c.r, c.g, c.b) }

    private static func escape(_ scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "&": return "&amp;"
        case "<": return "&lt;"
        case ">": return "&gt;"
        default: return String(Character(scalar))
        }
    }

    private static func escape(_ text: String) -> String {
        text.unicodeScalars.map(escape).joined()
    }
}

extension TextConvert {
    /// The screen in a text format, as file bytes.
    public static func data(_ screen: AnsiScreen, format: TextFormat, htmlStyle: HTMLStyle = .classes,
                            embedFont: Bool = true) -> Data {
        switch format {
        case .html: return Data(HTMLExport.document(screen, style: htmlStyle, embedFont: embedFont).utf8)
        case .ansi: return Data(modernANSI(screen, colors: .trueColor).utf8)
        case .ansi256: return Data(modernANSI(screen, colors: .xterm256).utf8)
        case .text: return Data(cp437Text(screen))
        case .utf8: return Data(utf8Text(screen).utf8)
        }
    }
}
