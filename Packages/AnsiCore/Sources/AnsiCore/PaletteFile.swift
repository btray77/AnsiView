import Foundation

/// A 16 colour palette in VGA attribute order (1 is blue, 4 is red), with a name for menus.
public struct NamedPalette: Equatable, Codable {
    public var name: String
    public var colors: [RGB]

    public init(name: String, colors: [RGB]) {
        self.name = name
        self.colors = PaletteFile.normalized(colors)
    }
}

/// Palette files a viewer can switch to (plan 9 ruling 6): JASC-PAL, GIMP, Adobe ACT, and the
/// palettes embedded in XBin, ADF and IDF art.
public enum PaletteFile {
    public enum LoadError: LocalizedError, Equatable {
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "This is not a palette AnsiView can read: \(why)."
            }
        }
    }

    /// The extensions the Load Palette panel accepts.
    public static let extensions = ["pal", "gpl", "act", "xb", "adf", "idf"]

    public static func load(_ data: Data, fileExtension: String, name: String) throws -> NamedPalette {
        let bytes = [UInt8](data)
        switch fileExtension.lowercased() {
        case "pal": return NamedPalette(name: name, colors: try jasc(bytes))
        case "gpl":
            let (title, colors) = try gpl(bytes)
            return NamedPalette(name: title ?? name, colors: colors)
        case "act": return NamedPalette(name: name, colors: try act(bytes))
        case "xb", "adf", "idf":
            let format: ArtFormat = fileExtension.lowercased() == "xb" ? .xbin : fileExtension.lowercased() == "adf" ? .adf : .idf
            let (_, length) = Sauce.read(bytes)
            guard let colors = BinaryFormats.embeddedPalette(Array(bytes.prefix(length)), format: format) else {
                throw LoadError.unreadable("the file has no palette of its own")
            }
            return NamedPalette(name: name, colors: colors)
        default:
            throw LoadError.unreadable("unknown kind of file")
        }
    }

    /// Exactly 16 colours: extra ones dropped, missing ones taken from VGA.
    public static func normalized(_ colors: [RGB]) -> [RGB] {
        Array(colors.prefix(16)) + Palette.vga.dropFirst(min(16, colors.count))
    }

    /// Three whole numbers 0 to 255 at the start of a line, or nil.
    private static func triple(_ line: Substring) throws -> RGB? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 3, let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]) else { return nil }
        guard [r, g, b].allSatisfy({ (0...255).contains($0) }) else { throw LoadError.unreadable("a colour is out of range") }
        return RGB(r: UInt8(r), g: UInt8(g), b: UInt8(b))
    }

    private static func lines(_ bytes: [UInt8]) -> [Substring] {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces)[...] }
    }

    /// Paint Shop Pro's text palette: `JASC-PAL`, `0100`, a count, then `r g b` lines.
    static func jasc(_ bytes: [UInt8]) throws -> [RGB] {
        let all = lines(bytes)
        guard all.count >= 3, all[0] == "JASC-PAL", let count = Int(all[2]), count > 0 else {
            throw LoadError.unreadable("no JASC-PAL header")
        }
        var colors: [RGB] = []
        for line in all.dropFirst(3) where colors.count < count {
            if let color = try triple(line) { colors.append(color) }
        }
        guard !colors.isEmpty else { throw LoadError.unreadable("no colours") }
        return normalized(colors)
    }

    /// GIMP's palette: `GIMP Palette`, optional `Name:` and `Columns:`, `#` comments, `r g b name`.
    static func gpl(_ bytes: [UInt8]) throws -> (name: String?, colors: [RGB]) {
        let all = lines(bytes)
        guard all.first == "GIMP Palette" else { throw LoadError.unreadable("no GIMP Palette header") }
        var name: String?
        var colors: [RGB] = []
        for line in all.dropFirst() {
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("Name:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { name = value }
                continue
            }
            if line.hasPrefix("Columns:") { continue }
            if let color = try triple(line) { colors.append(color) }
        }
        guard !colors.isEmpty else { throw LoadError.unreadable("no colours") }
        return (name, normalized(colors))
    }

    /// Adobe colour table: 256 RGB triples, optionally a big endian count and a transparency index.
    static func act(_ bytes: [UInt8]) throws -> [RGB] {
        guard bytes.count == 768 || bytes.count == 772 else { throw LoadError.unreadable("an ACT file is 768 or 772 bytes") }
        var count = 256
        if bytes.count == 772 {
            let stated = Int(bytes[768]) << 8 | Int(bytes[769])
            if (1...256).contains(stated) { count = stated }
        }
        let colors = (0..<min(16, count)).map { i in RGB(r: bytes[i * 3], g: bytes[i * 3 + 1], b: bytes[i * 3 + 2]) }
        return normalized(colors)
    }

    /// Palettes offered without loading anything (plan 9 ruling 6).
    public static let builtIn: [NamedPalette] = {
        var cga = Palette.vga
        // The first CGA monitors showed colour 6 as dark yellow; IBM's 5153 made it brown.
        cga[6] = RGB(r: 0xAA, g: 0xAA, b: 0x00)
        let grey = Palette.vga.map { (c: RGB) -> RGB in
            let weighted: Int = Int(c.r) * 299 + Int(c.g) * 587 + Int(c.b) * 114
            let y = UInt8(min(255, weighted / 1000))
            return RGB(r: y, g: y, b: y)
        }
        return [NamedPalette(name: "VGA", colors: Palette.vga),
                NamedPalette(name: "CGA (dark yellow)", colors: cga),
                NamedPalette(name: "Greyscale", colors: grey)]
    }()
}

/// Shows art in another palette: each of the piece's own 16 colours becomes the colour with the
/// same index in the chosen palette; any other colour stays (cells store colours, not indexes).
public enum PaletteRemap {
    /// The colours the piece was drawn with: its embedded palette (XBin, ADF, IDF), else VGA.
    public static func sourcePalette(for file: ArtFile) -> [RGB] {
        file.embeddedPalette ?? Palette.vga
    }

    /// Colour substitutions; empty when nothing changes. A colour listed twice maps by its first index.
    public static func map(from source: [RGB], to target: [RGB]) -> [RGB: RGB] {
        var map: [RGB: RGB] = [:]
        let target = PaletteFile.normalized(target)
        for (index, color) in PaletteFile.normalized(source).enumerated() where map[color] == nil {
            map[color] = target[index]
        }
        return map.filter { $0.key != $0.value }
    }

    public static func apply(_ map: [RGB: RGB], to screen: AnsiScreen) -> AnsiScreen {
        guard !map.isEmpty else { return screen }
        var out = screen
        for y in out.rows.indices {
            for x in out.rows[y].indices {
                if let fg = map[out.rows[y][x].fg] { out.rows[y][x].fg = fg }
                if let bg = map[out.rows[y][x].bg] { out.rows[y][x].bg = bg }
            }
        }
        return out
    }
}
