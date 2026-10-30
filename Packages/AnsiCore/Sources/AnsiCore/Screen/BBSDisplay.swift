import Foundation

/// Which colours an exported screen carries: ANSI escape sequences, or the BBS package's own codes.
public enum ColourCodeMode: String, Codable, CaseIterable, Equatable {
    case ansi, native

    /// The modes a package offers: its own codes only when it has colour codes (review fix).
    public static func modes(for package: BBSPackage) -> [ColourCodeMode] {
        package.definition.colours == .none ? [.ansi] : [.ansi, .native]
    }

    public func label(_ package: BBSPackage) -> String {
        self == .ansi ? "ANSI colours (escape codes)" : "\(package.displayName) \(package.colourCodeName)"
    }
}

/// The BBS side of a screen (screen designer rulings 2 to 4): writing the canvas with a package's
/// colour codes, reading those codes back, and producing what the BBS sends a caller with every
/// display code replaced by a sample value. Everything works from the package's syntax families
/// (`ColourSyntax`, `MacroSyntax`), so registry packages need no code here. Extends `BBSCodes`:
/// its attribute to SGR conversion is reused.
public enum BBSDisplay {
    // MARK: Writing native colour codes

    /// The canvas as text with the package's colour codes instead of escape sequences, CR LF line
    /// ends, trailing blanks trimmed (as `ArtWriter.ansiBody`). Lossy when a cell needed a colour
    /// the codes cannot send (24 bit colours, or blink and bright backgrounds the syntax lacks).
    public static func nativeBody(_ canvas: EditCanvas, package: BBSPackage) -> (bytes: [UInt8], lossy: Bool) {
        let syntax = package.definition.colours
        var out: [UInt8] = []
        var lossy = false
        var current: UInt8?
        let blank = AnsiCell()
        let tokens = DisplayCodeCatalog.codes(package).map { Array($0.token.lowercased().utf8) }
        for row in canvas.screen(trimmed: true).rows {
            var cells = row
            while let last = cells.last, last == blank { cells.removeLast() }
            let lowered = cells.map { (0x41...0x5A).contains($0.code) ? $0.code + 0x20 : $0.code }
            for (x, cell) in cells.enumerated() {
                var attribute = ArtWriter.attribute(cell, ice: canvas.iceColors)
                if Palette.vgaIndex(of: cell.fg) == nil || Palette.vgaIndex(of: cell.bg) == nil { lossy = true }
                let isBlank = cell.code == 0x20 || cell.code == 0
                switch syntax {
                case .atX:
                    // @X00 and @XFF save and restore the colour instead of setting it.
                    if attribute == 0x00 { if !isBlank { lossy = true }; attribute = isBlank ? 0x07 : 0x08 }
                    if attribute == 0xFF { lossy = true; attribute = 0x7F }
                case .pipes(let limit) where limit <= 24:
                    if attribute & 0x80 != 0 { lossy = true; attribute &= 0x7F }
                case .wwiv:
                    if attribute & 0x80 != 0 { lossy = true; attribute &= 0x7F }
                default: break
                }
                if syntax != .none, attribute != current {
                    out += codes(from: current, to: attribute, syntax: syntax, ice: canvas.iceColors)
                    current = attribute
                }
                // Control byte cells are codes the user typed with the picker: written as they are.
                let keep = [0x01, 0x03, 0x06, 0x0B].contains(cell.code)
                let byte = keep ? cell.code : TextConvert.lookalikes[cell.code] ?? cell.code
                // A character that starts this syntax's codes is doubled to stay text ("||", "[["),
                // unless a code of the package starts there (a code the user typed).
                if let escape = syntax.literalEscape, byte == escape,
                   !tokens.contains(where: { lowered[x...].starts(with: $0) }) {
                    out += [byte, byte]
                } else {
                    out.append(byte)
                }
            }
            out += [0x0D, 0x0A]
        }
        return (out, lossy)
    }

    private static func hexDigit(_ value: Int) -> UInt8 { Array("0123456789ABCDEF".utf8)[value & 15] }

    private static func pipe(_ n: Int) -> [UInt8] { Array(String(format: "|%02d", n).utf8) }

