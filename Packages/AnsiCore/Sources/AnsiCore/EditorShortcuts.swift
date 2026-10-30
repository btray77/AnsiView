import Foundation

/// A key with modifiers. `key` is a lowercase character ("n", "'") or a named key ("insert",
/// "left", "f3", "return") (editor tools plan, ruling 13).
public struct KeyCombo: Hashable {
    public var key: String
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool

    public init(_ key: String, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    /// A single character key without modifiers: typed text in the Text tool, a shortcut elsewhere.
    public var isPlain: Bool { key.count == 1 && !control && !option && !command }

    private static let names: [UInt32: String] = {
        var map: [UInt32: String] = [0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right",
                                     0xF727: "insert", 0xF728: "forwarddelete", 0xF729: "home", 0xF72B: "end",
                                     0xF72C: "pageup", 0xF72D: "pagedown", 0xF746: "help",
                                     0x0D: "return", 0x03: "enter", 0x09: "tab", 0x7F: "delete", 0x1B: "escape", 0x20: "space"]
        for n in 1...20 { map[0xF703 + UInt32(n)] = "f\(n)" }
        return map
    }()

    private static let symbols: [String: String] = [
        "up": "↑", "down": "↓", "left": "←", "right": "→", "insert": "Insert", "forwarddelete": "⌦", "home": "Home",
        "end": "End", "pageup": "Page Up", "pagedown": "Page Down", "help": "Help", "return": "Return", "enter": "Enter",
        "tab": "Tab", "delete": "⌫", "escape": "Esc", "space": "Space",
    ]

    /// The key name for a character from a key event (`charactersIgnoringModifiers`).
    public static func keyName(scalar: UInt32) -> String {
        if let name = names[scalar] { return name }
        guard let s = Unicode.Scalar(scalar) else { return "" }
        return String(Character(s)).lowercased()
    }

    /// "⌃⇧N", "Insert", "⌥←".
    public var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        if let symbol = Self.symbols[key] { return text + symbol }
        return text + key.uppercased()
    }

    /// "ctrl+option+shift+n"
    public var storage: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("option") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    public init?(storage: String) {
        // The key itself may be "+", so split off modifiers from the front only.
        var rest = Substring(storage)
        var flags: Set<String> = []
        while let range = rest.range(of: "+"), rest.distance(from: rest.startIndex, to: range.lowerBound) > 0 {
            let part = String(rest[rest.startIndex..<range.lowerBound])
            guard ["ctrl", "option", "shift", "cmd"].contains(part) else { break }
            flags.insert(part)
            rest = rest[range.upperBound...]
        }
        let key = String(rest)
        guard !key.isEmpty, key.count == 1 || Self.symbols[key] != nil || key.hasPrefix("f") && Int(key.dropFirst()) != nil else {
            return nil
        }
        self.init(key, control: flags.contains("ctrl"), option: flags.contains("option"),
                  shift: flags.contains("shift"), command: flags.contains("cmd"))
    }
}

/// Everything the editor's keyboard can do through configurable shortcuts.
public enum EditorAction: String, CaseIterable {
    case toolDraw, toolSelect, toolLine, toolBox, toolFill, toolText, toolBrush, toolEyedropper
    case swapColours, toggleInsert, insertLine, deleteLine, insertColumn, deleteColumn
    case liftSelection, mirrorHorizontal, mirrorVertical, rotate180, rotateClockwise
    case characterPicker, nextLineStyle, toggleGrid

    public var title: String {
        switch self {
        case .toolDraw: return "Draw tool (half blocks)"
        case .toolSelect: return "Select tool"
        case .toolLine: return "Line tool (box lines)"
        case .toolBox: return "Box and shape tool"
        case .toolFill: return "Fill tool"
        case .toolText: return "Text tool"
        case .toolBrush: return "Brush tool"
        case .toolEyedropper: return "Eyedropper tool"
        case .swapColours: return "Swap foreground and background"
        case .toggleInsert: return "Insert / overwrite mode"
        case .insertLine: return "Insert line"
        case .deleteLine: return "Delete line"
        case .insertColumn: return "Insert column"
        case .deleteColumn: return "Delete column"
        case .liftSelection: return "Lift selection to move it"
        case .mirrorHorizontal: return "Mirror selection horizontally"
        case .mirrorVertical: return "Mirror selection vertically"
        case .rotate180: return "Rotate selection 180"
        case .rotateClockwise: return "Rotate selection 90 clockwise"
        case .characterPicker: return "Character picker"
        case .nextLineStyle: return "Next line style"
        case .toggleGrid: return "Show or hide the grid"
        }
    }

