import Foundation

/// What the dialing panel shows.
public struct DialPanelStatus: Equatable {
    public var name: String
    public var address: String
    /// One based pass through the queue, of `passes`.
    public var attempt: Int
    public var passes: Int
    /// Zero based index in the queue, of `queueCount`.
    public var position: Int
    public var queueCount: Int
    /// "Connecting", "Busy, redialing" and so on.
    public var state: String
    /// Seconds dialing, or seconds left in a wait.
    public var seconds: Int
    /// 0...1 through a redial wait; nil while dialing.
    public var waitFraction: Double?

    public init(name: String, address: String, attempt: Int, passes: Int, position: Int, queueCount: Int,
                state: String, seconds: Int, waitFraction: Double?) {
        self.name = name
        self.address = address
        self.attempt = attempt
        self.passes = passes
        self.position = position
        self.queueCount = queueCount
        self.state = state
        self.seconds = seconds
        self.waitFraction = waitFraction
    }
}

/// The dialing panel as a DOS style text screen (an original design): a double line box in
/// bright cyan on blue, drawn by `AnsiRenderer` with the bitmap font.
public enum DialPanelScreen {
    public static let columns = 52
    public static let rows = 13
    static let title = " AnsiView Dialer "

    public static func make(_ status: DialPanelStatus) -> AnsiScreen {
        let blue = Palette.vga[1]
        let frame = Palette.vga[11]
        let label = Palette.vga[3]
        let value = Palette.vga[15]
        let highlight = Palette.vga[14]
        var grid = Array(repeating: Array(repeating: AnsiCell(code: 0x20, fg: value, bg: blue), count: columns), count: rows)

        func put(_ text: String, row: Int, column: Int, color: RGB, limit: Int? = nil) {
            let room = min(limit ?? Int.max, columns - 1 - column)
            for (offset, scalar) in text.unicodeScalars.prefix(max(0, room)).enumerated() {
                grid[row][column + offset] = AnsiCell(code: CP437.code(for: scalar) ?? 0x3F, fg: color, bg: blue)
            }
        }
        func box(_ code: UInt8, _ row: Int, _ column: Int) {
            grid[row][column] = AnsiCell(code: code, fg: frame, bg: blue)
        }

        for column in 1..<(columns - 1) {
            box(0xCD, 0, column)
            box(0xCD, rows - 1, column)
        }
        for row in 1..<(rows - 1) {
            box(0xBA, row, 0)
            box(0xBA, row, columns - 1)
        }
        box(0xC9, 0, 0); box(0xBB, 0, columns - 1)
        box(0xC8, rows - 1, 0); box(0xBC, rows - 1, columns - 1)
        put(title, row: 0, column: (columns - title.count) / 2, color: value)

        let left = 3
        let valueColumn = 13
        let width = columns - 1 - valueColumn - 2
        let lines: [(String, String, RGB)] = [
            ("BBS", status.name, value),
            ("Address", status.address, value),
            ("Attempt", "\(status.attempt) of \(status.passes)", value),
            ("Queue", "\(status.position + 1) of \(status.queueCount)", value),
            ("Status", status.state, highlight),
            (status.waitFraction == nil ? "Time" : "Redial in", "\(status.seconds) s", value),
        ]
        for (index, line) in lines.enumerated() {
            put(line.0 + ":", row: 2 + index, column: left, color: label)
            put(line.1, row: 2 + index, column: valueColumn, color: line.2, limit: width)
        }
        if let fraction = status.waitFraction {
            let barWidth = columns - 2 * left
            let filled = Int((min(1, max(0, fraction)) * Double(barWidth)).rounded())
            for column in 0..<barWidth {
                grid[9][left + column] = AnsiCell(code: column < filled ? 0xDB : 0xB0, fg: frame, bg: blue)
            }
        }
        put("Stop ends dialing.  Dial Now skips the wait.", row: 11, column: left, color: label)
        return AnsiScreen(columns: columns, rows: grid, title: "Dialing")
    }
}
