import Foundation

/// Which colours an exported screen carries: ANSI escape sequences, or the BBS package's own codes.
public enum ColourCodeMode: String, Codable, CaseIterable, Equatable {
    case ansi, native

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
    /// the codes cannot send (24 bit colours, or blink and bright backgrounds on pipes that stop at 23).
    public static func nativeBody(_ canvas: EditCanvas, package: BBSPackage) -> (bytes: [UInt8], lossy: Bool) {
        let syntax = package.definition.colours
        var out: [UInt8] = []
        var lossy = false
        var current: UInt8?
        let blank = AnsiCell()
        for row in canvas.screen(trimmed: true).rows {
            var cells = row
            while let last = cells.last, last == blank { cells.removeLast() }
            for cell in cells {
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
                // Ctrl-A and heart cells are codes the user typed with the picker: written as they are.
                let keep = cell.code == 0x01 || cell.code == 0x03
                out.append(keep ? cell.code : TextConvert.lookalikes[cell.code] ?? cell.code)
            }
            out += [0x0D, 0x0A]
        }
        return (out, lossy)
    }

    private static func hexDigit(_ value: Int) -> UInt8 { Array("0123456789ABCDEF".utf8)[value & 15] }

    private static func pipe(_ n: Int) -> [UInt8] { Array(String(format: "|%02d", n).utf8) }