    /// Celerity letters in VGA order, low (0 to 7) then high (8 to 15).
    static let celerityLetters: [Character] = ["k", "b", "g", "c", "r", "m", "y", "w", "d", "B", "G", "C", "R", "M", "Y", "W"]
    /// Searchlight colour names in VGA order.
    static let searchlightNames = ["BK", "BL", "GR", "CY", "RD", "MG", "BR", "GY", "DG", "LB", "LG", "LC", "LR", "LM", "YE", "WH"]
    /// MECCA colour names in VGA order (the first eight also as backgrounds).
    static let meccaNames = ["black", "blue", "green", "cyan", "red", "magenta", "brown", "gray", "darkgray", "lightblue",
                             "lightgreen", "lightcyan", "lightred", "lightmagenta", "yellow", "white"]

    /// The codes that change the colour from `old` (nil: unknown) to `new`.
    static func codes(from old: UInt8?, to new: UInt8, syntax: ColourSyntax, ice: Bool) -> [UInt8] {
        let fg = Int(new & 0x0F), bg = Int((new >> 4) & 0x07), high = new & 0x80 != 0
        func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
        switch syntax {
        case .ctrlA:
            // Normal first, then the letter, then the background digit (ANSI order; a digit
            // replaces the whole background), then high intensity and blink or iCE.
            let letter = UInt8(ascii: DisplayCodeCatalog.synchronetLetters[fg & 7].unicodeScalars.first!)
            var out: [UInt8] = [0x01, 0x4E, 0x01, letter, 0x01, UInt8(0x30 + SGRState.vgaToAnsi[bg])]
            if fg >= 8 { out += [0x01, 0x48] }
            if high { out += [0x01, ice ? 0x45 : 0x49] }
            return out
        case .pipes, .wwiv:
            // A background code keeps the foreground; a foreground code keeps the background.
            var out: [UInt8] = []
            if old.map({ Int($0 >> 4) }) != Int(new >> 4) { out += pipe((high ? 24 : 16) + bg) }
            if old.map({ Int($0 & 0x0F) }) != fg { out += pipe(fg) }
            return out
        case .atX:
            return [0x40, 0x58, hexDigit(Int(new >> 4)), hexDigit(fg)]
        case .atHexAt:
            return [0x40, hexDigit(Int(new >> 4)), hexDigit(fg), 0x40]
        case .celerity:
            // The background colour as the foreground, swap, then the foreground; blink on or off.
            return bytes("|\(celerityLetters[bg])|S|\(celerityLetters[fg])|\(high ? "X" : "x")")
        case .ctrlKBracket:
            return [0x0B, 0x5B, hexDigit(Int(new >> 4)), hexDigit(fg)]
        case .impulse:
            return bytes(String(format: "%%B%X%%%02d", Int(new >> 4), fg))
        case .searchlight:
            // Normal, the background colour, inverse (it becomes the background), the foreground.
            return bytes("\\NO\\\(searchlightNames[bg])\\IV\\\(searchlightNames[fg])" + (high ? "\\BI" : ""))
        case .mecca:
            return bytes("[\(high ? "blink" : "steady")][\(meccaNames[fg]) on \(meccaNames[bg])]")
        case .none:
            return BBSCodes.sgr(attribute: new)
        }
    }

    // MARK: What the BBS sends

    /// `bytes` as the package would send them: colour codes become ANSI colours and, when
    /// `samples` are given, value codes become the sample values and screen codes their effect.
    /// Without samples only colours change (for opening such a file in the editor). Stops at the
    /// DOS end of file (0x1A), where SAUCE starts.
    public static func render(_ bytes: [UInt8], package: BBSPackage, samples: SampleValues?) -> [UInt8] {
        var r = Renderer(package: package, samples: samples)
        r.run(Array(bytes.prefix { $0 != 0x1A }))
        return r.out
    }

