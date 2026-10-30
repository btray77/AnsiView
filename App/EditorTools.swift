import AnsiCore
import AppKit

/// The editor's tools (editor tools plan, ruling 14). Draw and Select keep their plan 6 numbers.
enum EditorTool: Int, CaseIterable {
    case draw, select, line, box, fill, text, brush, eyedropper

    var title: String {
        switch self {
        case .draw: return "Draw"
        case .select: return "Select"
        case .line: return "Line"
        case .box: return "Box"
        case .fill: return "Fill"
        case .text: return "Text"
        case .brush: return "Brush"
        case .eyedropper: return "Eyedropper"
        }
    }

    var symbolName: String {
        switch self {
        case .draw: return "pencil.tip"
        case .select: return "rectangle.dashed"
        case .line: return "point.topleft.down.to.point.bottomright.curvepath"
        case .box: return "square"
        case .fill: return "drop.fill"
        case .text: return "character.cursor.ibeam"
        case .brush: return "paintbrush.pointed"
        case .eyedropper: return "eyedropper"
        }
    }

    var action: EditorAction {
        switch self {
        case .draw: return .toolDraw
        case .select: return .toolSelect
        case .line: return .toolLine
        case .box: return .toolBox
        case .fill: return .toolFill
        case .text: return .toolText
        case .brush: return .toolBrush
        case .eyedropper: return .toolEyedropper
        }
    }

    var hint: String { action.hint }

    func tooltip(_ shortcuts: EditorShortcuts) -> String {
        "\(title) tool (\(shortcuts.combo(for: action).display)): \(hint)"
    }

    var cursor: NSCursor {
        switch self {
        case .text: return .iBeam
        case .select, .eyedropper: return .arrow
        default: return .crosshair
        }
    }
}

/// Plan 6 called the tools modes; the harnesses and older code still say `EditorMode`.
typealias EditorMode = EditorTool

/// What the Box tool draws.
enum ShapeKind: Int, CaseIterable {
    case rectangle, line, ellipse
    var title: String { ["Rectangle", "Line", "Ellipse"][rawValue] }
}

/// The styles offered for boxes and straight lines.
enum BoxStyleChoice: Int, CaseIterable {
    case single, double, singleHDoubleV, doubleHSingleV, solid, halfBlock, light, medium, dark, brushCharacter

    var title: String {
        switch self {
        case .single: return "Single ┌─┐"
        case .double: return "Double ╔═╗"
        case .singleHDoubleV: return "Single across, double down ╓─╖"
        case .doubleHSingleV: return "Double across, single down ╒═╕"
        case .solid: return "Solid █"
        case .halfBlock: return "Half blocks ▀▄▌▐"
        case .light: return "Light shade ░"
        case .medium: return "Medium shade ▒"
        case .dark: return "Dark shade ▓"
        case .brushCharacter: return "Brush character"
        }
    }

    func style(brush: UInt8) -> ShapeStyle {
        switch self {
        case .single: return .line(.single)
        case .double: return .line(.double)
        case .singleHDoubleV: return .line(.singleHDoubleV)
        case .doubleHSingleV: return .line(.doubleHSingleV)
        case .solid: return .solid
        case .halfBlock: return .halfBlock
        case .light: return .shade(1)
        case .medium: return .shade(2)
        case .dark: return .shade(3)
        case .brushCharacter: return .character(brush)
        }
    }
}

/// Tool options chosen in the options bar.
struct ToolSettings {
    var lineStyle = LineStyle.single
    var shape = ShapeKind.rectangle
    var boxStyle = BoxStyleChoice.single
    var filled = false
    var fillWithBrush = false
    var shadow = false
    var title = ""
    var fillMatch = CellParts.both
    var fillApply = CellParts.both
    var colourOnlyBrush = false
    var leaveCopy = false
}

/// Keyboard shortcuts kept in the user's defaults (ruling 13).
final class ShortcutStore {
    static let shared = ShortcutStore()
    static let changed = Notification.Name("EditorShortcutsChanged")
    var defaults = UserDefaults.standard

    private(set) lazy var shortcuts: EditorShortcuts = load()

    private func load() -> EditorShortcuts {
        EditorShortcuts(plist: defaults.dictionary(forKey: EditorShortcuts.defaultsKey) as? [String: String] ?? [:])
    }

