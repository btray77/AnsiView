import Foundation

/// What a template is made for: width, BBS name, the package whose display codes go in, and the
/// hotkey items of menus.
public struct TemplateOptions: Equatable {
    public var columns: Int
    public var bbsName: String
    public var package: BBSPackage
    /// The font of the logo; nil uses AnsiView's own AV Ember.
    public var logoFont: TextArtFont?
    public var samples: SampleValues

    public init(columns: Int = 80, bbsName: String = "My BBS", package: BBSPackage = .synchronet,
                logoFont: TextArtFont? = nil, samples: SampleValues = SampleValues()) {
        self.columns = columns
        self.bbsName = bbsName
        self.package = package
        self.logoFont = logoFont
        self.samples = samples
    }

    /// Rows a template fills: one less than the caller's screen (80 x 24, 132 x 37), so the last
    /// line break never scrolls (preview warning `tallerThanScreen`).
    public var rows: Int { columns >= 132 ? 36 : 23 }
}

/// One New from Template design (original work made for AnsiView, no third party art).
public struct ScreenTemplate: Identifiable {
    public let id: String
    public let title: String
    public let slot: ScreenSlot
    public let summary: String
    public let widths: [Int]
    public let animated: Bool
    let build: (TemplateOptions) -> [AnimationFrame]

    /// The template as an editor project: one frame, or several for animated templates.
    public func make(_ options: TemplateOptions) -> ArtProject {
        var options = options
        if !widths.contains(options.columns) { options.columns = widths.first ?? 80 }
        return ArtProject(frames: build(options))
    }
}

extension ScreenBuilder {
    /// The display code of `field` for the template's package, or the sample value when that
    /// package has no code for it (so the screen still reads right).
    @discardableResult
    mutating func field(_ field: ScreenField, x: Int, y: Int, fg: Int, bg: Int = 0, options: TemplateOptions) -> Int {
        let token = DisplayCodeCatalog.placeholder(field, package: options.package) ?? options.samples[field]
        return text(token, x: x, y: y, fg: fg, bg: bg)
    }

    /// The BBS name drawn with the logo font, centred at row `y`; plain text when it would not fit.
    /// Returns the rows used.
    @discardableResult
    mutating func logo(_ name: String, y: Int, options: TemplateOptions, fg: Int = 14) -> Int {
        let font = options.logoFont ?? .tdf(OriginalFonts.tdfFonts[2])
        var textOptions = TextArtOptions()
        textOptions.foreground = fg
        let region = TextArt.render(name.uppercased(), font: font, options: textOptions).region
        if region.width > 0, region.width <= width - 2 {
            stamp(region, x: max(0, (width - region.width) / 2), y: y)
            return region.height
        }
        centred(name, y: y, fg: fg)
        return 1
    }
}

public enum ScreenTemplates {
    public static let all: [ScreenTemplate] = [
        ScreenTemplate(id: "matrix", title: "Matrix / Login", slot: .matrix,
                       summary: "The first screen: logo, login, new user, guest and disconnect.", widths: [80, 132],
                       animated: false, build: { [matrix($0)] }),
        ScreenTemplate(id: "welcome", title: "Welcome", slot: .welcome,
                       summary: "Greets the caller by name with their call count, last call and node.", widths: [80, 132],
                       animated: false, build: { [welcome($0)] }),
        ScreenTemplate(id: "main-menu", title: "Main Menu", slot: .mainMenu,
                       summary: "Logo, a framed list of hotkeys in columns, status line and prompt.", widths: [80, 132],
                       animated: false, build: { [mainMenu($0)] }),
        ScreenTemplate(id: "goodbye", title: "Goodbye / Logoff", slot: .goodbye,
                       summary: "Thanks the caller and shows when they were on.", widths: [80, 132],
                       animated: false, build: { [goodbye($0)] }),
        ScreenTemplate(id: "bulletins", title: "Bulletin List", slot: .bulletinList,
                       summary: "Numbered bulletins in a frame with a read prompt.", widths: [80, 132],
                       animated: false, build: { [bulletins($0)] }),
        ScreenTemplate(id: "message-header", title: "Message Area Header", slot: .messageHeader,
                       summary: "Area name bar and the column heads of a message list.", widths: [80, 132],
                       animated: false, build: { [messageHeader($0)] }),
        ScreenTemplate(id: "file-area", title: "File Area Header and List", slot: .fileHeader,
                       summary: "File area bar, column heads and sample file lines to restyle.", widths: [80, 132],
                       animated: false, build: { [fileArea($0)] }),
        ScreenTemplate(id: "door-menu", title: "Door Games Menu", slot: .doorMenu,
                       summary: "A framed list of door games with player counts.", widths: [80, 132],
                       animated: false, build: { [doorMenu($0)] }),
        ScreenTemplate(id: "ad", title: "ANSI Ad", slot: .ad,
                       summary: "An advert for other boards: logo, address, software and features.", widths: [80],
                       animated: false, build: { [ad($0)] }),
        ScreenTemplate(id: "loading", title: "Loading / Transition (animated)", slot: .loading,
                       summary: "A progress bar that fills over eight animation frames.", widths: [80, 132],
                       animated: true, build: loading),
    ]