    /// The screen a caller ends up with from `sent` (the output of `render`), at the art's width.
    public static func screen(_ sent: [UInt8], columns: Int, iceColors: Bool) -> AnsiScreen {
        let sauce = Sauce(title: "", author: "", group: "", date: nil, dataType: 1, fileType: 1,
                          tInfo: [UInt16(max(1, min(columns, EditCanvas.maxColumns))), 0, 0, 0],
                          flags: iceColors ? 0x01 : 0x00, fontName: "", comments: [])
        let data = Data(sent + sauce.encoded(fileSize: sent.count))
        return AnsiAnalysis(ArtFile(data: data, fileExtension: "ans")).finalScreen
    }

    struct Renderer {
        let package: BBSPackage
        let colours: [ColourSyntax]
        let macros: [MacroSyntax]
        let codes: [String: DisplayCode]
        let samples: SampleValues?
        var out: [UInt8] = []
        var attribute: UInt8 = 0x07
        /// Mystic |$L## style padding waiting for the next code.
        var pendingPad: (align: UInt8, width: Int)?

        init(package: BBSPackage, samples: SampleValues?) {
            self.package = package
            self.samples = samples
            colours = package.definition.colourSyntaxes
            macros = package.definition.macros
            var map: [String: DisplayCode] = [:]
            for code in DisplayCodeCatalog.codes(package) where map[code.token] == nil { map[code.token] = code }
            codes = map
        }

        mutating func setAttribute(_ value: UInt8) {
            attribute = value
            out += BBSCodes.sgr(attribute: value)
        }

        mutating func colour(_ effect: ColourEffect) {
            switch effect {
            case .foreground(let i): setAttribute(attribute & 0xF0 | UInt8(i))
            case .background(let i): setAttribute(attribute & 0x0F | UInt8(i) << 4)
            case .highBackground(let i): setAttribute(attribute & 0x0F | UInt8(i) << 4 | 0x80)
            }
        }

        /// Swaps foreground and background (the foreground's intensity is lost, as on a DOS screen).
        mutating func swapColours() {
            let fg = attribute & 0x07, bg = (attribute >> 4) & 0x07
            setAttribute(attribute & 0x80 | fg << 4 | bg)
        }

        mutating func perform(_ action: DisplayAction, token: String) {
            switch action {
            case .clearScreen: out += Array("\u{1B}[2J\u{1B}[H".utf8)
            case .newline: out += [0x0D, 0x0A]
            case .home: out += Array("\u{1B}[H".utf8)
            case .clearToEndOfLine: out += Array("\u{1B}[K".utf8)
            case .view: out += Array("[\(token.dropFirst())]".utf8)
            case .pause, .beep, .delay: break
            }
        }

        /// Writes a code's effect: the sample value (padded), the action or the colour.
        mutating func apply(_ code: DisplayCode, token: String? = nil, width: Int? = nil, align: UInt8 = 0x4C,
                            fill: Character = " ", transform: (String) -> String = { $0 }) {
            guard let samples else { return }
            if let field = code.field {
                var text = transform(samples[field])
                if code.package == .pcboard, code.token == "@USER@" { text = text.uppercased() }
                if let pad = pendingPad {
                    pendingPad = nil
                    text = Self.pad(text, width: pad.width, align: pad.align)
                } else if let width {
                    text = Self.pad(text, width: width, align: align, fill: fill)
                }
                out += text.unicodeScalars.map { CP437.code(for: $0) ?? 0x3F }
            } else if let action = code.action {
                perform(action, token: token ?? code.token)
            } else if let colour = code.colour {
                self.colour(colour)
            }
        }

        /// Widest field a code may ask for: wider than any terminal line, small enough that a
        /// mistyped width ("@USER:999999999@") cannot stall the preview (review fix).
        static let maxPad = 255

        static func pad(_ text: String, width: Int, align: UInt8, fill: Character = " ") -> String {
            let width = min(width, maxPad)
            let chars = Array(text)
            if chars.count >= width { return String(chars.prefix(width)) }
            let gap = width - chars.count
            let f = String(fill)
            switch align {
            case 0x52: return String(repeating: f, count: gap) + text
            case 0x43: return String(repeating: f, count: gap / 2) + text + String(repeating: f, count: gap - gap / 2)
            default: return text + String(repeating: f, count: gap)
            }
        }

