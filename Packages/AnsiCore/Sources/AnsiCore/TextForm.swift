import Foundation

/// Keys a retro text screen understands (the app maps key events to these).
public enum FormKey: Equatable {
    case up, down, left, right, enter, escape, tab, backTab, backspace, forwardDelete
    case home, end, pageUp, pageDown
    /// Option-Up and Option-Down: move the selected row (directory only).
    case moveUp, moveDown
    case character(Character)
}

public enum FormEvent: Equatable {
    case none
    /// A field's value changed.
    case changed(String)
    /// An action field was pressed.
    case activated(String)
    /// Esc: save and go back.
    case done
}

/// One field of a `TextForm`.
public struct FormField: Equatable {
    public enum Kind: Equatable {
        case text(maxLength: Int)
        /// Shown as stars unless a toggle with `revealsSecrets` is on.
        case secret(maxLength: Int)
        case number(ClosedRange<Int>)
        case choice([String])
        case toggle
        case action
    }

    public var id: String
    public var section: String
    public var label: String
    /// One or two plain sentences shown under the form while the field is selected.
    public var hint: String
    public var kind: Kind
    /// The value of text, secret and number fields, or an action's caption.
    public var text: String
    /// The chosen option of a choice field.
    public var index: Int
    public var isOn: Bool
    /// A toggle that shows secret fields while on.
    public var revealsSecrets: Bool

    public init(id: String, section: String, label: String, hint: String, kind: Kind, text: String = "",
                index: Int = 0, isOn: Bool = false, revealsSecrets: Bool = false) {
        self.id = id
        self.section = section
        self.label = label
        self.hint = hint
        self.kind = kind
        self.text = text
        self.index = index
        self.isOn = isOn
        self.revealsSecrets = revealsSecrets
    }

    public static func text(_ id: String, section: String, label: String, hint: String, value: String,
                            maxLength: Int = 120) -> FormField {
        FormField(id: id, section: section, label: label, hint: hint, kind: .text(maxLength: maxLength), text: value)
    }

    public static func secret(_ id: String, section: String, label: String, hint: String, value: String,
                              maxLength: Int = 120) -> FormField {
        FormField(id: id, section: section, label: label, hint: hint, kind: .secret(maxLength: maxLength), text: value)
    }

    public static func number(_ id: String, section: String, label: String, hint: String, value: Int,
                              range: ClosedRange<Int>) -> FormField {
        FormField(id: id, section: section, label: label, hint: hint, kind: .number(range), text: String(value))
    }

    public static func choice(_ id: String, section: String, label: String, hint: String, options: [String],
                              index: Int) -> FormField {
        FormField(id: id, section: section, label: label, hint: hint, kind: .choice(options),
                  index: options.indices.contains(index) ? index : 0)
    }

    public static func toggle(_ id: String, section: String, label: String, hint: String, isOn: Bool,
                              revealsSecrets: Bool = false) -> FormField {
        FormField(id: id, section: section, label: label, hint: hint, kind: .toggle, isOn: isOn, revealsSecrets: revealsSecrets)
    }

    public static func action(_ id: String, section: String, label: String, hint: String, caption: String) -> FormField {
        FormField(id: id, section: section, label: label, hint: hint, kind: .action, text: caption)
    }

    /// A number field's value, clamped.
    public var number: Int {
        guard case .number(let range) = kind else { return Int(text) ?? 0 }
        return min(range.upperBound, max(range.lowerBound, Int(text) ?? range.lowerBound))
    }

    public var choiceValue: String {
        guard case .choice(let options) = kind, options.indices.contains(index) else { return "" }
        return options[index]
    }

    var editsText: Bool {
        switch kind {
        case .text, .secret, .number: return true
        default: return false
        }
    }
}

/// A keyboard driven form drawn as a DOS style text screen (ruling 14): Up/Down moves between
/// fields, Enter goes to the next, Left/Right toggles or cycles, Esc saves and goes back.
public struct TextForm {
    public var title: String
    public var fields: [FormField]
    /// A line under the hint (for the editor: last called and times called).
    public var info: String
    public private(set) var selected = 0
    /// Character position in the selected text field.
    public private(set) var caret = 0

