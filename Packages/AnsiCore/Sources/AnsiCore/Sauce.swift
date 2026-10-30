import Foundation

/// The SAUCE metadata record art files carry in their last 128 bytes, plus its optional comment block.
/// Layout: https://www.acid.org/info/sauce/sauce.htm
public struct Sauce: Equatable {
    public enum LetterSpacing: Equatable { case unspecified, eight, nine }
    public enum AspectRatio: Equatable { case unspecified, legacy, square }

    public static let recordLength = 128
    static let commentLength = 64

    public var title: String
    public var author: String
    public var group: String
    public var date: DateComponents?
    public var dataType: UInt8
    public var fileType: UInt8
    public var tInfo: [UInt16]
    public var flags: UInt8
    public var fontName: String
    public var comments: [String]

    /// iCE colors: the blink bit selects bright backgrounds instead of blinking.
    public var iceColors: Bool { flags & 0x01 != 0 }

    public var letterSpacing: LetterSpacing {
        switch (flags >> 1) & 0x03 {
        case 1: return .eight
        case 2: return .nine
        default: return .unspecified
        }
    }

    public var aspectRatio: AspectRatio {
        switch (flags >> 3) & 0x03 {
        case 1: return .legacy
        case 2: return .square
        default: return .unspecified
        }
    }

    /// Character width the record specifies, when it is believable.
    public var columns: Int? {
        switch dataType {
        case 1, 6:
            let width = Int(tInfo[0])
            return (1...1000).contains(width) ? width : nil
        case 5:
            // BinaryText stores half the width in the file type byte.
            return fileType > 0 ? Int(fileType) * 2 : nil
        default:
            return nil
        }
    }

    public init(title: String, author: String, group: String, date: DateComponents?, dataType: UInt8,
                fileType: UInt8, tInfo: [UInt16], flags: UInt8, fontName: String, comments: [String]) {
        self.title = title
        self.author = author
        self.group = group
        self.date = date
        self.dataType = dataType
        self.fileType = fileType
        self.tInfo = tInfo
        self.flags = flags
        self.fontName = fontName
        self.comments = comments
    }

    /// What goes after the art: the 0x1A end of file marker, the comment block when there are
    /// comments (at most 255 lines of 64 characters), then the 128 byte record.
    /// `fileSize` is the length of the art before the marker.
    public func encoded(fileSize: Int) -> [UInt8] {
        var out: [UInt8] = [0x1A]
        let lines = Array(comments.prefix(255))
        if !lines.isEmpty {
            out += Array("COMNT".utf8)
            for line in lines { out += CP437.bytes(line, length: Self.commentLength) }
        }
        var record = Array("SAUCE00".utf8)
        record += CP437.bytes(title, length: 35)
        record += CP437.bytes(author, length: 20)
        record += CP437.bytes(group, length: 20)
        if let date, let year = date.year, let month = date.month, let day = date.day {
            record += Array(String(format: "%04d%02d%02d", year, month, day).utf8)
        } else {
            record += Array(repeating: 0x20, count: 8)
        }
        let size = UInt32(clamping: fileSize)
        record += [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)]
        record += [dataType, fileType]
        for index in 0..<4 {
            let value = index < tInfo.count ? tInfo[index] : 0
            record += [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        record += [UInt8(lines.count), flags]
        var font = Array(fontName.utf8.prefix(22))
        font += Array(repeating: 0, count: 22 - font.count)
        record += font
        return out + record
    }

    /// Finds a SAUCE record at the end of `bytes`. `contentLength` is where the art itself ends:
    /// before the comment block, the record, and the 0x1A end of file marker preceding them.
    public static func read(_ bytes: [UInt8]) -> (sauce: Sauce?, contentLength: Int) {
        guard bytes.count >= recordLength else { return (nil, bytes.count) }
        let start = bytes.count - recordLength
        guard Array(bytes[start..<start + 7]) == Array("SAUCE00".utf8) else { return (nil, bytes.count) }

        func text(_ offset: Int, _ length: Int) -> String {
            cp437String(bytes[(start + offset)..<(start + offset + length)])
        }
        func word(_ offset: Int) -> UInt16 {
            UInt16(bytes[start + offset]) | UInt16(bytes[start + offset + 1]) << 8
        }

        var contentEnd = start
        var comments: [String] = []
        let commentCount = Int(bytes[start + 104])
        let blockStart = start - 5 - commentCount * commentLength
        if commentCount > 0, blockStart >= 0, Array(bytes[blockStart..<blockStart + 5]) == Array("COMNT".utf8) {
            for i in 0..<commentCount {
                let lineStart = blockStart + 5 + i * commentLength
                comments.append(cp437String(bytes[lineStart..<lineStart + commentLength]))
            }
            contentEnd = blockStart
        }
        if contentEnd > 0, bytes[contentEnd - 1] == 0x1A { contentEnd -= 1 }

        let sauce = Sauce(
            title: text(7, 35),
            author: text(42, 20),
            group: text(62, 20),
            date: parseDate(text(82, 8)),
            dataType: bytes[start + 94],
            fileType: bytes[start + 95],
            tInfo: [word(96), word(98), word(100), word(102)],
            flags: bytes[start + 105],
            fontName: text(106, 22),
            comments: comments)
        return (sauce, contentEnd)
    }

    private static func parseDate(_ text: String) -> DateComponents? {
        guard text.count == 8, let value = Int(text) else { return nil }
        let year = value / 10000, month = value / 100 % 100, day = value % 100
        guard (1...12).contains(month), (1...31).contains(day), year > 0 else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }
}

/// Decodes CP437 bytes, dropping trailing spaces and NULs.
func cp437String<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    var scalars = String.UnicodeScalarView()
    for byte in bytes {
        scalars.append(byte == 0 ? " " : CP437.unicode[Int(byte)])
    }
    return String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: " \u{00A0}"))
}
