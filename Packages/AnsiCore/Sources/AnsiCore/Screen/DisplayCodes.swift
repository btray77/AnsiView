import Foundation

// BBS display codes per package (screen designer plan, "Research"). Every code here is cited
// in `source`; packages or codes without a source are left out and listed in the plan.

/// A value a display code shows; the preview fills it from `SampleValues`.
public enum ScreenField: String, Codable, CaseIterable, Equatable {
    case userHandle, realName, firstName, bbsName, sysop, node, time, date, location, calls, timeLeft, lastOn,
         messageArea, fileArea, securityLevel, version

    public var label: String {
        switch self {
        case .userHandle: return "User name (alias)"
        case .realName: return "Real name"
        case .firstName: return "First name"
        case .bbsName: return "BBS name"
        case .sysop: return "SysOp name"
        case .node: return "Node number"
        case .time: return "Time"
        case .date: return "Date"
        case .location: return "User's location"
        case .calls: return "User's calls"
        case .timeLeft: return "Time left (minutes)"
        case .lastOn: return "Last call date"
        case .messageArea: return "Message area / conference"
        case .fileArea: return "File area"
        case .securityLevel: return "Security level"
        case .version: return "BBS software version"
        }
    }

    public var defaultSample: String {
        switch self {
        case .userHandle: return "Night Owl"
        case .realName: return "Sam Caller"
        case .firstName: return "Night"
        case .bbsName: return "My BBS"
        case .sysop: return "The SysOp"
        case .node: return "1"
        case .time: return "10:42 pm"
        case .date: return "10/30/26"
        case .location: return "Springfield, IL"
        case .calls: return "42"
        case .timeLeft: return "58"
        case .lastOn: return "10/29/26"
        case .messageArea: return "General Chat"
        case .fileArea: return "ANSI Art Packs"
        case .securityLevel: return "50"
        case .version: return "1.0"
        }
    }
}

/// The values the preview shows for display codes, editable in the Sample Values sheet.
public struct SampleValues: Codable, Equatable {
    public var values: [String: String] = [:]

    public init() {}

    public subscript(field: ScreenField) -> String {
        get { values[field.rawValue] ?? field.defaultSample }
        set { values[field.rawValue] = newValue }
    }
}

/// What a code does when it is not a value.
public enum DisplayAction: String, Equatable {
    case clearScreen, newline, pause, home, clearToEndOfLine, beep, delay, view
}

public enum DisplayCodeGroup: String, CaseIterable, Equatable {
    case user, system, time, screen, colour, view

    public var label: String {
        switch self {
        case .user: return "Caller"
        case .system: return "System"
        case .time: return "Time and date"
        case .screen: return "Screen control"
        case .colour: return "Colours"
        case .view: return "Menu views (theme.hjson)"
        }
    }
}

/// One code the picker can insert.
public struct DisplayCode: Identifiable, Equatable {
    public let package: BBSPackage
    /// The text inserted into the art, exactly as the BBS reads it.
    public let token: String
    public let title: String
    public let group: DisplayCodeGroup
    public let field: ScreenField?
    public let action: DisplayAction?
    /// The DOS attribute a colour code sets (foreground only: low nibble; background: 0x10 | index).
    public let colour: ColourEffect?

    public var id: String { package.rawValue + ":" + token }

    /// What the code shows, for the picker and its tooltip.
    public var help: String {
        if let field { return "Shows the \(field.label.lowercased()). Preview: the sample value." }
        if let colour { return colour.help }
        switch action {
        case .clearScreen: return "Clears the screen and homes the cursor."
        case .newline: return "Starts a new line (CR LF)."
        case .pause: return "Waits for a key (the preview carries on)."
        case .home: return "Moves the cursor to the top left."
        case .clearToEndOfLine: return "Clears to the end of the line."
        case .beep: return "Beeps."
        case .delay: return "Pauses the output briefly."
        case .view: return "A menu view placed by theme.hjson; the preview shows its name."
        case nil: return title
        }
    }
}