    public static func template(_ id: String) -> ScreenTemplate? { all.first { $0.id == id } }

    // MARK: Designs

    private static func frame(_ b: ScreenBuilder) -> AnimationFrame {
        AnimationFrame(layers: [CanvasLayer(name: "Background", canvas: b.canvas)])
    }

    /// A top bar: shaded ends and the title in the middle. The last column stays empty so the
    /// line break after it never wraps (preview warning `wrapAtLastColumn`).
    private static func titleBar(_ b: inout ScreenBuilder, y: Int, title: String, colour: Int = 1) {
        b.fill(CellRect(x: 0, y: y, width: b.width - 1, height: 1), code: 0x20, fg: 15, bg: colour)
        b.gradientBar(x: 0, y: y, length: 6, fg: colour + 8, bg: colour)
        b.gradientBar(x: b.width - 7, y: y, length: 6, fg: colour + 8, bg: colour)
        b.centred(title, y: y, fg: 15, bg: colour, within: 0..<(b.width - 1))
    }

    /// The bottom status line: user, time left and node codes on a bar. The bar stops after the
    /// codes: values longer than their codes would otherwise push it past the edge.
    private static func statusLine(_ b: inout ScreenBuilder, y: Int, options: TemplateOptions) {
        var x = b.text(" User: ", x: 0, y: y, fg: 11, bg: 1)
        x = b.field(.userHandle, x: x, y: y, fg: 15, bg: 1, options: options)
        x = b.text("  Time left: ", x: x, y: y, fg: 11, bg: 1)
        x = b.field(.timeLeft, x: x, y: y, fg: 15, bg: 1, options: options)
        x = b.text("  Node: ", x: x, y: y, fg: 11, bg: 1)
        x = b.field(.node, x: x, y: y, fg: 15, bg: 1, options: options)
        b.text(" ", x: x, y: y, fg: 15, bg: 1)
    }

    private static func prompt(_ b: inout ScreenBuilder, y: Int, _ text: String) {
        let x = b.text(text, x: 1, y: y, fg: 11)
        b.text(": ", x: x, y: y, fg: 8)
    }

    /// Hotkeys in a frame, laid out in as many columns as fit.
    private static func hotkeyFrame(_ b: inout ScreenBuilder, y: Int, height: Int, title: String,
                                    items: [(String, String)], colour: Int = 9) {
        let rect = CellRect(x: 2, y: y, width: b.width - 4, height: height)
        b.box(rect, style: .line(.double), fg: colour, title: title, titleColour: 15)
        let columns = b.width >= 132 ? 3 : 2
        let perColumn = max(1, Int((Double(items.count) / Double(columns)).rounded(.up)))
        let columnWidth = (rect.width - 4) / columns
        for (index, item) in items.enumerated() {
            let column = index / perColumn, row = index % perColumn
            guard row < height - 2 else { continue }
            b.hotkey(item.0, item.1, x: rect.x + 3 + column * columnWidth, y: y + 1 + row, keyColour: 14, bracketColour: 3, fg: 7)
        }
    }