        mutating func run(_ b: [UInt8]) {
            var i = 0
            while i < b.count {
                if b[i] == 0x1B {
                    // Escape sequences pass through untouched.
                    var j = i + 1
                    if j < b.count, b[j] == 0x5B {
                        j += 1
                        while j < b.count, !(0x40...0x7E).contains(b[j]) { j += 1 }
                    }
                    let end = min(b.count, j + 1)
                    out += b[i..<end]
                    i = end
                    continue
                }
                if let used = colourCode(at: i, in: b) ?? macroCode(at: i, in: b) { i += used; continue }
                out.append(b[i])
                i += 1
            }
        }

        static func digits(_ b: [UInt8], _ from: Int, _ n: Int) -> Int? {
            guard from >= 0, from + n <= b.count else { return nil }
            let part = b[from..<(from + n)]
            guard part.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            return Int(String(decoding: part, as: UTF8.self))
        }

        mutating func colourCode(at i: Int, in b: [UInt8]) -> Int? {
            for syntax in colours {
                if let used = colourCode(at: i, in: b, syntax: syntax) { return used }
            }
            return nil
        }

        /// A colour code of `syntax` at `i`: the bytes it used.
        mutating func colourCode(at i: Int, in b: [UInt8], syntax: ColourSyntax) -> Int? {
            func byte(_ k: Int) -> UInt8? { i + k < b.count ? b[i + k] : nil }
            func word(_ k: Int, _ n: Int) -> String? { i + k + n <= b.count ? String(decoding: b[(i + k)..<(i + k + n)], as: UTF8.self) : nil }
            let c = b[i]
            switch syntax {
            case .ctrlA:
                guard c == 0x01, let x = byte(1) else { return nil }
                let upper = (0x61...0x7A).contains(x) ? x - 0x20 : x
                if let index = DisplayCodeCatalog.synchronetLetters.firstIndex(of: Character(Unicode.Scalar(upper))) {
                    setAttribute(attribute & 0xF8 | UInt8(index))
                } else if (0x30...0x37).contains(x) {
                    setAttribute(attribute & 0x0F | UInt8(Palette.ansiToVGA[Int(x - 0x30)]) << 4)
                } else if upper == 0x48 { setAttribute(attribute | 0x08)
                } else if upper == 0x49 || upper == 0x45 { setAttribute(attribute | 0x80)
                } else if upper == 0x4E { setAttribute(0x07)
                } else if samples == nil {
                    return nil
                } else if x == 0x5B { out.append(0x0D)
                } else if x == 0x5D { out.append(0x0A)
                } else if let code = codes["\u{01}" + String(UnicodeScalar(upper))] {
                    apply(code)
                }
                return 2
            case .pipes(let limit):
                guard c == 0x7C, let n = Self.digits(b, i + 1, 2), n < limit else { return nil }
                colour(n < 16 ? .foreground(n) : n < 24 ? .background(n - 16) : .highBackground(n - 24))
                return 3
            case .wwiv:
                if c == 0x03, let d = byte(1), (0x30...0x39).contains(d) {
                    setAttribute(Self.wwivHearts[Int(d - 0x30)])
                    return 2
                }
                guard c == 0x7C else { return nil }
                if let n = Self.digits(b, i + 1, 2), n < 24 {
                    colour(n < 16 ? .foreground(n) : .background(n - 16))
                    return 3
                }
                if byte(1) == 0x23, let d = byte(2), (0x30...0x39).contains(d) {
                    setAttribute(Self.wwivHearts[Int(d - 0x30)])
                    return 3
                }
                return nil
            case .atX:
                guard c == 0x40, byte(1) == 0x58, let h = byte(2).flatMap(Self.hex), let l = byte(3).flatMap(Self.hex) else { return nil }
                setAttribute(UInt8(h << 4 | l))
                return 4
            case .atHexAt:
                guard c == 0x40, byte(3) == 0x40, let h = byte(1).flatMap(Self.hex), let l = byte(2).flatMap(Self.hex) else { return nil }
                setAttribute(UInt8(h << 4 | l))
                return 4
            case .celerity:
                guard c == 0x7C, let x = byte(1) else { return nil }
                if x == 0x7C { out.append(0x7C); return 2 }
                if let index = BBSDisplay.celerityLetters.firstIndex(of: Character(Unicode.Scalar(x))) {
                    setAttribute(attribute & 0xF0 | UInt8(index))
                } else if x == 0x53 { swapColours()
                } else if x == 0x58 { setAttribute(attribute | 0x80)
                } else if x == 0x78 { setAttribute(attribute & 0x7F)
                } else { return nil }
                return 2
            case .ctrlKBracket:
                guard c == 0x0B, byte(1) == 0x5B, let h = byte(2).flatMap(Self.hex), let l = byte(3).flatMap(Self.hex) else { return nil }
                setAttribute(UInt8(h << 4 | l))
                return 4
            case .impulse:
                guard c == 0x25 else { return nil }
                if byte(1) == 0x42, let h = byte(2).flatMap(Self.hex) {
                    setAttribute(attribute & 0x0F | UInt8(h) << 4)
                    return 3
                }
                if let n = Self.digits(b, i + 1, 2), n < 16 { colour(.foreground(n)); return 3 }
                return nil
            case .searchlight:
                if c == 0x5C, byte(1) == 0x5C { out.append(0x5C); return 2 }
                guard c == 0x5C, let name = word(1, 2) else { return nil }
                if let index = BBSDisplay.searchlightNames.firstIndex(of: name) { setAttribute(attribute & 0xF0 | UInt8(index))
                } else if name == "IV" { swapColours()
                } else if name == "BI" { setAttribute(attribute | 0x80)
                } else if name == "NO" { setAttribute(0x07)
                } else { return nil }
                return 3
            case .mecca:
                if c == 0x5B, byte(1) == 0x5B { out.append(0x5B); return 2 }
                guard c == 0x5B, let end = b[i...].firstIndex(of: 0x5D), end - i < 40 else { return nil }
                let inner = String(decoding: b[(i + 1)..<end], as: UTF8.self).lowercased()
                let parts = inner.split(separator: " ").map(String.init)
                if parts.count == 3, parts[1] == "on", let fg = BBSDisplay.meccaNames.firstIndex(of: parts[0]),
                   let bg = BBSDisplay.meccaNames.prefix(8).firstIndex(of: parts[2]) {
                    setAttribute(attribute & 0x80 | UInt8(bg) << 4 | UInt8(fg))
                } else if parts.count == 1, let fg = BBSDisplay.meccaNames.firstIndex(of: parts[0]) {
                    setAttribute(attribute & 0xF0 | UInt8(fg))
                } else if inner == "blink" { setAttribute(attribute | 0x80)
                } else if inner == "steady" { setAttribute(attribute & 0x7F)
                } else { return nil }
                return end - i + 1
            case .none:
                return nil
            }
        }