    /// The codes that change the colour from `old` (nil: unknown) to `new`.
    static func codes(from old: UInt8?, to new: UInt8, syntax: ColourSyntax, ice: Bool) -> [UInt8] {
        let fg = Int(new & 0x0F), bg = Int((new >> 4) & 0x07), high = new & 0x80 != 0
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

    struct Renderer {
        let package: BBSPackage
        let colours: ColourSyntax
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
            colours = package.definition.colours
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
                            transform: (String) -> String = { $0 }) {
            guard let samples else { return }
            if let field = code.field {
                var text = transform(samples[field])
                if code.package == .pcboard, code.token == "@USER@" { text = text.uppercased() }
                if let pad = pendingPad {
                    pendingPad = nil
                    text = Self.pad(text, width: pad.width, align: pad.align)
                } else if let width {
                    text = Self.pad(text, width: width, align: align)
                }
                out += text.unicodeScalars.map { CP437.code(for: $0) ?? 0x3F }
            } else if let action = code.action {
                perform(action, token: token ?? code.token)
            } else if let colour = code.colour {
                self.colour(colour)
            }
        }

        static func pad(_ text: String, width: Int, align: UInt8) -> String {
            let chars = Array(text)
            if chars.count >= width { return String(chars.prefix(width)) }
            let gap = width - chars.count
            switch align {
            case 0x52: return String(repeating: " ", count: gap) + text
            case 0x43: return String(repeating: " ", count: gap / 2) + text + String(repeating: " ", count: gap - gap / 2)
            default: return text + String(repeating: " ", count: gap)
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

        /// A colour code of the package's syntax at `i`: the bytes it used.
        mutating func colourCode(at i: Int, in b: [UInt8]) -> Int? {
            func byte(_ k: Int) -> UInt8? { i + k < b.count ? b[i + k] : nil }
            let c = b[i]
            switch colours {
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
                case .atSynchronet where c == 0x40:
                    if let used = atCode(at: i, in: b, separators: [0x7C, 0x2D], pcboard: false) { return used }
                case .atPCBoard where c == 0x40:
                    if let used = atCode(at: i, in: b, separators: [0x3A], pcboard: true) { return used }
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
                case .percent(let caseBlind, let views) where c == 0x25:
                    guard let x = byte(1), let y = byte(2), x.isLetter, y.isLetter else { continue }
                    var token = "%" + String(UnicodeScalar(x)) + String(UnicodeScalar(y))
                    if caseBlind { token = token.uppercased() }
                    var used = 3
                    while views, let d = byte(used), (0x30...0x39).contains(d) { used += 1 }
                    if used > 3, codes.values.contains(where: { $0.action == .view && $0.token.prefix(3) == token.prefix(3) }) {
                        perform(.view, token: "%" + String(decoding: b[(i + 1)..<(i + used)], as: UTF8.self))
                        return used
                    }
                    if let code = codes[token] { apply(code); return 3 }
                default:
                    continue
                }
            }
            return nil
        }

        /// "@NAME@" with Synchronet modifiers ("|R20", "-L", "|Z3", "|U", "|R####", width then
        /// the whole code's length) or a PCBoard width (":30", ":30C", ":30R").
        mutating func atCode(at i: Int, in b: [UInt8], separators: Set<UInt8>, pcboard: Bool) -> Int? {
            var j = i + 1
            while j < b.count, j - i < 64, b[j] != 0x40, b[j] >= 0x20 { j += 1 }
            guard j < b.count, b[j] == 0x40, j > i + 1 else { return nil }
            let inner = Array(b[(i + 1)..<j])
            let split = inner.firstIndex { separators.contains($0) } ?? inner.count
            let name = String(decoding: inner[..<split], as: UTF8.self)
            guard let code = codes["@\(name)@"] else { return nil }
            let total = j - i + 1
            var width: Int?
            var align: UInt8 = 0x4C
            var transform: (String) -> String = { $0 }
            if split < inner.count {
                let modifiers = Array(inner[(split + 1)...])
                if pcboard {
                    width = Int(String(decoding: modifiers.prefix { (0x30...0x39).contains($0) }, as: UTF8.self))
                    if let last = modifiers.last, last == 0x43 || last == 0x52 { align = last }
                } else {
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
            apply(code, width: width, align: align, transform: transform)
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

    /// Codes in `bytes` written in another package's syntax, which `package` would show as text.
    /// Only syntax some registered package reads counts, so ordinary text ("100% sure") does not.
    public static func foreignCodes(in bytes: [UInt8], package: BBSPackage) -> [String] {
        let text = String(decoding: bytes.map { $0 >= 0x80 ? 0x20 : $0 }, as: UTF8.self)
        let colours = package.definition.colours, macros = package.definition.macros
        let others = BBSPackageRegistry.definitions.filter { $0.package != package }
        var found: [String] = []
        func add(_ token: String) { if !found.contains(token) { found.append(token) } }
        func matches(_ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }
        func otherKnows(_ token: String) -> Bool {
            others.contains { d in DisplayCodeCatalog.codes(d.package).contains { $0.token == token } }
        }
        let ownTokens = Set(DisplayCodeCatalog.codes(package).map(\.token))
        // Pipe colours.
        let pipeLimit: Int? = { switch colours { case .pipes(let l): return l; case .wwiv: return 24; default: return nil } }()
        for token in matches("\\|[0-9]{2}") where (Int(token.dropFirst()) ?? 0) >= (pipeLimit ?? 0) {
            if otherKnows(token) { add(token) }
        }
        // Pipe letters, WWIV macros, percent codes: foreign when this package does not read the token.
        for token in matches("\\|[A-Z@\\[][A-Za-z@%!/\\[]|%[A-Za-z]{2}[0-9]*") {
            let caseBlind = macros.contains(.percent(caseBlind: true, views: false))
            let base = token.hasPrefix("%") ? String(token.prefix(3)) : token
            let mine = ownTokens.contains(token) || ownTokens.contains(caseBlind ? base.uppercased() : base)
                || (macros.contains(.percent(caseBlind: false, views: true)) && ownTokens.contains { $0.count > 3 && $0.prefix(3) == base })
                || (macros.contains(.pipeLetters) && token.hasPrefix("|$"))
            if !mine, otherKnows(base) || otherKnows(token) || others.contains(where: { d in
                DisplayCodeCatalog.codes(d.package).contains { $0.action == .view && $0.token.prefix(3) == base } }) {
                add(token)
            }
        }
        // @X colours and @bf@ colours.
        if colours != .atX { for token in matches("@X[0-9A-Fa-f]{2}") { add(token) } }
        if colours != .atHexAt { for token in matches("@[0-9A-F]{2}@") { add(token) } }
        // @NAME@ codes.
        let readsAt = macros.contains(.atSynchronet) || macros.contains(.atPCBoard)
        for token in matches("@[A-Z][A-Z0-9_.]*(?:[|:\\-][A-Z0-9#]*)?@") where !readsAt {
            let name = String(token.dropFirst().prefix { $0 != "@" && $0 != "|" && $0 != ":" && $0 != "-" })
            if otherKnows("@\(name)@") { add(token) }
        }
        if colours != .ctrlA { for token in matches("\u{01}.") { add(DisplayCodeCatalog.printable(token)) } }
        if colours != .wwiv { for token in matches("\u{03}[0-9]") { add(DisplayCodeCatalog.printable(token)) } }
        return found
    }
}

private extension UInt8 {
    var isLetter: Bool { (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self) }
}