    public var hint: String {
        switch self {
        case .toolDraw: return "Paint half block pixels: left button foreground, right button background."
        case .toolSelect: return "Drag a rectangle; drag inside it to move it, Option-drag to move a copy."
        case .toolLine: return "Draw box lines that join: drag, or use the arrows; Option-arrows erase."
        case .toolBox: return "Drag a rectangle, line or ellipse in the chosen style."
        case .toolFill: return "Click to flood fill the connected area that matches the clicked cell."
        case .toolText: return "Click to place the cursor and type."
        case .toolBrush: return "Paint the brush character, or colours only, under the mouse."
        case .toolEyedropper: return "Click a cell to take its colours (Option-click also takes its character)."
        case .swapColours: return "Swaps the drawing colours (outside the Text tool)."
        case .toggleInsert: return "Insert shifts the row right as you type; overwrite replaces."
        case .insertLine: return "Inserts a blank row at the cursor."
        case .deleteLine: return "Deletes the cursor's row."
        case .insertColumn: return "Inserts a blank column at the cursor."
        case .deleteColumn: return "Deletes the cursor's column."
        case .liftSelection: return "Lifts the selection so arrows or the mouse move it; Return places it, Esc puts it back."
        case .mirrorHorizontal: return "Flips the selection left to right, remapping box and directional characters."
        case .mirrorVertical: return "Flips the selection top to bottom, remapping characters."
        case .rotate180: return "Turns the selection upside down, remapping characters."
        case .rotateClockwise: return "Turns the selection a quarter clockwise (when it fits)."
        case .characterPicker: return "Opens the CP437 character picker to choose the brush character."
        case .nextLineStyle: return "Cycles single, double and mixed line styles."
        case .toggleGrid: return "Shows lines between cells."
        }
    }

    public var defaultCombo: KeyCombo {
        switch self {
        case .toolDraw: return KeyCombo("d", control: true)
        case .toolSelect: return KeyCombo("s", control: true)
        case .toolLine: return KeyCombo("l", control: true)
        case .toolBox: return KeyCombo("b", control: true)
        case .toolFill: return KeyCombo("f", control: true)
        case .toolText: return KeyCombo("t", control: true)
        case .toolBrush: return KeyCombo("r", control: true)
        case .toolEyedropper: return KeyCombo("e", control: true)
        case .swapColours: return KeyCombo("x")
        case .toggleInsert: return KeyCombo("insert")
        case .insertLine: return KeyCombo("n", control: true)
        case .deleteLine: return KeyCombo("y", control: true)
        case .insertColumn: return KeyCombo("n", control: true, shift: true)
        case .deleteColumn: return KeyCombo("y", control: true, shift: true)
        case .liftSelection: return KeyCombo("g", control: true)
        case .mirrorHorizontal: return KeyCombo("h", control: true)
        case .mirrorVertical: return KeyCombo("v", control: true)
        case .rotate180: return KeyCombo("u", control: true)
        case .rotateClockwise: return KeyCombo("o", control: true)
        case .characterPicker: return KeyCombo("p", control: true)
        case .nextLineStyle: return KeyCombo("k", control: true)
        case .toggleGrid: return KeyCombo("'", control: true)
        }
    }
}

/// The user's shortcut choices: defaults plus overrides kept in defaults under `defaultsKey`.
public struct EditorShortcuts: Equatable {
    public static let defaultsKey = "EditorShortcuts"
    public private(set) var overrides: [EditorAction: KeyCombo] = [:]

    public init() {}

    public init(plist: [String: String]) {
        for (name, text) in plist {
            guard let action = EditorAction(rawValue: name), let combo = KeyCombo(storage: text) else { continue }
            if combo != action.defaultCombo { overrides[action] = combo }
        }
    }

    public var plist: [String: String] {
        Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value.storage) })
    }

    public func combo(for action: EditorAction) -> KeyCombo { overrides[action] ?? action.defaultCombo }

    /// The action a key runs (the first in list order when two share it).
    public func action(for combo: KeyCombo) -> EditorAction? {
        EditorAction.allCases.first { self.combo(for: $0) == combo }
    }

    /// Keys used by more than one action.
    public var conflicts: [KeyCombo: [EditorAction]] {
        var byCombo: [KeyCombo: [EditorAction]] = [:]
        for action in EditorAction.allCases { byCombo[combo(for: action), default: []].append(action) }
        return byCombo.filter { $0.value.count > 1 }
    }

    /// The other actions sharing `action`'s key.
    public func conflicts(for action: EditorAction) -> [EditorAction] {
        let key = combo(for: action)
        return EditorAction.allCases.filter { $0 != action && combo(for: $0) == key }
    }

    public mutating func set(_ combo: KeyCombo, for action: EditorAction) {
        overrides[action] = combo == action.defaultCombo ? nil : combo
    }

    public mutating func reset(_ action: EditorAction) { overrides[action] = nil }
    public mutating func resetAll() { overrides = [:] }
}