        /// A value or screen code at `i` (only with samples): the bytes it used.
        mutating func macroCode(at i: Int, in b: [UInt8]) -> Int? {
            guard samples != nil else { return nil }
            func byte(_ k: Int) -> UInt8? { i + k < b.count ? b[i + k] : nil }
            let c = b[i]
            for syntax in macros {
                switch syntax {
                case .atCodes(let style) where c == 0x40:
                    if let used = atCode(at: i, in: b, style: style) { return used }
                case .pipeLetters where c == 0x7C:
                    if byte(1) == 0x24, let align = byte(2), let width = Self.digits(b, i + 3, 2) {
                        pendingPad = (align == 0x4C ? 0x4C : align == 0x43 ? 0x43 : 0x52, width)
                        return 5
                    }
                    if let x = byte(1), let y = byte(2), let code = codes["|" + String(UnicodeScalar(x)) + String(UnicodeScalar(y))] {
                        apply(code)
                        return 3
                    }
                case .wwivMacros where c == 0x7C:
                    if let x = byte(1), let y = byte(2), let code = codes["|" + String(UnicodeScalar(x)) + String(UnicodeScalar(y))] {
                        apply(code)
                        return 3
                    }
                case .letters(let prefix, let count, let caseBlind, let views):
                    let p = Array(prefix.utf8)
                    guard b[i...].starts(with: p), i + p.count + count <= b.count else { continue }
                    let letters = b[(i + p.count)..<(i + p.count + count)]
                    guard letters.allSatisfy({ $0.isLetter || (count == 1 && $0 > 0x20) }) else { continue }
                    var token = prefix + String(decoding: letters, as: UTF8.self)
                    if caseBlind { token = prefix + String(decoding: letters, as: UTF8.self).uppercased() }
                    var used = p.count + count
                    if views {
                        while let d = byte(used), (0x30...0x39).contains(d) { used += 1 }
                        if used > p.count + count, codes.values.contains(where: { $0.action == .view && $0.token.hasPrefix(token) }) {
                            perform(.view, token: String(decoding: b[i..<(i + used)], as: UTF8.self))
                            return used
                        }
                        used = p.count + count
                    }
                    if let code = codes[token] { apply(code); return used }
                case .controlFK where c == 0x06 || c == 0x0B:
                    // RA: dots add a space each; ProBoard: @ # % fill to the whole code's length.
                    var k = 1, dots = 0, fills = 0
                    var align: UInt8 = 0x4C
                    while let x = byte(k), x == 0x2E || x == 0x40 || x == 0x23 || x == 0x25 {
                        if x == 0x2E { dots += 1 } else { fills += 1; align = x == 0x23 ? 0x52 : x == 0x25 ? 0x43 : 0x4C }
                        k += 1
                    }
                    guard let letter = byte(k), let code = codes[String(UnicodeScalar(c)) + String(UnicodeScalar(letter))] else { continue }
                    let width: Int? = dots > 0 ? 1 + dots : fills > 0 ? k + 1 : nil
                    apply(code, width: width, align: dots > 0 && code.field.map({ [.calls, .timeLeft, .node].contains($0) }) == true ? 0x52 : align)
                    return k + 1
                case .brackets where c == 0x5B:
                    guard let end = b[i...].firstIndex(of: 0x5D), end - i < 32 else { continue }
                    let token = "[" + String(decoding: b[(i + 1)..<end], as: UTF8.self).lowercased() + "]"
                    if let code = codes[token] { apply(code); return end - i + 1 }
                default:
                    continue
                }
            }
            return nil
        }

