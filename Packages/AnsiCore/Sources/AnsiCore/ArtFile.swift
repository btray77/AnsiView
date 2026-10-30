import Foundation

/// The kinds of art file AnsiView reads.
public enum ArtFormat: Equatable {
    /// ANSI.SYS escape sequences over CP437 text (also plain ASCII and .ice files).
    case ansi
    /// ANSI escape sequences over UTF-8 text.
    case utf8Ansi
    /// Raw character and attribute pairs (BinaryText).
    case bin
    case xbin
    /// Artworx Data Format.
    case adf
    /// iCE Draw Format.
    case idf
    /// PCBoard @X color codes.
    case pcboard
    /// Wildcat @XX@ color codes.
    case wildcat
    /// Avatar control codes.
    case avatar

    /// True for formats played through the terminal as a byte stream.
    public var isStream: Bool {
        switch self {
        case .ansi, .utf8Ansi, .pcboard, .wildcat, .avatar: return true
        case .bin, .xbin, .adf, .idf: return false
        }
    }

    /// Decides the format from SAUCE, then magic numbers, then the file extension, then content.
    public static func detect(bytes: [UInt8], fileExtension: String?, sauce: Sauce?) -> ArtFormat {
        if let sauce {
            switch (sauce.dataType, sauce.fileType) {
            case (5, _): return .bin
            case (6, _): return .xbin
            case (1, 4): return .pcboard
            case (1, 5): return .avatar
            default: break
            }
        }
        if bytes.starts(with: Array("XBIN".utf8) + [0x1A]) { return .xbin }
        if bytes.count >= 4, bytes[0] == 0x04, Array(bytes[1...3]) == Array("1.4".utf8) { return .idf }
        switch fileExtension?.lowercased() {
        case "bin": return .bin
        case "xb": return .xbin
        case "adf": return .adf
        case "idf": return .idf
        case "pcb": return .pcboard
        case "avt": return .avatar
        default: break
        }
        let head = bytes.prefix(65_536)
        if containsPCBoardCode(head) { return .pcboard }
        if containsWildcatCode(head) { return .wildcat }
        if containsAvatarCode(head) { return .avatar }
        if isUTF8WithMultibyte(bytes) { return .utf8Ansi }
        return .ansi
    }

    private static func isHex(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b)
    }

    /// "@X" followed by two hex digits.
    private static func containsPCBoardCode(_ b: ArraySlice<UInt8>) -> Bool {
        var i = b.startIndex
        while i + 3 < b.endIndex {
            if b[i] == 0x40, b[i + 1] == 0x58, isHex(b[i + 2]), isHex(b[i + 3]) { return true }
            i += 1
        }
        return false
    }

    /// "@", two hex digits, "@".
    private static func containsWildcatCode(_ b: ArraySlice<UInt8>) -> Bool {
        var i = b.startIndex
        while i + 3 < b.endIndex {
            if b[i] == 0x40, isHex(b[i + 1]), isHex(b[i + 2]), b[i + 3] == 0x40 { return true }
            i += 1
        }
        return false
    }

    /// Avatar's set attribute command, ^V^A.
    private static func containsAvatarCode(_ b: ArraySlice<UInt8>) -> Bool {
        var i = b.startIndex
        while i + 1 < b.endIndex {
            if b[i] == 0x16, b[i + 1] == 0x01 { return true }
            i += 1
        }
        return false
    }

    /// Valid UTF-8 containing at least one multibyte sequence. CP437 art with high bytes is
    /// almost never valid UTF-8, so this does not misfire on DOS files.
    private static func isUTF8WithMultibyte(_ bytes: [UInt8]) -> Bool {
        guard bytes.contains(where: { $0 >= 0x80 }) else { return false }
        return String(bytes: bytes, encoding: .utf8) != nil
    }
}

/// A loaded art file: its format, metadata, display settings and content.
public struct ArtFile {
    public static let defaultColumns = 80

    public enum Content {
        /// Bytes to play through `AnsiTerminal`.
        case stream([UInt8])
        /// A finished screen (binary formats).
        case screen(AnsiScreen)
    }

    public let format: ArtFormat
    public let sauce: Sauce?
    public let columns: Int
    public let iceColors: Bool
    public let font: BitmapFont
    public let ninePixel: Bool
    public let title: String?
    public let content: Content

    /// The byte stream for stream formats; empty for binary formats.
    public var stream: [UInt8] {
        if case .stream(let bytes) = content { return bytes }
        return []
    }

    public init(data: Data, fileExtension: String? = nil) {
        let raw = [UInt8](data)
        let (sauce, contentLength) = Sauce.read(raw)
        var body = Array(raw.prefix(contentLength))
        let format = ArtFormat.detect(bytes: body, fileExtension: fileExtension, sauce: sauce)
        if format.isStream, let eof = body.firstIndex(of: 0x1A) {
            // DOS end of file marker; anything after it is padding.
            body.removeSubrange(eof...)
        }
        // iCE files use the blink bit for bright backgrounds instead of blinking.
        let iceColors = fileExtension?.lowercased() == "ice" || sauce?.iceColors == true
        var font = BitmapFont.named(sauce?.fontName)
        var columns = sauce?.columns ?? Self.defaultColumns

        let loaded: (AnsiScreen, BitmapFont?)?
        switch format {
        case .bin:
            // BinaryText without a SAUCE width is conventionally 160 columns.
            loaded = (BinaryFormats.bin(body, columns: sauce?.columns ?? 160, ice: iceColors), nil)
        case .xbin: loaded = try? BinaryFormats.xbin(body)
        case .adf: loaded = (try? BinaryFormats.adf(body)).map { ($0.0, $0.1) }
        case .idf: loaded = try? BinaryFormats.idf(body)
        default: loaded = nil
        }

        self.format = format
        self.sauce = sauce
        self.iceColors = iceColors
        self.ninePixel = sauce?.letterSpacing == .nine
        self.title = sauce.flatMap { $0.title.isEmpty ? nil : $0.title }
        if format.isStream {
            self.content = .stream(body)
        } else {
            var screen = loaded?.0 ?? AnsiScreen(columns: columns, rows: [])
            if let embedded = loaded?.1 { font = embedded }
            screen.font = font
            screen.sauce = sauce
            screen.title = title
            columns = screen.columns
            self.content = .screen(screen)
        }
        self.columns = columns
        self.font = font
    }
}