    func update(_ change: (inout EditorShortcuts) -> Void) {
        change(&shortcuts)
        defaults.set(shortcuts.plist, forKey: EditorShortcuts.defaultsKey)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

/// The native look or the retro DOS look (blue chrome, yellow and white text).
enum EditorTheme: String {
    case native, retro
    static let defaultsKey = "EditorTheme"

    static var current: EditorTheme {
        get { EditorTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .native }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    static let dosBlue = NSColor(srgbRed: 0, green: 0, blue: 170 / 255, alpha: 1)
    static let dosYellow = NSColor(srgbRed: 1, green: 1, blue: 85 / 255, alpha: 1)
    static let dosCyan = NSColor(srgbRed: 85 / 255, green: 1, blue: 1, alpha: 1)
}

/// Shows a control's tooltip in the status bar while the mouse is over it ("hints everywhere").
final class HintTracker: NSResponder {
    var show: ((String?) -> Void)?
    private var tracked: [ObjectIdentifier: NSTrackingArea] = [:]

    /// Adds tracking to every view under `root` that has a tooltip.
    func track(_ root: NSView) {
        if let tip = root.toolTip, !tip.isEmpty {
            if let old = tracked[ObjectIdentifier(root)] { root.removeTrackingArea(old) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: ["hint": tip])
            root.addTrackingArea(area)
            tracked[ObjectIdentifier(root)] = area
        }
        for sub in root.subviews { track(sub) }
    }

    override func mouseEntered(with event: NSEvent) { show?(event.trackingArea?.userInfo?["hint"] as? String) }
    override func mouseExited(with event: NSEvent) { show?(nil) }
}

/// The vertical tool palette.
final class ToolPaletteView: NSStackView {
    var onPick: ((EditorTool) -> Void)?
    private(set) var buttons: [NSButton] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        for tool in EditorTool.allCases {
            let image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title)
                ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: tool.title)!
            let button = NSButton(image: image, target: self, action: #selector(clicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .regularSquare
            button.tag = tool.rawValue
            button.setAccessibilityLabel("\(tool.title) tool")
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 34), button.heightAnchor.constraint(equalToConstant: 30)])
            buttons.append(button)
            addArrangedSubview(button)
        }
        refreshTooltips()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func refreshTooltips() {
        let shortcuts = ShortcutStore.shared.shortcuts
        for button in buttons { button.toolTip = EditorTool(rawValue: button.tag)!.tooltip(shortcuts) }
    }

    func select(_ tool: EditorTool) {
        for button in buttons { button.state = button.tag == tool.rawValue ? .on : .off }
    }

    @objc private func clicked(_ sender: NSButton) {
        onPick?(EditorTool(rawValue: sender.tag) ?? .draw)
    }
}

/// Options for the current tool, in one row under the palette bar.
final class ToolOptionsBar: NSStackView {
    var settings = ToolSettings()
    var onChange: (() -> Void)?
    var onPickCharacter: (() -> Void)?

