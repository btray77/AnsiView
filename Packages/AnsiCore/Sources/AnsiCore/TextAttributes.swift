/// The character attributes set by SGR (`ESC[...m`), shared by the file player's `AnsiTerminal`
/// and the BBS terminal's `TerminalEmulator`.
struct TextAttributes: Equatable {
    /// A color as set by escape codes: a classic ANSI index (0-7, brightened by bold) or an exact color.
    enum ColorSpec: Equatable { case index(Int), rgb(RGB) }

    var fg = ColorSpec.index(7)
    var bg = ColorSpec.index(0)
    var bold = false
    var blink = false
    var inverse = false
    var brightFG = false
    var brightBG = false

    /// The cell colors. With iCE colors, blink brightens the background instead of blinking.
    func colors(iceColors: Bool) -> (fg: RGB, bg: RGB) {
        var f: RGB, b: RGB
        switch fg {
        case .index(let i): f = Palette.vga[Palette.ansiToVGA[i] + (bold || brightFG ? 8 : 0)]
        case .rgb(let color): f = color
        }
        switch bg {
        case .index(let i): b = Palette.vga[Palette.ansiToVGA[i] + ((iceColors && blink) || brightBG ? 8 : 0)]
        case .rgb(let color): b = color
        }
        if inverse { swap(&f, &b) }
        return (f, b)
    }

    /// Applies one SGR sequence's parameters (missing ones already read as 0).
    mutating func apply(_ codes: [Int]) {
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: self = TextAttributes()
            case 1: bold = true
            case 5, 6: blink = true
            case 7: inverse = true
            case 22: bold = false
            case 25: blink = false
            case 27: inverse = false
            case 30...37: fg = .index(code - 30); brightFG = false
            case 39: fg = .index(7); brightFG = false
            case 40...47: bg = .index(code - 40); brightBG = false
            case 49: bg = .index(0); brightBG = false
            case 90...97: fg = .index(code - 90); brightFG = true
            case 100...107: bg = .index(code - 100); brightBG = true
            case 38, 48:
                // 38;5;n or 38;2;r;g;b (48 for background). A malformed tail ends the sequence.
                guard let (color, used) = Self.extendedColor(codes, from: i + 1) else { return }
                if code == 38 { fg = .rgb(color) } else { bg = .rgb(color) }
                i += used
            default: break
            }
            i += 1
        }
    }

    /// PabloDraw 24 bit color: ESC[0;r;g;bt sets the background, ESC[1;r;g;bt the foreground.
    mutating func applyPabloDraw(_ params: [Int]) {
        guard params.count >= 4 else { return }
        let color = RGB(r: UInt8(min(255, params[1])), g: UInt8(min(255, params[2])), b: UInt8(min(255, params[3])))
        if params[0] == 1 { fg = .rgb(color) } else if params[0] == 0 { bg = .rgb(color) }
    }

    /// Reads the parameters after 38 or 48. Returns the color and how many parameters it used.
    private static func extendedColor(_ codes: [Int], from start: Int) -> (RGB, Int)? {
        guard start < codes.count else { return nil }
        switch codes[start] {
        case 5 where start + 1 < codes.count:
            return (Palette.xterm256[min(255, codes[start + 1])], 2)
        case 2 where start + 3 < codes.count:
            let c = codes[(start + 1)...(start + 3)].map { UInt8(min(255, $0)) }
            return (RGB(r: c[0], g: c[1], b: c[2]), 4)
        default:
            return nil
        }
    }
}