    public init(title: String, fields: [FormField], info: String) {
        self.title = title
        self.fields = fields
        self.info = info
        caret = fields.first.map { $0.text.count } ?? 0
    }

    public func field(_ id: String) -> FormField? { fields.first { $0.id == id } }

    public var revealSecrets: Bool { fields.contains { $0.revealsSecrets && $0.isOn } }

    public mutating func select(id: String) {
        if let index = fields.firstIndex(where: { $0.id == id }) { select(index: index) }
    }

    public mutating func select(index: Int) {
        guard !fields.isEmpty else { return }
        commitNumber()
        selected = min(fields.count - 1, max(0, index))
        caret = fields[selected].text.count
    }

    public mutating func handle(_ key: FormKey) -> FormEvent {
        guard !fields.isEmpty else { return key == .escape ? .done : .none }
        let field = fields[selected]
        switch key {
        case .up, .backTab: select(index: selected - 1)
        case .down, .tab: select(index: selected + 1)
        case .pageUp: select(index: selected - 10)
        case .pageDown: select(index: selected + 10)
        case .enter:
            if field.kind == .action { return .activated(field.id) }
            select(index: selected + 1)
        case .escape:
            commitNumber()
            return .done
        case .left, .right:
            let step = key == .right ? 1 : -1
            switch field.kind {
            case .choice(let options):
                guard !options.isEmpty else { return .none }
                fields[selected].index = (field.index + step + options.count) % options.count
                return .changed(field.id)
            case .toggle:
                fields[selected].isOn.toggle()
                return .changed(field.id)
            case .number(let range):
                let value = min(range.upperBound, max(range.lowerBound, field.number + step))
                guard value != Int(field.text) else { return .none }
                fields[selected].text = String(value)
                caret = fields[selected].text.count
                return .changed(field.id)
            case .text, .secret:
                caret = min(field.text.count, max(0, caret + step))
            case .action: break
            }
        case .home: if field.editsText { caret = 0 }
        case .end: if field.editsText { caret = field.text.count }
        case .backspace:
            guard field.editsText, caret > 0 else { return .none }
            var chars = Array(field.text)
            chars.remove(at: caret - 1)
            caret -= 1
            fields[selected].text = String(chars)
            return .changed(field.id)
        case .forwardDelete:
            guard field.editsText, caret < field.text.count else { return .none }
            var chars = Array(field.text)
            chars.remove(at: caret)
            fields[selected].text = String(chars)
            return .changed(field.id)
        case .character(let c):
            return type(c)
        case .moveUp, .moveDown: break
        }
        return .none
    }

    /// A mouse click on a screen row: the first click selects, a click on the selected field
    /// cycles a choice, flips a toggle or presses an action.
    public mutating func click(row: Int, map: [Int: Int]) -> FormEvent {
        guard let index = map[row], fields.indices.contains(index) else { return .none }
        guard index == selected else {
            select(index: index)
            return .none
        }
        switch fields[index].kind {
        case .choice, .toggle: return handle(.right)
        case .action: return .activated(fields[index].id)
        default: return .none
        }
    }

    private mutating func type(_ c: Character) -> FormEvent {
        let field = fields[selected]
        let printable = c.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
        guard printable else { return .none }
        switch field.kind {
        case .text(let max), .secret(let max):
            guard field.text.count < max else { return .none }
            var chars = Array(field.text)
            chars.insert(c, at: caret)
            caret += 1
            fields[selected].text = String(chars)
            return .changed(field.id)
        case .number:
            guard c.isASCII, c.isNumber, field.text.count < 6 else { return .none }
            fields[selected].text = (field.text == "0" ? "" : field.text) + String(c)
            caret = fields[selected].text.count
            return .changed(field.id)
        case .choice, .toggle:
            return c == " " ? handle(.right) : .none
        case .action:
            return c == " " ? .activated(field.id) : .none
        }
    }

    /// Clamps a number being typed when the selection leaves it.
    private mutating func commitNumber() {
        guard fields.indices.contains(selected), case .number = fields[selected].kind else { return }
        fields[selected].text = String(fields[selected].number)
    }

    // MARK: Screen