        /// "@NAME@" with the style's padding.
        mutating func atCode(at i: Int, in b: [UInt8], style: MacroSyntax.AtStyle) -> Int? {
            var j = i + 1
            while j < b.count, j - i < 64, b[j] != 0x40, b[j] >= 0x20 { j += 1 }
            guard j < b.count, b[j] == 0x40, j > i + 1 else { return nil }
            let inner = Array(b[(i + 1)..<j])
            let separators: Set<UInt8> = style == .synchronet ? [0x7C, 0x2D] : style == .hashes ? [0x23] : [0x3A]
            let split = inner.firstIndex { separators.contains($0) } ?? inner.count
            let name = String(decoding: inner[..<split], as: UTF8.self)
            guard let code = codes["@\(name)@"] else { return nil }
            let total = j - i + 1
            var width: Int?
            var align: UInt8 = 0x4C
            var fill: Character = " "
            var transform: (String) -> String = { $0 }
            if split < inner.count {
                let modifiers = Array(inner[(split + 1)...])
                switch style {
                case .hashes:
                    width = total
                case .pcboard:
                    width = Int(String(decoding: modifiers.prefix { (0x30...0x39).contains($0) }, as: UTF8.self))
                    if let last = modifiers.last, last == 0x43 || last == 0x52 { align = last }
                case .celerity:
                    if let first = modifiers.first, [0x4C, 0x52, 0x43].contains(first) {
                        align = first
                        width = Self.digits(modifiers, 1, 2)
                        if modifiers.count > 3 { fill = Character(Unicode.Scalar(modifiers[3])) }
                    }
                case .synchronet:
                    var k = 0
                    while k < modifiers.count {
                        let m = modifiers[k]
                        k += 1
                        let number = modifiers[k...].prefix { (0x30...0x39).contains($0) }
                        switch m {
                        case 0x4C, 0x52, 0x43:
                            align = m
                            let hashes = modifiers[k...].prefix { $0 == 0x23 }
                            if !number.isEmpty { width = Int(String(decoding: number, as: UTF8.self)); k += number.count }
                            else { width = total; k += hashes.count }
                        case 0x5A:
                            let n = Int(String(decoding: number, as: UTF8.self)) ?? 0
                            k += number.count
                            let previous = transform
                            transform = { text in
                                let t = previous(text)
                                return t.count < n ? String(repeating: "0", count: n - t.count) + t : t
                            }
                        case 0x55: let previous = transform; transform = { previous($0).uppercased() }
                        case 0x44: let previous = transform; transform = { previous($0).lowercased() }
                        default: break
                        }
                    }
                }
            }
            apply(code, width: width, align: align, fill: fill, transform: transform)
            return total
        }