    let lineStylePopup = NSPopUpButton()
    let shapeControl = NSSegmentedControl(labels: ShapeKind.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let boxStylePopup = NSPopUpButton()
    let filledBox = NSButton(checkboxWithTitle: "Filled", target: nil, action: nil)
    let fillBrushBox = NSButton(checkboxWithTitle: "with brush character", target: nil, action: nil)
    let shadowBox = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
    let titleField = NSTextField(string: "")
    let matchPopup = NSPopUpButton()
    let applyPopup = NSPopUpButton()
    let brushKind = NSSegmentedControl(labels: ["Character", "Colour only"], trackingMode: .selectOne, target: nil, action: nil)
    let characterButton = NSButton(title: "█", target: nil, action: nil)
    let leaveCopyBox = NSButton(checkboxWithTitle: "Leave a copy when moving", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")

    private static let partChoices: [(String, CellParts)] = [("character and colour", .both), ("character", .character), ("colour", .colour)]

    init() {
        super.init(frame: .zero)
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 4, right: 10)
        lineStylePopup.addItems(withTitles: LineStyle.allCases.map(\.label))
        lineStylePopup.toolTip = "Line style for the Line tool (next style: \(ShortcutStore.shared.shortcuts.combo(for: .nextLineStyle).display))"
        shapeControl.selectedSegment = 0
        shapeControl.toolTip = "Shape the Box tool drags out: a rectangle, a straight line, or an ellipse in half blocks"
        boxStylePopup.addItems(withTitles: BoxStyleChoice.allCases.map(\.title))
        boxStylePopup.toolTip = "Edge style: box lines join with lines already drawn; blocks and shades draw over"
        filledBox.toolTip = "Fill the inside of the rectangle"
        fillBrushBox.toolTip = "Fill with the brush character instead of spaces in the background colour"
        shadowBox.toolTip = "Add a TheDraw style drop shadow (darkens the cells right of and below the box)"
        titleField.placeholderString = "Title"
        titleField.toolTip = "Text written into the top edge of the box"
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        matchPopup.addItems(withTitles: Self.partChoices.map { "Match \($0.0)" })
        matchPopup.toolTip = "Which neighbours the fill spreads to: same character and colour, same character, or same colour"
        applyPopup.addItems(withTitles: Self.partChoices.map { "Fill \($0.0)" })
        applyPopup.toolTip = "What the fill changes: character and colours, the character only, or the colours only"
        brushKind.selectedSegment = 0
        brushKind.toolTip = "Paint the brush character with the colours, or only recolour the cells"
        characterButton.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        characterButton.toolTip = "The brush character: click to open the CP437 character picker (\(ShortcutStore.shared.shortcuts.combo(for: .characterPicker).display))"
        leaveCopyBox.toolTip = "Moving a selection keeps the original in place (Option-drag does this once)"
        for control in [lineStylePopup, shapeControl, boxStylePopup, filledBox, fillBrushBox, shadowBox, titleField,
                         matchPopup, applyPopup, brushKind, characterButton, leaveCopyBox] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        characterButton.action = #selector(pickCharacter(_:))
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        for view in [label, lineStylePopup, shapeControl, boxStylePopup, filledBox, fillBrushBox, shadowBox, titleField,
                     matchPopup, applyPopup, brushKind, characterButton, leaveCopyBox] as [NSView] { addArrangedSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the controls that apply to `tool`.
    func show(for tool: EditorTool, brush: UInt8) {
        label.stringValue = "\(tool.title):"
        let visible: [NSView]
        switch tool {
        case .line: visible = [lineStylePopup]
        case .box: visible = [shapeControl, boxStylePopup, filledBox, fillBrushBox, shadowBox, titleField, characterButton]
        case .fill: visible = [matchPopup, applyPopup, characterButton]
        case .brush: visible = [brushKind, characterButton]
        case .select: visible = [leaveCopyBox]
        default: visible = []
        }
        for view in arrangedSubviews where view !== label { view.isHidden = !visible.contains { $0 === view } }
        let rectangle = settings.shape == .rectangle
        filledBox.isEnabled = rectangle
        fillBrushBox.isEnabled = rectangle && settings.filled
        shadowBox.isEnabled = rectangle
        titleField.isEnabled = rectangle
        characterButton.title = String(Character(CP437.unicode[Int(brush)]))
    }

    @objc private func changed(_ sender: Any?) {
        settings.lineStyle = LineStyle.allCases[max(0, lineStylePopup.indexOfSelectedItem)]
        settings.shape = ShapeKind(rawValue: max(0, shapeControl.selectedSegment)) ?? .rectangle
        settings.boxStyle = BoxStyleChoice(rawValue: max(0, boxStylePopup.indexOfSelectedItem)) ?? .single
        settings.filled = filledBox.state == .on
        settings.fillWithBrush = fillBrushBox.state == .on
        settings.shadow = shadowBox.state == .on
        settings.title = titleField.stringValue
        settings.fillMatch = Self.partChoices[max(0, matchPopup.indexOfSelectedItem)].1
        settings.fillApply = Self.partChoices[max(0, applyPopup.indexOfSelectedItem)].1
        settings.colourOnlyBrush = brushKind.selectedSegment == 1
        settings.leaveCopy = leaveCopyBox.state == .on
        onChange?()
    }

    /// Sets the line style from a shortcut.
    func setLineStyle(_ style: LineStyle) {
        lineStylePopup.selectItem(at: LineStyle.allCases.firstIndex(of: style) ?? 0)
        changed(nil)
    }

    @objc private func pickCharacter(_ sender: Any?) { onPickCharacter?() }
}
