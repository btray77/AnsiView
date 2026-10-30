import CryptoKit
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
        // Art extensions are trusted: an "@" in ASCII art must not turn it into a BBS format.
        let artExtensions: Set<String> = ["ans", "asc", "nfo", "diz", "ice"]
        if !artExtensions.contains(fileExtension?.lowercased() ?? "") {
            let head = bytes.prefix(65_536)
            if isConvincing(codeOffsets(head, matching: isPCBoardCode)) { return .pcboard }
            if isConvincing(codeOffsets(head, matching: isWildcatCode)) { return .wildcat }
            if isConvincing(codeOffsets(head, matching: isAvatarCode)) { return .avatar }
        }
        if isUTF8WithMultibyte(bytes) { return .utf8Ansi }
        return .ansi
    }

    private static func isHex(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b)
    }

    /// A file really uses a code format when a code appears near the start or several times.
    private static func isConvincing(_ offsets: [Int]) -> Bool {
        offsets.count >= 3 || (offsets.first.map { $0 < 256 } ?? false)
    }

    /// Offsets (from the start) of up to three codes.
    private static func codeOffsets(_ b: ArraySlice<UInt8>, matching test: (ArraySlice<UInt8>, Int) -> Bool) -> [Int] {
        var found: [Int] = []
        var i = b.startIndex
        while i < b.endIndex, found.count < 3 {
            if test(b, i) { found.append(i - b.startIndex) }
            i += 1
        }
        return found
    }

    /// "@X" followed by two hex digits.
    private static func isPCBoardCode(_ b: ArraySlice<UInt8>, _ i: Int) -> Bool {
        i + 3 < b.endIndex && b[i] == 0x40 && b[i + 1] == 0x58 && isHex(b[i + 2]) && isHex(b[i + 3])
    }

    /// "@", two hex digits, "@".
    private static func isWildcatCode(_ b: ArraySlice<UInt8>, _ i: Int) -> Bool {
        i + 3 < b.endIndex && b[i] == 0x40 && isHex(b[i + 1]) && isHex(b[i + 2]) && b[i + 3] == 0x40
    }

    /// Avatar's set attribute command, ^V^A.
    private static func isAvatarCode(_ b: ArraySlice<UInt8>, _ i: Int) -> Bool {
        i + 1 < b.endIndex && b[i] == 0x16 && b[i + 1] == 0x01
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
    /// Identifies the file by its bytes: the first 16 hex digits of their SHA-256. Survives renames
    /// and moves, and is the same in the app and in Quick Look.
    public let identity: String
    /// Size of the whole file in bytes, SAUCE record included.
    public let byteCount: Int

    /// The byte stream for stream formats; empty for binary formats.
    public var stream: [UInt8] {
        if case .stream(let bytes) = content { return bytes }
        return []
    }

    public init(data: Data, fileExtension: String? = nil) {
        let raw = [UInt8](data)
        byteCount = raw.count
        identity = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let (sauce, contentLength) = Sauce.read(raw)
        var body = Array(raw.prefix(contentLength))
        let format = ArtFormat.detect(bytes: body, fileExtension: fileExtension, sauce: sauce)
        // Avatar uses 0x1A as a parameter value, so its translator finds end of file itself.
        if format.isStream, format != .avatar, let eof = body.firstIndex(of: 0x1A) {
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
            switch format {
            case .pcboard: self.content = .stream(BBSCodes.pcboardToANSI(body))
            case .wildcat: self.content = .stream(BBSCodes.wildcatToANSI(body))
            case .avatar: self.content = .stream(BBSCodes.avatarToANSI(body))
            default: self.content = .stream(body)
            }
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