    static func mainMenu(_ o: TemplateOptions) -> AnimationFrame {
        var b = ScreenBuilder(columns: o.columns, rows: o.rows)
        titleBar(&b, y: 0, title: "Main Menu")
        let logoRows = b.logo(o.bbsName, y: 2, options: o)
        let top = 2 + logoRows + 1
        let items: [(String, String)] = [("M", "Message areas"), ("F", "File areas"), ("D", "Door games"), ("B", "Bulletins"),
                                         ("W", "Who is online"), ("U", "User settings"), ("C", "Chat with the SysOp"), ("G", "Goodbye")]
        let frameHeight = max(4, min(o.rows - top - 3, (items.count + 1) / (o.columns >= 132 ? 3 : 2) + 3))
        hotkeyFrame(&b, y: top, height: frameHeight, title: "Main Menu", items: items)
        statusLine(&b, y: o.rows - 2, options: o)
        prompt(&b, y: o.rows - 1, "Command")
        return frame(b)
    }

    static func matrix(_ o: TemplateOptions) -> AnimationFrame {
        var b = ScreenBuilder(columns: o.columns, rows: o.rows)
        for y in 0..<o.rows where y % 4 == 0 { b.hline(x: 0, y: y, length: o.columns - 1, code: 0xFA, fg: 8) }
        let logoRows = b.logo(o.bbsName, y: 3, options: o, fg: 11)
        let y = 3 + logoRows + 2
        let box = CellRect(x: o.columns / 2 - 20, y: y, width: 40, height: 7)
        b.box(box, style: .line(.single), fg: 3, filled: true, title: "Welcome, traveller", titleColour: 11)
        b.hotkey("L", "Log in", x: box.x + 4, y: y + 2, keyColour: 15, bracketColour: 3, fg: 7)
        b.hotkey("N", "New user", x: box.x + 21, y: y + 2, keyColour: 15, bracketColour: 3, fg: 7)
        b.hotkey("G", "Guest", x: box.x + 4, y: y + 4, keyColour: 15, bracketColour: 3, fg: 7)
        b.hotkey("D", "Disconnect", x: box.x + 21, y: y + 4, keyColour: 15, bracketColour: 3, fg: 7)
        var x = b.text("Node ", x: 2, y: o.rows - 1, fg: 8)
        x = b.field(.node, x: x, y: o.rows - 1, fg: 7, options: o)
        x = b.text("   ", x: x, y: o.rows - 1, fg: 8)
        x = b.field(.date, x: x, y: o.rows - 1, fg: 7, options: o)
        x = b.text(" ", x: x, y: o.rows - 1, fg: 8)
        b.field(.time, x: x, y: o.rows - 1, fg: 7, options: o)
        return frame(b)
    }

    static func welcome(_ o: TemplateOptions) -> AnimationFrame {
        var b = ScreenBuilder(columns: o.columns, rows: o.rows)
        titleBar(&b, y: 0, title: "Welcome", colour: 2)
        let logoRows = b.logo(o.bbsName, y: 2, options: o, fg: 10)
        var y = 2 + logoRows + 2
        let left = o.columns / 2 - 22
        var x = b.text("Welcome back, ", x: left, y: y, fg: 7)
        x = b.field(.userHandle, x: x, y: y, fg: 15, options: o)
        b.text("!", x: x, y: y, fg: 7)
        y += 2
        let lines: [(String, ScreenField)] = [("You have called ", .calls), ("Your last call was ", .lastOn),
                                              ("You are on node ", .node), ("Time left today: ", .timeLeft)]
        for (label, field) in lines {
            let x = b.text(label, x: left, y: y, fg: 2)
            b.field(field, x: x, y: y, fg: 10, options: o)
            y += 1
        }
        b.gradientBar(x: 0, y: o.rows - 2, length: o.columns - 1, fg: 2)
        b.centred("Press any key to continue", y: o.rows - 1, fg: 8)
        return frame(b)
    }

