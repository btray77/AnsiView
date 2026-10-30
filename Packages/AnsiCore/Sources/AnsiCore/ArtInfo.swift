import Foundation

extension ArtFormat {
    /// The format's name as shown to people.
    public var displayName: String {
        switch self {
        case .ansi: return "ANSI"
        case .utf8Ansi: return "UTF-8 ANSI"
        case .bin: return "BinaryText"
        case .xbin: return "XBin"
        case .adf: return "Artworx ADF"
        case .idf: return "iCE Draw"
        case .pcboard: return "PCBoard"
        case .wildcat: return "Wildcat"
        case .avatar: return "Avatar"
        case .rip: return "RIPscrip"
        }
    }
}

/// What the info sheet shows for a file: its SAUCE fields, then columns, format and size.
public struct ArtInfo {
    public struct Row: Equatable {
        public let label: String
        public let value: String
    }

    public static let noSauce = "No SAUCE record"

    public let hasSauce: Bool
    public let rows: [Row]

    public init(_ file: ArtFile) {
        var rows: [Row] = []
        func add(_ label: String, _ value: String) { rows.append(Row(label: label, value: value)) }
        func orNone(_ text: String) -> String { text.isEmpty ? "None" : text }
        if let sauce = file.sauce {
            add("Title", orNone(sauce.title))
            add("Author", orNone(sauce.author))
            add("Group", orNone(sauce.group))
            add("Date", sauce.date.map(Self.formatDate) ?? "None")
            let comments = sauce.comments.filter { !$0.isEmpty }
            if !comments.isEmpty { add("Comments", comments.joined(separator: "\n")) }
            add("Font", orNone(sauce.fontName))
            add("iCE Colors", sauce.iceColors ? "Yes" : "No")
            switch sauce.letterSpacing {
            case .eight: add("Letter Spacing", "8 pixel")
            case .nine: add("Letter Spacing", "9 pixel")
            case .unspecified: add("Letter Spacing", "Not set")
            }
            switch sauce.aspectRatio {
            case .legacy: add("Aspect", "Legacy 4:3")
            case .square: add("Aspect", "Square")
            case .unspecified: add("Aspect", "Not set")
            }
        }
        add("Columns", "\(file.columns)")
        add("Format", file.format.displayName)
        add("File Size", Self.formatSize(file.byteCount))
        self.hasSauce = file.sauce != nil
        self.rows = rows
    }

    static func formatDate(_ date: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", date.year ?? 0, date.month ?? 0, date.day ?? 0)
    }

    /// "1 byte", "12,345 bytes" (grouped with commas whatever the locale, like the rest of the UI).
    public static func formatSize(_ count: Int) -> String {
        var digits = String(count)
        var grouped = ""
        while digits.count > 3 {
            grouped = "," + digits.suffix(3) + grouped
            digits.removeLast(3)
        }
        return digits + grouped + (count == 1 ? " byte" : " bytes")
    }
}
