import Foundation

/// Ways to take rendered text art out of the Text to ASCII window (plan ruling 20).
public enum TextArtOutput {
    public enum CommentStyle: String, CaseIterable {
        case slashes, hash, dashes, block, semicolon, box

        public var label: String {
            switch self {
            case .slashes: return "// (C, Swift, JavaScript)"
            case .hash: return "# (shell, Python, Ruby)"
            case .dashes: return "-- (SQL, Lua, Haskell)"
            case .block: return "/* */ (C, CSS)"
            case .semicolon: return "; (assembly, Lisp, INI)"
            case .box: return "Box border"
            }
        }
    }

    /// Box and block characters as ASCII for the ASCII only copy.
    static let asciiFallback: [Unicode.Scalar: Character] = {
        var map: [Unicode.Scalar: Character] = [:]
        for s in "─━═╌╍" .unicodeScalars { map[s] = "-" }
        for s in "│┃║╎╏" .unicodeScalars { map[s] = "|" }
        for s in "┌┐└┘├┤┬┴┼╒╓╔╕╖╗╘╙╚╛╜╝╞╟╠╡╢╣╤╥╦╧╨╩╪╫╬" .unicodeScalars { map[s] = "+" }
        for s in "█▓■" .unicodeScalars { map[s] = "#" }
        map["▒"] = ":"
        map["░"] = "."
        map["▀"] = "\""
        map["▄"] = "_"
        map["▌"] = "["
        map["▐"] = "]"
        map["\u{00A0}"] = " "
        return map
    }()

    /// The cells as text: CP437 shown as Unicode, or as ASCII only; trailing spaces trimmed.
    public static func plainText(_ region: CanvasRegion, asciiOnly: Bool = false) -> String {
        region.cells.map { row -> String in
            var line = ""
            for cell in row {
                let scalar = cell.scalar ?? (cell.code == 0 ? " " : CP437.unicode[Int(cell.code)])
                if !asciiOnly || scalar.isASCII {
                    line.unicodeScalars.append(scalar.isASCII && scalar.value < 32 ? " " : scalar)
                } else if let mapped = asciiFallback[scalar] {
                    line.append(mapped)
                } else {
                    let plain = String(scalar).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
                    line.append(plain.unicodeScalars.count == 1 && plain.unicodeScalars.first!.isASCII ? plain : "?")
                }
            }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }.joined(separator: "\n")
    }

    /// The cells as ANSI text with 24 bit colours (what terminals and AnsiView read back).
    public static func ansi(_ region: CanvasRegion) -> String {
        let screen = AnsiScreen(columns: max(1, region.width), rows: region.cells)
        return TextConvert.modernANSI(screen, colors: .trueColor)
    }

    /// A classic CP437 .ans file with a SAUCE record.
    public static func ansFile(_ region: CanvasRegion, title: String = "", iceColors: Bool = false) throws -> Data {
        var canvas = EditCanvas(columns: max(1, region.width), height: max(1, region.height))
        canvas.setIceColors(iceColors)
        canvas.paste(region, x: 0, y: 0)
        canvas.title = String(title.prefix(35))
        return try ArtWriter.data(canvas, format: .ansi)
    }

    /// `text` wrapped as a source code comment.
    public static func comment(_ text: String, style: CommentStyle) -> String {
        let lines = text.components(separatedBy: "\n")
        func prefixed(_ mark: String) -> String {
            lines.map { $0.isEmpty ? mark : "\(mark) \($0)" }.joined(separator: "\n")
        }
        switch style {
        case .slashes: return prefixed("//")
        case .hash: return prefixed("#")
        case .dashes: return prefixed("--")
        case .semicolon: return prefixed(";")
        case .block:
            // "*/" inside the art would end the comment early: break it apart.
            let safe = lines.map { $0.replacingOccurrences(of: "*/", with: "* /") }
            return (["/*"] + safe.map { $0.isEmpty ? " *" : " * \($0)" } + [" */"]).joined(separator: "\n")
        case .box:
            let width = lines.map(\.count).max() ?? 0
            let edge = "+" + String(repeating: "-", count: width + 2) + "+"
            let body = lines.map { "| " + $0 + String(repeating: " ", count: width - $0.count) + " |" }
            return ([edge] + body + [edge]).joined(separator: "\n")
        }
    }

    /// A Markdown fenced code block, with a longer fence when the art has backticks.
    public static func markdown(_ text: String) -> String {
        var fence = "```"
        while text.contains(fence) { fence += "`" }
        return "\(fence)text\n\(text)\n\(fence)"
    }
}

/// Hint and (?) texts for the font windows (kept here so tests check them).
public enum FontHelp {
    public static let tdfTypes = """
    TheDraw fonts (.TDF) come in three kinds. Outline fonts store the shape of each letter and \
    AnsiView draws it with the outline style you pick, in your colours. Block fonts store the \
    characters and use your colours. Colour fonts store characters and their own colours, which \
    are kept exactly; on an iCE canvas their blink bit becomes a bright background. One .TDF file \
    can hold many fonts; each is listed on its own.
    """

    public static let outlineStyles = """
    Outline styles are the 19 line sets TheDraw offers for outline fonts: single and double \
    lines in every mix (top, bottom, left and right edges can each be single or double) and \
    three half block styles. The font only says where the edges and corners go.
    """

    public static let figletLayouts = """
    FIGlet layouts decide how close letters sit. Full width puts every letter at its full \
    width. Fitted moves letters together until they touch. Smushed moves them one more \
    column where the font's rules allow two touching characters to merge into one: equal \
    characters, an underscore under a line, the stronger of two brackets or slashes, opposite \
    brackets becoming |, /\\ becoming |, \\/ becoming Y and >< becoming X, and two hardblanks. \
    Universal smush overlaps letters whatever the characters, the right one winning. \
    Vertical layout does the same between lines of text. Font default uses what the font's \
    designer chose.
    """

    public static let import_ = """
    Import TheDraw (.tdf) and FIGlet (.flf, .tlf) fonts, folders of them, or .zip packs. \
    AnsiView copies them into its own font folder; the originals are not changed. Font \
    archives from BBS days (for example the big TheDraw font collections) can be imported \
    as they are.
    """

    public static let emptyState = """
    These are the fonts that come with AnsiView. Import your own TheDraw and FIGlet font \
    collections (files, folders or .zip packs) to see them here too.
    """
}
