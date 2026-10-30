import Foundation

public enum ComponentGroup: String, CaseIterable, Equatable {
    case headers, frames, legends, status, separators, logos

    public var label: String {
        switch self {
        case .headers: return "Headers"
        case .frames: return "Frames and borders"
        case .legends: return "Hotkey legends"
        case .status: return "Status lines"
        case .separators: return "Separators"
        case .logos: return "Logos"
        }
    }
}

/// What a built-in component is made with (the Component Library's controls).
public struct ComponentOptions: Equatable {
    public var width: Int
    public var height: Int
    public var colour: Int
    /// Header title, or the logo's text.
    public var text: String
    public var package: BBSPackage
    public var samples: SampleValues
    /// The logo font; nil uses AV Ember.
    public var font: TextArtFont?

    public init(width: Int = 78, height: Int = 8, colour: Int = 9, text: String = "Title", package: BBSPackage = .synchronet,
                samples: SampleValues = SampleValues(), font: TextArtFont? = nil) {
        self.width = width
        self.height = height
        self.colour = colour
        self.text = text
        self.package = package
        self.samples = samples
        self.font = font
    }

    var template: TemplateOptions { TemplateOptions(columns: width, bbsName: text, package: package, logoFont: font, samples: samples) }
}

/// A reusable piece of screen, inserted as a floating paste.
public struct ScreenComponent: Identifiable {
    public let id: String
    public let title: String
    public let group: ComponentGroup
    public let help: String
    let build: (ComponentOptions) -> CanvasRegion

    public func make(_ options: ComponentOptions) -> CanvasRegion {
        var options = options
        options.width = max(8, min(EditCanvas.maxColumns, options.width))
        options.height = max(3, min(60, options.height))
        return build(options)
    }
}

public enum ScreenComponents {
    private static func region(_ width: Int, _ height: Int, _ draw: (inout ScreenBuilder) -> Void) -> CanvasRegion {
        var b = ScreenBuilder(columns: width, rows: height)
        draw(&b)
        return b.region
    }

    private static func frame(_ id: String, _ title: String, _ style: ShapeStyle) -> ScreenComponent {
        ScreenComponent(id: id, title: title, group: .frames, help: "A \(title.lowercased()) drawn with the box tool's style; set its width and height.") { o in
            region(o.width, o.height) { $0.box(CellRect(x: 0, y: 0, width: o.width, height: o.height), style: style, fg: o.colour,
                                               title: o.text == "Title" ? "" : o.text, titleColour: 15) }
        }
    }

    private static func separator(_ id: String, _ title: String, _ draw: @escaping (inout ScreenBuilder, ComponentOptions) -> Void) -> ScreenComponent {
        ScreenComponent(id: id, title: title, group: .separators, help: "A one row \(title.lowercased()) across the width.") { o in
            region(o.width, 1) { draw(&$0, o) }
        }
    }