/// How a colour code changes the current attribute.
public enum ColourEffect: Equatable {
    case foreground(Int)
    case background(Int)
    /// Background 0 to 7 with the high bit (iCE bright background, or blink without iCE).
    case highBackground(Int)

    var help: String {
        switch self {
        case .foreground(let i): return "Foreground colour \(i): \(ColourEffect.names[i])."
        case .background(let i): return "Background colour \(i): \(ColourEffect.names[i])."
        case .highBackground(let i): return "Bright background \(ColourEffect.names[i + 8]) with iCE colours, else \(ColourEffect.names[i]) with blinking text."
        }
    }

    static let names = ["black", "blue", "green", "cyan", "red", "magenta", "brown", "light grey", "dark grey",
                        "light blue", "light green", "light cyan", "light red", "light magenta", "yellow", "white"]
}

public enum DisplayCodeCatalog {
    /// Two digit pipe colours below `limit`: 00 to 15 foreground, 16 to 23 background, 24 to 31
    /// bright background (iCE) or blink.
    private static func pipeColours(_ package: BBSPackage, limit: Int) -> [DisplayCode] {
        (0..<limit).map { n in
            let effect: ColourEffect = n < 16 ? .foreground(n) : n < 24 ? .background(n - 16) : .highBackground(n - 24)
            let name = n < 16 ? ColourEffect.names[n] : n < 24 ? "on " + ColourEffect.names[n - 16] : "on bright " + ColourEffect.names[n - 16]
            return DisplayCode(package: package, token: String(format: "|%02d", n), title: name.capitalized, group: .colour,
                               field: nil, action: nil, colour: effect)
        }
    }

    /// Ctrl-A colour letters in VGA attribute order (black, blue, green, cyan, red, magenta, yellow, white).
    public static let synchronetLetters: [Character] = ["K", "B", "G", "C", "R", "M", "Y", "W"]

