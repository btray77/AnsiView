import Foundation

/// A caller's screen size for Preview as Caller.
public struct CallerTerminalSize: Equatable, Hashable, Codable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    public var label: String { "\(columns) x \(rows)" }

    /// 80 x 24 (a VT100 style terminal), 80 x 25 (a DOS screen) and 132 x 37.
    public static let presets = [CallerTerminalSize(columns: 80, rows: 24), CallerTerminalSize(columns: 80, rows: 25),
                                 CallerTerminalSize(columns: 132, rows: 37)]
}

/// Something about a screen that a caller may see differently from the editor.
public struct PreviewWarning: Equatable {
    public enum Kind: String, Equatable, CaseIterable {
        case lineTooLong, wrapAtLastColumn, bottomRightScroll, tallerThanScreen, unsupportedCode, needsIce, encodingUndocumented, noColourCodes,
             notRepresentable, animatedAsANSI
    }

    public var kind: Kind
    /// The line of the sent screen it is about (1 based), when it is about one line.
    public var row: Int?
    public var message: String

    public init(kind: Kind, row: Int? = nil, message: String) {
        self.kind = kind
        self.row = row
        self.message = message
    }

    /// The (?) text for this kind of warning.
    public var help: String { ScreenDesignerHelp.warning(kind) }
}

/// Size, time and layout checks for Preview as Caller (screen designer ruling 9).
public enum CallerPreviewAnalysis {
    /// Seconds a caller waits for `bytes` at `baud` (8N1: 10 bits per character); 0 for unlimited.
    public static func displaySeconds(bytes: Int, baud: Int) -> Double {
        baud > 0 ? Double(bytes) * Double(PaddingDelay.bitsPerCharacter) / Double(baud) : 0
    }

    /// "4.2 KB, 17.6 s at 2400 baud".
    public static func sizeLine(bytes: Int, baud: Int) -> String {
        let size = bytes < 1024 ? "\(bytes) bytes" : String(format: "%.1f KB", Double(bytes) / 1024)
        guard baud > 0 else { return "\(size), shown at once (unlimited speed)" }
        return String(format: "%@, %.1f s at %d baud", size, displaySeconds(bytes: bytes, baud: baud), baud)
    }

    /// Follows the cursor through the stream a BBS sends (text, CR, LF, backspace and the ANSI
    /// cursor commands) and reports what a terminal that wraps at once (ANSI.SYS) does with it.
    /// Reading stops at the DOS end of file (0x1A), where SAUCE starts.
    public static func layoutWarnings(_ stream: [UInt8], size: CallerTerminalSize) -> [PreviewWarning] {
        let width = max(1, size.columns), height = max(1, size.rows)
        var warnings: [PreviewWarning] = []
        var row = 0, column = 0, line = 1
        var saved = (0, 0)
        var reportedLong: Set<Int> = [], reportedWrap: Set<Int> = []
        var scrolled = false, corner = false
        func scrollCheck() {
            if row >= height, !scrolled {
                scrolled = true
                warnings.append(PreviewWarning(kind: .tallerThanScreen, row: line, message:
                    "The screen goes past row \(height) of a \(size.label) terminal; the top scrolls away."))
            }
        }
        var i = 0
        while i < stream.count {
            let b = stream[i]
            if b == 0x1A { break }
            if b == 0x1B {
                // CSI: ESC [ parameters final; other escapes are two bytes.
                guard i + 1 < stream.count, stream[i + 1] == 0x5B else { i += 2; continue }
                var j = i + 2
                while j < stream.count, !(0x40...0x7E).contains(stream[j]) { j += 1 }
                guard j < stream.count else { break }
                let params = String(decoding: stream[(i + 2)..<j], as: UTF8.self)
                    .split(separator: ";", omittingEmptySubsequences: false).map { Int($0.filter(\.isNumber)) }
                func p(_ index: Int, _ fallback: Int) -> Int { max(1, (index < params.count ? params[index] : nil) ?? fallback) }
                switch stream[j] {
                case 0x48, 0x66: row = min(height - 1, p(0, 1) - 1); column = min(width - 1, p(1, 1) - 1)
                case 0x41: row = max(0, row - p(0, 1))
                case 0x42: row = min(height - 1, row + p(0, 1))
                case 0x43: column = min(width - 1, column + p(0, 1))
                case 0x44: column = max(0, column - p(0, 1))
                case 0x4A where (params.first ?? 0) == 2: row = 0; column = 0
                case 0x73: saved = (row, column)
                case 0x75: (row, column) = saved
                default: break
                }
                i = j + 1
                continue
            }
            switch b {
            case 0x0D, 0x0A:
                if column >= width, !reportedWrap.contains(line), !reportedLong.contains(line) {
                    reportedWrap.insert(line)
                    warnings.append(PreviewWarning(kind: .wrapAtLastColumn, row: line, message:
                        "Line \(line) fills all \(width) columns and then starts a new line; terminals that wrap at once show an extra blank line."))
                }
                if b == 0x0D { column = 0 } else {
                    row += 1
                    line += 1
                    scrollCheck()
                }
            case 0x08:
                column = max(0, min(width, column) - 1)
            case 0x00..<0x20, 0x7F:
                break
            default:
                if column >= width {
                    if !reportedLong.contains(line) {
                        reportedLong.insert(line)
                        warnings.append(PreviewWarning(kind: .lineTooLong, row: line, message:
                            "Line \(line) is longer than \(width) columns; the rest wraps onto the next row."))
                    }
                    row += 1
                    column = 0
                    scrollCheck()
                }
                if row == height - 1, column == width - 1, !corner, !scrolled {
                    corner = true
                    warnings.append(PreviewWarning(kind: .bottomRightScroll, row: line, message:
                        "A character lands in the bottom right cell (row \(height), column \(width)); most terminals scroll the screen up one row."))
                }
                column += 1
            }
            i += 1
        }
        return warnings
    }
}
