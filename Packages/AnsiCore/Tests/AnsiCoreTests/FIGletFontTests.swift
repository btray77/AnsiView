import Foundation
import Testing
@testable import AnsiCore

struct FIGletFontTests {
    /// A two row font written for these tests: space, A, B, a few rule characters.
    static func tinyFont(layout: String = "-1 1 0 64") -> String {
        // header: hardblank $, height 2, baseline 2, max length 6, then `layout`: old layout,
        // comment line count (1), and optionally print direction and full layout.
        var lines = ["flf2a$ 2 2 6 \(layout)"]
        lines.append("A comment line.")
        func char(_ rows: [String]) {
            for (i, row) in rows.enumerated() { lines.append(row + (i == rows.count - 1 ? "@@" : "@")) }
        }
        for code in 32...126 {
            switch code {
            case 32: char(["$ ", "$ "])
            case 65: char(["/\\", "||"])
            case 66: char(["|)", "|)"])
            case 95: char(["  ", "__"])
            case 124: char(["| ", "| "])
            default: char(["", ""])
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String, name: String = "Tiny") throws -> FIGletFont {
        try FIGletFont.parse(Data(text.utf8), name: name)
    }

    static func lines(_ font: FIGletFont, _ text: String, _ layout: FIGletLayout = .fontDefault) -> [String] {
        font.renderLine(text, horizontal: layout).map { String(String.UnicodeScalarView($0)) }
    }

    @Test func parsesHeaderAndGlyphs() throws {
        let font = try Self.parse(Self.tinyFont())
        #expect(font.height == 2)
        #expect(font.hardblank == "$")
        #expect(font.comments == ["A comment line."])
        #expect(font.glyphs[65] == [Array("/\\".unicodeScalars), Array("||".unicodeScalars)])
        // Trailing end marks are removed, so short rows stay short until rendering pads them.
        #expect(font.glyphs[66]?[0] == Array("|)".unicodeScalars))
        #expect(font.horizontalMode == .fitting)
    }

    @Test func refusesBadHeaders() {
        #expect(throws: FIGletError.notFIGlet) { try Self.parse("hello") }
        #expect(throws: FIGletError.badHeader) { try Self.parse("flf2a$ x 2 6 0 0\n") }
        #expect(throws: FIGletError.badHeader) { try Self.parse("flf2a$ 0 2 6 0 0\n") }
        #expect(throws: FIGletError.badHeader) { try Self.parse("flf2a$ 500 2 6 0 0\n") }
        // A font with no characters at all.
        #expect(throws: FIGletError.noCharacters) { try Self.parse("flf2a$ 2 2 6 0 0\n") }
    }

    @Test func shortFileKeepsTheCharactersRead() throws {
        let full = Self.tinyFont()
        let cut = full.split(separator: "\n", omittingEmptySubsequences: false).prefix(2 + 2 * 20).joined(separator: "\n")
        let font = try Self.parse(String(cut))
        #expect(font.glyphs[32] != nil)
        #expect(font.glyphs[65] == nil)
    }

    @Test func deutschAndCodeTaggedCharacters() throws {
        var text = Self.tinyFont()
        for _ in 0..<7 { text += "D@\nD@@\n" }
        text += "0x263A  smiley\n:)@\n:)@@\n"
        text += "0123  octal 83\nS@\nS@@\n"
        text += "-5  negative, skipped\nN@\nN@@\n"
        text += "300\nT@\nT@@\n"
        let font = try Self.parse(text)
        #expect(font.glyphs[196] != nil && font.glyphs[223] != nil)
        #expect(font.glyphs[0x263A]?[0] == Array(":)".unicodeScalars))
        #expect(font.glyphs[83]?[0] == Array("S".unicodeScalars))
        #expect(font.glyphs[-5] == nil)
        #expect(font.glyphs[300] != nil)
    }

    @Test func layoutFromOldAndFullLayout() throws {
        #expect(try Self.parse(Self.tinyFont(layout: "-1 1")).horizontalMode == .fullWidth)
        #expect(try Self.parse(Self.tinyFont(layout: "0 1")).horizontalMode == .fitting)
        #expect(try Self.parse(Self.tinyFont(layout: "15 1")).horizontalMode == .smushing(rules: 15))
        // Full layout wins: 128 + 1 + 2 is smushing with rules 1 and 2.
        #expect(try Self.parse(Self.tinyFont(layout: "-1 1 0 131")).horizontalMode == .smushing(rules: 3))
        #expect(try Self.parse(Self.tinyFont(layout: "15 1 0 64")).horizontalMode == .fitting)
        #expect(try Self.parse(Self.tinyFont(layout: "15 1 0 0")).horizontalMode == .fullWidth)
        // Vertical bits: 8192 fitting, 16384 smushing with rules from bits 8 to 12.
        #expect(try Self.parse(Self.tinyFont(layout: "15 1 0 8192")).verticalMode == .fitting)
        #expect(try Self.parse(Self.tinyFont(layout: "15 1 0 16640")).verticalMode == .smushing(rules: 1))
        #expect(try Self.parse(Self.tinyFont(layout: "15 1")).verticalMode == .fullWidth)
    }

    @Test func smushingRules() {
        func s(_ l: Character, _ r: Character, _ rules: Int) -> Character? {
            FIGletFont.smushHorizontal(l.unicodeScalars.first!, r.unicodeScalars.first!,
                                       mode: rules < 0 ? .smushing(rules: 0) : .smushing(rules: rules),
                                       hardblank: "$", leftWidth: 2, rightWidth: 2).map { Character($0) }
        }
        // Spaces always give way.
        #expect(s(" ", "x", 0) == "x" && s("x", " ", 0) == "x")
        // Rule 1 equal characters.
        #expect(s("|", "|", 1) == "|" && s("|", "/", 1) == nil)
        // Rule 2 underscore.
        #expect(s("_", "/", 2) == "/" && s("[", "_", 2) == "[" && s("_", "x", 2) == nil)
        // Rule 4 hierarchy: | then /\ then [] then {} then () then <>.
        #expect(s("|", "/", 4) == "/" && s("}", "/", 4) == "}" && s("(", ">", 4) == ">" && s("/", "\\", 4) == nil)
        // Rule 8 opposite pairs.
        #expect(s("[", "]", 8) == "|" && s(")", "(", 8) == "|" && s("{", "}", 8) == "|")
        // Rule 16 big X.
        #expect(s("/", "\\", 16) == "|" && s("\\", "/", 16) == "Y" && s(">", "<", 16) == "X" && s("<", ">", 16) == nil)
        // Rule 32 hardblank; hardblanks never smush otherwise.
        #expect(s("$", "$", 32) == "$" && s("$", "$", 1) == nil && s("$", "x", 63) == nil)
        // Universal: the right character wins, a hardblank gives way.
        #expect(s("a", "b", -1) == "b" && s("$", "b", -1) == "b" && s("a", "$", -1) == "a")
        // Characters narrower than 2 columns do not smush.
        #expect(FIGletFont.smushHorizontal("|", "|", mode: .smushing(rules: 1), hardblank: "$", leftWidth: 1, rightWidth: 2) == nil)
    }

    @Test func modesOnTheTinyFont() throws {
        let font = try Self.parse(Self.tinyFont())
        #expect(Self.lines(font, "AB", .fullWidth) == ["/\\|)", "|||)"])
        #expect(Self.lines(font, "A A", .fullWidth) == ["/\\  /\\", "||  ||"])
        // Fitting: A's right column touches B's left column, nothing overlaps.
        #expect(Self.lines(font, "AB", .fitting) == ["/\\|)", "|||)"])
        // Smushing with the font's rules: this font has none, so it is universal smushing.
        #expect(Self.lines(font, "AB", .smushing) == ["/|)", "||)"])
        // With the equal rule only, the top row (\ against |) cannot smush, so nothing does.
        let equal = try Self.parse(Self.tinyFont(layout: "-1 1 0 129"))
        #expect(Self.lines(equal, "AB") == ["/\\|)", "|||)"])
    }

    @Test func hardblankBecomesSpaceOnlyInOutput() throws {
        let font = try Self.parse(Self.tinyFont())
        let region = TextArt.render("A A", font: .figlet(font), options: TextArtOptions()).region
        #expect(region.cells.allSatisfy { row in !row.contains { $0.code == UInt8(ascii: "$") } })
    }

    @Test func hostileInputNeverTraps() {
        var rng = SplitMix(seed: 0xF1_6E_7)
        let base = Array(Self.tinyFont().utf8)
        var parsed = 0
        for round in 0..<2000 {
            var bytes = base
            if round % 2 == 0 {
                for _ in 0..<(1 + Int(rng.next() % 10)) {
                    bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next())
                }
            } else {
                bytes = Array(bytes.prefix(Int(rng.next() % UInt64(bytes.count))))
            }
            if let font = try? FIGletFont.parse(Data(bytes), name: "Fuzz") {
                parsed += 1
                _ = TextArt.render("AB A_|\nB", font: .figlet(font), options: TextArtOptions())
            }
        }
        #expect(parsed > 0)
        #expect(throws: FIGletError.tooLarge) { try FIGletFont.parse(Data(count: FIGletFont.maxFileSize + 1), name: "x") }
    }

    // MARK: figlet's own reference output (tests/res004, res009, res010, res011 of figlet 2.2.5)

    static let joshkDefault = [
        "  __ _           _     _    __  ",
        " / /(_) ___  ___| |__ | | __\\ \\ ",
        "/ / | |/ _ \\/ __| '_ \\| |/ / \\ \\",
        "\\ \\ | | (_) \\__ \\ | | |   <  / /",
        " \\_\\/ |\\___/|___/_| |_|_|\\_\\/_/ ",
        "  |__/                          ",
    ]
    static let joshkKerning = [
        "  __  _              _      _    __  ",
        " / / (_)  ___   ___ | |__  | | __\\ \\ ",
        "/ /  | | / _ \\ / __|| '_ \\ | |/ / \\ \\",
        "\\ \\  | || (_) |\\__ \\| | | ||   <  / /",
        " \\_\\_/ | \\___/ |___/|_| |_||_|\\_\\/_/ ",
        "   |__/                              ",
    ]
    static let joshkFullWidth = [
        "   __    _                 _       _     __  ",
        "  / /   (_)   ___    ___  | |__   | | __ \\ \\ ",
        " / /    | |  / _ \\  / __| | '_ \\  | |/ /  \\ \\",
        " \\ \\    | | | (_) | \\__ \\ | | | | |   <   / /",
        "  \\_\\  _/ |  \\___/  |___/ |_| |_| |_|\\_\\ /_/ ",
        "      |__/                                   ",
    ]
    static let joshkOverlap = [
        "  __ _           _     _   __  ",
        " / /(_) ___  ___| |__ | | _\\ \\ ",
        "/ / | |/ _ \\/ __| '_ \\| |/ /\\ \\",
        "\\ \\ | | (_) \\__ | | | |   < / /",
        " \\__/ |\\___/|___|_| |_|_|\\_/_/ ",
        "  |__/                         ",
    ]

    @Test func matchesFigletReferenceOutput() throws {
        let url = try #require(FIGletFont.bundledURLs.first { $0.lastPathComponent == "standard.flf" })
        let font = try FIGletFont.parse(Data(contentsOf: url), name: "standard")
        #expect(Self.lines(font, "<joshk>") == Self.joshkDefault)
        #expect(Self.lines(font, "<joshk>", .fitting) == Self.joshkKerning)
        #expect(Self.lines(font, "<joshk>", .fullWidth) == Self.joshkFullWidth)
        #expect(Self.lines(font, "<joshk>", .universal) == Self.joshkOverlap)
    }

    @Test func everyBundledFIGletFontParses() throws {
        #expect(FIGletFont.bundledURLs.count == 18)
        for url in FIGletFont.bundledURLs {
            let font = try FIGletFont.parse(Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
            #expect(font.glyphs.count >= 95, "\(url.lastPathComponent)")
            let region = TextArt.render("Hello", font: .figlet(font), options: TextArtOptions()).region
            #expect(region.height >= 1, "\(url.lastPathComponent)")
        }
    }

    @Test func verticalLayouts() throws {
        let font = try FIGletFont.parse(Data(contentsOf: FIGletFont.bundledURLs.first { $0.lastPathComponent == "standard.flf" }!),
                                        name: "standard")
        var options = TextArtOptions()
        options.horizontalLayout = .fontDefault
        options.verticalLayout = .fullWidth
        let full = TextArt.render("A\nB", font: .figlet(font), options: options).region
        #expect(full.height == 12)
        options.verticalLayout = .fitting
        let fitted = TextArt.render("A\nB", font: .figlet(font), options: options).region
        // standard's A has one blank row at the bottom and B one at the bottom too; B's top
        // row has `____`, so fitting removes only the blank row(s) between them.
        #expect(fitted.height < 12 && fitted.height >= 10)
        options.verticalLayout = .smushing
        let smushed = TextArt.render("A\nB", font: .figlet(font), options: options).region
        #expect(smushed.height <= fitted.height)
    }

    @Test func verticalSmushRules() {
        func v(_ top: Character, _ bottom: Character, _ rules: Int) -> Character? {
            FIGletFont.smushVertical(top.unicodeScalars.first!, bottom.unicodeScalars.first!,
                                     mode: .smushing(rules: rules)).map { Character($0) }
        }
        #expect(v("x", "x", 1) == "x")
        #expect(v("_", "|", 2) == "|" && v("|", "_", 2) == "|")
        #expect(v("|", "/", 4) == "/")
        #expect(v("-", "_", 8) == "=" && v("_", "-", 8) == "=")
        #expect(v("|", "|", 16) == "|")
        #expect(v("a", "b", 0) == "b")
        #expect(v("a", "b", 1) == nil)
    }
}