    public struct Rendered {
        public var screen: AnsiScreen
        /// Screen row to field index, for mouse clicks.
        public var fieldAtRow: [Int: Int]
    }

    static let keysLine = " \u{18}\u{19} Field  Enter Next  \u{1B}\u{1A} Change  Space Toggle  Esc Save and back "

    public func screen(columns: Int = 80, rows: Int = 25) -> Rendered {
        var canvas = RetroCanvas(columns: columns, rows: rows)
        canvas.frame(title: title)
        let contentTop = 1
        let contentRows = max(1, rows - 6)
        enum Line { case heading(String), field(Int), blank }
        var lines: [Line] = []
        var lastSection: String?
        for (index, field) in fields.enumerated() {
            if field.section != lastSection {
                if lastSection != nil { lines.append(.blank) }
                lines.append(.heading(field.section))
                lastSection = field.section
            }
            lines.append(.field(index))
        }
        let selectedLine = lines.firstIndex { if case .field(let i) = $0 { return i == selected }; return false } ?? 0
        let top = (selectedLine / contentRows) * contentRows
        var map: [Int: Int] = [:]
        let labelColumn = 3
        let valueColumn = 30
        let valueWidth = max(4, columns - valueColumn - 2)
        let reveal = revealSecrets
        for (offset, line) in lines.dropFirst(top).prefix(contentRows).enumerated() {
            let row = contentTop + offset
            switch line {
            case .blank: break
            case .heading(let name):
                canvas.put(String(repeating: "\u{2500}", count: 2) + " ", row: row, column: 2, fg: RetroCanvas.frameColor)
                canvas.put(name, row: row, column: 5, fg: Palette.vga[14])
                let after = 5 + name.count + 1
                canvas.put(String(repeating: "\u{2500}", count: max(0, columns - 3 - after)), row: row, column: after,
                           fg: RetroCanvas.frameColor)
            case .field(let index):
                map[row] = index
                let field = fields[index]
                let isSelected = index == selected
                let dots = String(repeating: ".", count: max(0, valueColumn - labelColumn - field.label.count - 2))
                canvas.put(field.label, row: row, column: labelColumn, fg: Palette.vga[isSelected ? 11 : 3])
                canvas.put(" " + dots, row: row, column: labelColumn + field.label.count, fg: Palette.vga[8])
                let (shown, caretColumn) = display(field, selected: isSelected, width: valueWidth, reveal: reveal)
                let fg = isSelected ? Palette.vga[0] : Palette.vga[7]
                let bg = isSelected ? Palette.vga[3] : Palette.vga[0]
                if isSelected { canvas.fill(row: row, column: valueColumn, count: valueWidth, bg: bg) }
                canvas.put(shown, row: row, column: valueColumn, fg: fg, bg: bg)
                if let caretColumn, caretColumn < valueWidth {
                    canvas.highlight(row: row, column: valueColumn + caretColumn, fg: Palette.vga[3], bg: Palette.vga[15])
                }
            }
        }
        if top > 0 { canvas.put("\u{18}", row: contentTop, column: columns - 1, fg: Palette.vga[14]) }
        if top + contentRows < lines.count { canvas.put("\u{19}", row: contentTop + contentRows - 1, column: columns - 1, fg: Palette.vga[14]) }
        canvas.divider(row: rows - 5)
        let hint = fields.indices.contains(selected) ? fields[selected].hint : ""
        for (offset, line) in RetroCanvas.wrap(hint, width: columns - 6).prefix(2).enumerated() {
            canvas.put(line, row: rows - 4 + offset, column: 3, fg: Palette.vga[15])
        }
        canvas.put(info, row: rows - 2, column: 3, fg: Palette.vga[7])
        canvas.footer(Self.keysLine)
        return Rendered(screen: canvas.screen(title: title), fieldAtRow: map)
    }