        static func hex(_ b: UInt8) -> Int? {
            switch b {
            case 0x30...0x39: return Int(b - 0x30)
            case 0x41...0x46: return Int(b - 0x41 + 10)
            case 0x61...0x66: return Int(b - 0x61 + 10)
            default: return nil
            }
        }

        /// WWIV's default new user colours for heart codes 0 to 9 (bbs/application.cpp).
        static let wwivHearts: [UInt8] = [7, 11, 14, 5, 31, 2, 12, 9, 6, 3]
    }

    // MARK: Codes of other packages

    /// Codes in `bytes` that another registered package reads and `package` does not (it would show
    /// them as text). Data driven: every other package's catalogue tokens are looked for, and a
    /// token counts as foreign when this package's own renderer leaves it unchanged. Ordinary text
    /// ("100% sure") is not a token of any package, so it is never reported.
    public static func foreignCodes(in bytes: [UInt8], package: BBSPackage) -> [String] {
        var found: [(Int, String)] = []
        var seen: Set<String> = []
        func readsItself(_ token: [UInt8]) -> Bool {
            render(token, package: package, samples: SampleValues()) != token
        }
        func consider(_ token: [UInt8], at offset: Int) {
            let printable = DisplayCodeCatalog.printable(String(decoding: token, as: UTF8.self))
            guard !seen.contains(printable), !readsItself(token) else { return }
            seen.insert(printable)
            found.append((offset, printable))
        }
        let candidates = Set(BBSPackageRegistry.definitions.filter { $0.package != package }.flatMap { DisplayCodeCatalog.codes($0.package) }
            .map(\.token).filter { token in
                // Two character codes ("|b", "\\%N" is three) are too common in ordinary text to report,
                // except those starting with a control byte (Ctrl-A, hearts, Ctrl-F, Ctrl-K).
                let control = token.unicodeScalars.first.map { $0.value < 0x20 } ?? false
                return (token.count >= 3 || control) && token.unicodeScalars.contains { !CharacterSet.alphanumerics.contains($0) }
            })
        for token in candidates {
            let t = Array(token.utf8)
            var i = 0
            while i + t.count <= bytes.count {
                if bytes[i] == t[0], Array(bytes[i..<(i + t.count)]) == t {
                    // A pipe or percent code must not run on into more letters ("|UHX" is not "|UH").
                    let next = i + t.count < bytes.count ? bytes[i + t.count] : 0x20
                    let lettersCode = t.count == 3 && (t[0] == 0x7C || t[0] == 0x25) && t[1].isLetter
                    if !(lettersCode && next.isLetter) { consider(t, at: i) }
                }
                i += 1
            }
        }
        // Colour codes outside the catalogue subsets: any @Xhh, any @hh@, any pipe number.
        for (pattern, length) in [("@X", 4), ("|", 3)] {
            let p = Array(pattern.utf8)
            var i = 0
            while i + length <= bytes.count {
                if Array(bytes[i..<(i + p.count)]) == p {
                    let rest = bytes[(i + p.count)..<(i + length)]
                    let ok = pattern == "@X" ? rest.allSatisfy { Renderer.hex($0) != nil } : rest.allSatisfy { (0x30...0x39).contains($0) }
                    if ok, BBSPackageRegistry.definitions.contains(where: { d in d.package != package && d.colourSyntaxes.contains { s in
                        if pattern == "@X" { return s == .atX }
                        if case .pipes = s { return true }
                        return s == .wwiv } }) {
                        consider(Array(bytes[i..<(i + length)]), at: i)
                    }
                }
                i += 1
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

private extension UInt8 {
    var isLetter: Bool { (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self) }
}