    static func goodbye(_ o: TemplateOptions) -> AnimationFrame {
        var b = ScreenBuilder(columns: o.columns, rows: o.rows)
        let logoRows = b.logo(o.bbsName, y: 2, options: o, fg: 13)
        var y = 2 + logoRows + 2
        let thanks = "Thanks for calling, "
        let token = DisplayCodeCatalog.placeholder(.userHandle, package: o.package) ?? o.samples[.userHandle]
        var x = max(0, (o.columns - thanks.count - token.count - 1) / 2)
        x = b.text(thanks, x: x, y: y, fg: 5)
        x = b.field(.userHandle, x: x, y: y, fg: 13, options: o)
        b.text(".", x: x, y: y, fg: 5)
        y += 2
        b.centred("Come back soon. The board is always on.", y: y, fg: 7)
        y += 2
        let wave: [UInt8] = [0xDC, 0xDF]
        for column in 0..<(o.columns - 1) {
            b.canvas.set(ScreenBuilder.cell(wave[column % 2], column % 8 < 4 ? 5 : 13), x: column, y: y)
        }
        x = b.text("You were on until ", x: 2, y: o.rows - 1, fg: 8)
        b.field(.time, x: x, y: o.rows - 1, fg: 7, options: o)
        return frame(b)
    }

    static func bulletins(_ o: TemplateOptions) -> AnimationFrame {
        var b = ScreenBuilder(columns: o.columns, rows: o.rows)
        titleBar(&b, y: 0, title: "Bulletins", colour: 4)
        let titles = ["House rules", "New this month", "How to upload", "Message networks", "Door game scores",
                      "Meet the SysOp", "Board history", "Other boards worth a call"]
        let rect = CellRect(x: 2, y: 2, width: o.columns - 4, height: titles.count + 4)
        b.box(rect, style: .line(.single), fg: 4, title: "Read a bulletin", titleColour: 12)
        for (index, title) in titles.enumerated() {
            let x = b.hotkey("\(index + 1)", "", x: rect.x + 3, y: rect.y + 2 + index, keyColour: 15, bracketColour: 4, fg: 7)
            b.text(title, x: x, y: rect.y + 2 + index, fg: 7)
            b.hline(x: rect.x + 34, y: rect.y + 2 + index, length: rect.width - 40, code: 0xFA, fg: 8)
        }
        prompt(&b, y: o.rows - 1, "Bulletin number, [Enter] to quit")
        return frame(b)
    }

    static func messageHeader(_ o: TemplateOptions) -> AnimationFrame {
        var b = ScreenBuilder(columns: o.columns, rows: 6)
        titleBar(&b, y: 0, title: "Messages", colour: 5)
        var x = b.text(" Area: ", x: 0, y: 2, fg: 13)
        x = b.field(.messageArea, x: x, y: 2, fg: 15, options: o)
        b.text(" on ", x: x, y: 2, fg: 5)
        b.field(.bbsName, x: x + 4, y: 2, fg: 13, options: o)
        let heads: [(String, Int)] = o.columns >= 132
            ? [("#", 1), ("From", 8), ("To", 34), ("Subject", 60), ("Date", 116)]
            : [("#", 1), ("From", 7), ("To", 24), ("Subject", 41), ("Date", 70)]
        for (head, column) in heads { b.text(head, x: column, y: 4, fg: 15) }
        b.hline(x: 0, y: 5, length: o.columns - 1, code: 0xC4, fg: 5)
        return frame(b)
    }