    /// The text shown for a field and the caret's offset in it.
    private func display(_ field: FormField, selected: Bool, width: Int, reveal: Bool) -> (String, Int?) {
        switch field.kind {
        case .text, .secret, .number:
            var text = field.text
            if case .secret = field.kind, !reveal { text = String(repeating: "*", count: text.count) }
            let caretAt = selected ? caret : text.count
            let start = max(0, caretAt - (width - 1))
            let window = String(Array(text).dropFirst(start).prefix(width))
            return (window, selected ? caretAt - start : nil)
        case .choice:
            return (selected ? "\u{11} \(field.choiceValue) \u{10}" : field.choiceValue, nil)
        case .toggle:
            return (field.isOn ? "[\u{221A}] On" : "[ ] Off", nil)
        case .action:
            return ("[ \(field.text) ]", nil)
        }
    }
}

/// Draws the retro screens: blue double line frame on black, text in DOS colours.
public struct RetroCanvas {
    public static let frameColor = Palette.vga[9]
    public let columns: Int
    public let rows: Int
    public var grid: [[AnsiCell]]

    public init(columns: Int, rows: Int, bg: RGB = Palette.vga[0]) {
        self.columns = columns
        self.rows = rows
        grid = Array(repeating: Array(repeating: AnsiCell(code: 0x20, fg: Palette.vga[7], bg: bg), count: columns), count: rows)
    }

    /// Writes text clipped to the inside of the frame. Characters without a CP437 code show "?".
    public mutating func put(_ text: String, row: Int, column: Int, fg: RGB, bg: RGB? = nil, limit: Int? = nil) {
        guard grid.indices.contains(row) else { return }
        var col = column
        let end = min(columns - 1, column + (limit ?? columns))
        for scalar in text.unicodeScalars {
            guard col < end else { break }
            if col >= 0 {
                let code: UInt8 = scalar.value < 0x20 ? UInt8(scalar.value) : (CP437.code(for: scalar) ?? 0x3F)
                grid[row][col] = AnsiCell(code: code, fg: fg, bg: bg ?? grid[row][col].bg)
            }
            col += 1
        }
    }

    public mutating func fill(row: Int, column: Int, count: Int, bg: RGB) {
        guard grid.indices.contains(row) else { return }
        for col in max(0, column)..<min(columns - 1, column + count) {
            grid[row][col] = AnsiCell(code: 0x20, fg: Palette.vga[7], bg: bg)
        }
    }

    public mutating func highlight(row: Int, column: Int, fg: RGB, bg: RGB) {
        guard grid.indices.contains(row), (0..<columns).contains(column) else { return }
        grid[row][column].fg = fg
        grid[row][column].bg = bg
    }

    public mutating func frame(title: String) {
        let color = Self.frameColor
        for col in 1..<(columns - 1) {
            grid[0][col] = AnsiCell(code: 0xCD, fg: color)
            grid[rows - 1][col] = AnsiCell(code: 0xCD, fg: color)
        }
        for row in 1..<(rows - 1) {
            grid[row][0] = AnsiCell(code: 0xBA, fg: color)
            grid[row][columns - 1] = AnsiCell(code: 0xBA, fg: color)
        }
        grid[0][0] = AnsiCell(code: 0xC9, fg: color)
        grid[0][columns - 1] = AnsiCell(code: 0xBB, fg: color)
        grid[rows - 1][0] = AnsiCell(code: 0xC8, fg: color)
        grid[rows - 1][columns - 1] = AnsiCell(code: 0xBC, fg: color)
        let label = " \(title) "
        put(label, row: 0, column: max(1, (columns - label.count) / 2), fg: Palette.vga[15])
    }

    /// A single line divider joined to the frame.
    public mutating func divider(row: Int) {
        guard grid.indices.contains(row) else { return }
        for col in 1..<(columns - 1) { grid[row][col] = AnsiCell(code: 0xC4, fg: Self.frameColor) }
        grid[row][0] = AnsiCell(code: 0xC7, fg: Self.frameColor)
        grid[row][columns - 1] = AnsiCell(code: 0xB6, fg: Self.frameColor)
    }

    /// Key help on the bottom border.
    public mutating func footer(_ keys: String) {
        put(keys, row: rows - 1, column: max(1, (columns - keys.count) / 2), fg: Palette.vga[14])
    }

    public func screen(title: String?) -> AnsiScreen {
        AnsiScreen(columns: columns, rows: grid, title: title)
    }

    /// Word wraps plain text to `width` columns.
    public static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