    public static let all: [ScreenComponent] = [
        ScreenComponent(id: "header-bar", title: "Title bar", group: .headers, help: "A coloured bar with shaded ends and the title in the middle.") { o in
            region(o.width, 1) { b in
                let bg = o.colour & 7
                b.fill(CellRect(x: 0, y: 0, width: o.width, height: 1), code: 0x20, fg: 15, bg: bg)
                b.gradientBar(x: 0, y: 0, length: min(6, o.width / 4), fg: bg + 8, bg: bg)
                b.gradientBar(x: o.width - min(6, o.width / 4), y: 0, length: min(6, o.width / 4), fg: bg + 8, bg: bg)
                b.centred(o.text, y: 0, fg: 15, bg: bg)
            }
        },
        ScreenComponent(id: "header-underlined", title: "Underlined heading", group: .headers, help: "The title over a double line.") { o in
            region(o.width, 2) { b in
                b.text(o.text, x: 1, y: 0, fg: 15)
                b.hline(x: 0, y: 1, length: o.width, code: 0xCD, fg: o.colour)
            }
        },
        ScreenComponent(id: "header-boxed", title: "Boxed heading", group: .headers, help: "The title centred in a three row box.") { o in
            region(o.width, 3) { b in
                b.box(CellRect(x: 0, y: 0, width: o.width, height: 3), style: .line(.single), fg: o.colour)
                b.centred(o.text, y: 1, fg: 15)
            }
        },
        frame("frame-single", "Single line frame", .line(.single)),
        frame("frame-double", "Double line frame", .line(.double)),
        frame("frame-single-double", "Frame, single across and double down", .line(.singleHDoubleV)),
        frame("frame-double-single", "Frame, double across and single down", .line(.doubleHSingleV)),
        frame("frame-half", "Half block frame", .halfBlock),
        frame("frame-solid", "Solid block frame", .solid),
        frame("frame-shade", "Shaded frame", .shade(1)),
        ScreenComponent(id: "legend-hotkeys", title: "Hotkey legend", group: .legends, help: "[A] Area  [M] Messages  [F] Files  [Q] Quit, in one row; edit the labels after inserting.") { o in
            region(o.width, 1) { b in
                var x = 1
                for (key, label) in [("A", "Area"), ("M", "Messages"), ("F", "Files"), ("D", "Doors"), ("G", "Goodbye"), ("Q", "Quit")] {
                    let end = b.hotkey(key, label, x: x, y: 0, keyColour: 15, bracketColour: o.colour, fg: 7)
                    if end > o.width { break }
                    x = end + 2
                }
            }
        },
        ScreenComponent(id: "legend-navigation", title: "Next / previous / quit legend", group: .legends, help: "For lists that page: next, previous, quit.") { o in
            region(o.width, 1) { b in
                var x = b.hotkey("N", "Next", x: 1, y: 0, bracketColour: o.colour) + 2
                x = b.hotkey("P", "Previous", x: x, y: 0, bracketColour: o.colour) + 2
                b.hotkey("Q", "Quit", x: x, y: 0, bracketColour: o.colour)
            }
        },
        ScreenComponent(id: "legend-yes-no", title: "Yes / No prompt", group: .legends, help: "A question with [Y]es and [N]o.") { o in
            region(o.width, 1) { b in
                let x = b.text("Continue? ", x: 1, y: 0, fg: 11)
                let y = b.hotkey("Y", "Yes", x: x, y: 0, bracketColour: o.colour) + 2
                b.hotkey("N", "No", x: y, y: 0, bracketColour: o.colour)
            }
        },
        ScreenComponent(id: "status-user", title: "Status line: user, time left, node", group: .status,
                        help: "The chosen BBS's codes for the user name, time left and node; the preview shows the sample values.") { o in
            region(o.width, 1) { b in
                let t = o.template
                var x = b.text(" User: ", x: 0, y: 0, fg: 11, bg: o.colour & 7)
                x = b.field(.userHandle, x: x, y: 0, fg: 15, bg: o.colour & 7, options: t)
                x = b.text("  Time left: ", x: x, y: 0, fg: 11, bg: o.colour & 7)
                x = b.field(.timeLeft, x: x, y: 0, fg: 15, bg: o.colour & 7, options: t)
                x = b.text("  Node: ", x: x, y: 0, fg: 11, bg: o.colour & 7)
                x = b.field(.node, x: x, y: 0, fg: 15, bg: o.colour & 7, options: t)
                b.text(" ", x: x, y: 0, fg: 15, bg: o.colour & 7)
            }
        },
        ScreenComponent(id: "status-time", title: "Status line: date and time", group: .status, help: "The BBS's date and time codes.") { o in
            region(o.width, 1) { b in
                let t = o.template
                var x = b.field(.date, x: 1, y: 0, fg: 7, options: t)
                x = b.text("  ", x: x, y: 0, fg: 8)
                b.field(.time, x: x, y: 0, fg: 7, options: t)
            }
        },
        separator("separator-single", "Single line") { b, o in b.hline(x: 0, y: 0, length: o.width, code: 0xC4, fg: o.colour) },
        separator("separator-double", "Double line") { b, o in b.hline(x: 0, y: 0, length: o.width, code: 0xCD, fg: o.colour) },
        separator("separator-shaded", "Shaded line") { b, o in b.gradientBar(x: 0, y: 0, length: o.width, fg: o.colour) },
        separator("separator-dotted", "Dotted line") { b, o in b.hline(x: 0, y: 0, length: o.width, code: 0xFA, fg: o.colour) },
        separator("separator-wave", "Half block wave") { b, o in
            for x in 0..<o.width { b.canvas.set(ScreenBuilder.cell(x % 2 == 0 ? 0xDC : 0xDF, o.colour), x: x, y: 0) }
        },
        ScreenComponent(id: "logo", title: "Logo in a font", group: .logos,
                        help: "Your text drawn with the chosen TheDraw or FIGlet font (AV Ember when none is chosen).") { o in
            let font = o.font ?? .tdf(OriginalFonts.tdfFonts[2])
            var options = TextArtOptions()
            options.foreground = o.colour
            let rendered = TextArt.render(o.text.isEmpty ? "Logo" : o.text, font: font, options: options).region
            guard rendered.width > 0 else { return region(o.width, 1) { $0.text(o.text, x: 0, y: 0, fg: o.colour) } }
            return CanvasRegion(cells: rendered.cells.map { Array($0.prefix(o.width)) })
        },
    ]

    public static func component(_ id: String) -> ScreenComponent? { all.first { $0.id == id } }
}