    /// The colour codes a syntax offers in the picker.
    static func colourCodes(_ syntax: ColourSyntax, package: BBSPackage) -> [DisplayCode] {
        func code(_ token: String, _ title: String, _ effect: ColourEffect?) -> DisplayCode {
            DisplayCode(package: package, token: token, title: title, group: .colour, field: nil, action: nil, colour: effect)
        }
        switch syntax {
        case .ctrlA:
            var list = synchronetLetters.enumerated().map { index, letter in
                code("\u{01}\(letter)", "Ctrl-A \(letter): \(ColourEffect.names[index]) text", .foreground(index))
            }
            list += (0..<8).map { digit in
                let vga = Palette.ansiToVGA[digit]
                return code("\u{01}\(digit)", "Ctrl-A \(digit): \(ColourEffect.names[vga]) background", .background(vga))
            }
            return list + [code("\u{01}H", "Ctrl-A H: high intensity", nil), code("\u{01}I", "Ctrl-A I: blink", nil),
                           code("\u{01}E", "Ctrl-A E: bright background (iCE)", nil), code("\u{01}N", "Ctrl-A N: normal", nil)]
        case .pipes(let limit): return pipeColours(package, limit: limit)
        case .wwiv:
            return pipeColours(package, limit: 24) + (0..<10).map { digit in
                code("\u{03}\(digit)", "Heart \(digit): user colour \(digit)", nil)
            }
        case .atX:
            // A useful subset of the 256: every foreground on black, bright white on each background,
            // and blinking white. @X00 and @XFF are left out (they save and restore the colour).
            let pairs = (1..<16).map { (0, $0) } + (1..<8).map { ($0, 15) } + [(8, 15)]
            return pairs.map { bg, fg in
                code(String(format: "@X%X%X", bg, fg),
                     "\(ColourEffect.names[fg].capitalized) on \(ColourEffect.names[bg & 7])\(bg >= 8 ? ", blinking" : "")", .foreground(fg))
            }
        case .atHexAt:
            return (1..<16).map { fg in code(String(format: "@0%X@", fg), "\(ColourEffect.names[fg].capitalized) on black", .foreground(fg)) }
        case .celerity:
            return BBSDisplay.celerityLetters.enumerated().map { i, l in code("|\(l)", "|\(l): \(ColourEffect.names[i]) text", .foreground(i)) }
                + [code("|S", "|S: swap text and background", nil), code("|X", "|X: blink on", nil), code("|x", "|x: blink off", nil)]
        case .ctrlKBracket:
            let pairs = (1..<16).map { (0, $0) } + (1..<8).map { ($0, 15) } + [(8, 15)]
            return pairs.map { bg, fg in
                code(String(format: "\u{0B}[%X%X", bg, fg),
                     "\(ColourEffect.names[fg].capitalized) on \(ColourEffect.names[bg & 7])\(bg >= 8 ? ", blinking" : "")", .foreground(fg))
            }
        case .impulse:
            return (0..<16).map { code(String(format: "%%%02d", $0), "\(ColourEffect.names[$0].capitalized) text", .foreground($0)) }
                + (0..<16).map { code(String(format: "%%B%X", $0), "On \(ColourEffect.names[$0 & 7])\($0 >= 8 ? ", bright (iCE) or blinking" : "")",
                                      $0 < 8 ? .background($0) : .highBackground($0 - 8)) }
        case .searchlight:
            return BBSDisplay.searchlightNames.enumerated().map { i, n in code("\\\(n)", "\\\(n): \(ColourEffect.names[i]) text", .foreground(i)) }
                + [code("\\IV", "\\IV: inverse (text colour becomes the background)", nil), code("\\BI", "\\BI: blink", nil),
                   code("\\NO", "\\NO: normal", nil)]
        case .mecca:
            return BBSDisplay.meccaNames.enumerated().map { i, n in code("[\(n)]", "[\(n)]: \(ColourEffect.names[i]) text", .foreground(i)) }
                + (1..<8).map { code("[white on \(BBSDisplay.meccaNames[$0])]", "White on \(ColourEffect.names[$0])", .foreground(15)) }
                + [code("[blink]", "[blink]: blinking text", nil), code("[steady]", "[steady]: stop blinking", nil)]
        case .none: return []
        }
    }

    private static let all: [BBSPackage: [DisplayCode]] = {
        var map: [BBSPackage: [DisplayCode]] = [:]
        for definition in BBSPackageRegistry.definitions {
            let package = definition.package
            map[package] = definition.codes.map {
                DisplayCode(package: package, token: $0.0, title: $0.1, group: $0.2, field: $0.3, action: $0.4, colour: nil)
            } + colourCodes(definition.colours, package: package)
        }
        return map
    }()

    public static func codes(_ package: BBSPackage) -> [DisplayCode] { all[package] ?? [] }

    /// The code a template uses for `field` (the first one listed), nil when the package has none.
    public static func placeholder(_ field: ScreenField, package: BBSPackage) -> String? {
        codes(package).first { $0.field == field && !$0.token.hasPrefix("\u{01}") }?.token
    }

    /// Codes whose token, title or help contain every word of `query`, grouped in picker order.
    public static func search(_ query: String, package: BBSPackage) -> [(group: DisplayCodeGroup, codes: [DisplayCode])] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let matching = codes(package).filter { code in
            let haystack = (printable(code.token) + " " + code.title + " " + code.help).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return DisplayCodeGroup.allCases.compactMap { group in
            let inGroup = matching.filter { $0.group == group }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }

    /// A token as shown in lists: Ctrl-A as "^A", Ctrl-C as "^C".
    public static func printable(_ token: String) -> String {
        token.replacingOccurrences(of: "\u{01}", with: "^A").replacingOccurrences(of: "\u{03}", with: "^C")
    }
}