    static func fileArea(_ o: TemplateOptions) -> AnimationFrame {
        var b = ScreenBuilder(columns: o.columns, rows: 14)
        titleBar(&b, y: 0, title: "Files", colour: 3)
        var x = b.text(" Area: ", x: 0, y: 2, fg: 11)
        x = b.field(.fileArea, x: x, y: 2, fg: 15, options: o)
        let heads: [(String, Int)] = [("File name", 1), ("Size", 15), ("Date", 23), ("Description", 34)]
        for (head, column) in heads { b.text(head, x: column, y: 4, fg: 15) }
        b.hline(x: 0, y: 5, length: o.columns - 1, code: 0xCD, fg: 3)
        let files = [("NEWSLTR.ZIP", "112k", "Board newsletter, this month"), ("ANSIPACK.ZIP", "1.4M", "Art pack from local artists"),
                     ("TERMINAL.ZIP", "640k", "A terminal program for callers"), ("README.TXT", "4k", "Start here")]
        for (index, file) in files.enumerated() {
            let y = 6 + index * 2
            b.text(file.0, x: 1, y: y, fg: 14)
            b.text(file.1, x: 15, y: y, fg: 10)
            b.text("01-01-99", x: 23, y: y, fg: 2)
            b.text(file.2, x: 34, y: y, fg: 7)
        }
        b.hline(x: 0, y: 13, length: o.columns - 1, code: 0xC4, fg: 3)
        x = b.text(" ", x: 0, y: 13, fg: 3)
        return frame(b)
    }

    static func doorMenu(_ o: TemplateOptions) -> AnimationFrame {
        var b = ScreenBuilder(columns: o.columns, rows: o.rows)
        titleBar(&b, y: 0, title: "Door Games", colour: 6)
        let logoRows = b.logo("Doors", y: 2, options: o, fg: 14)
        let top = 2 + logoRows + 1
        let games: [(String, String)] = [("1", "Star Freighter"), ("2", "Dungeon of Echoes"), ("3", "Word Ladder"), ("4", "Trivia Night"),
                                         ("5", "Galactic Poker"), ("6", "Rocket Golf"), ("Q", "Back to the main menu")]
        let frameHeight = max(4, min(o.rows - top - 2, (games.count + 1) / (o.columns >= 132 ? 3 : 2) + 3))
        hotkeyFrame(&b, y: top, height: frameHeight, title: "Choose a game", items: games, colour: 6)
        prompt(&b, y: o.rows - 1, "Game")
        return frame(b)
    }

    static func ad(_ o: TemplateOptions) -> AnimationFrame {
        var b = ScreenBuilder(columns: o.columns, rows: 20)
        // Codes stay outside the frame: a value longer than its code would push the right edge out.
        b.box(CellRect(x: 0, y: 0, width: o.columns - 1, height: 18), style: .halfBlock, fg: 12)
        let logoRows = b.logo(o.bbsName, y: 2, options: o)
        var y = 2 + logoRows + 1
        b.centred("telnet://bbs.example.com", y: y, fg: 15)
        y += 2
        let features = ["Message networks and local echoes", "Files: art packs, utilities, text files",
                        "Door games with daily scores", "No ratios, new users welcome"]
        for feature in features {
            b.centred("\u{25A0} " + feature, y: y, fg: 7)
            y += 1
        }
        let x = b.text("SysOp: ", x: 2, y: 19, fg: 12)
        b.field(.sysop, x: x, y: 19, fg: 15, options: o)
        return frame(b)
    }

    static func loading(_ o: TemplateOptions) -> [AnimationFrame] {
        let steps = 8
        let barWidth = min(50, o.columns - 20)
        return (0...steps).map { step in
            var b = ScreenBuilder(columns: o.columns, rows: 9)
            b.centred("Loading", y: 2, fg: 15)
            let x = (o.columns - barWidth - 2) / 2
            b.text("[", x: x, y: 4, fg: 8)
            b.text("]", x: x + barWidth + 1, y: 4, fg: 8)
            let filled = barWidth * step / steps
            for column in 0..<barWidth {
                b.canvas.set(ScreenBuilder.cell(column < filled ? 0xDB : 0xB0, column < filled ? 11 : 8), x: x + 1 + column, y: 4)
            }
            b.centred("\(step * 100 / steps)%", y: 6, fg: 3)
            var frame = frame(b)
            frame.delay = step == steps ? 1.0 : 0.15
            return frame
        }
    }
}
