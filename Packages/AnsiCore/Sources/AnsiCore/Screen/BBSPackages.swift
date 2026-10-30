import Foundation

// The BBS package registry (screen designer ruling 1, the owner's "work with ALL BBSes"):
// a package is data, a `BBSPackageDefinition` in `BBSPackageRegistry.definitions`. Its colour
// and text code syntax are chosen from the families below, which the renderer, the encoder and
// the foreign code check implement once. Adding a package with known syntax is a table entry
// plus tests; a new syntax family is a new case here. Packages that cannot be documented from
// real sources are listed in docs/BBS-COMPAT.md, not guessed.

/// How a package writes colours in its own text files.
public enum ColourSyntax: Equatable {
    /// Synchronet Ctrl-A: 0x01 then a letter (K B G C R M Y W in VGA order, ANSI digit backgrounds).
    case ctrlA
    /// Two digit pipes: |00 to |15 foreground, |16 to |23 background, and up to `limit` - 1
    /// (|24 to |31 bright background or blink) where the package documents it.
    case pipes(limit: Int)
    /// WWIV: pipes up to |23, heart codes (Ctrl-C digit) and |#digit user colours.
    case wwiv
    /// PCBoard @Xbf (hex background with the blink bit, hex foreground).
    case atX
    /// Wildcat @bf@.
    case atHexAt
    /// No colour codes of its own (ANSI only).
    case none
}

/// How a package writes value and screen codes.
public enum MacroSyntax: Equatable {
    /// "@NAME@" with Synchronet modifiers after | or - ("|R20", "|Z3", "|U").
    case atSynchronet
    /// "@NAME@" with a PCBoard width after a colon ("@USER:30C@").
    case atPCBoard
    /// Mystic "|XX" letters with "|$L##" padding.
    case pipeLetters
    /// WWIV "|@x" macros and "|[x" cursor codes.
    case wwivMacros
    /// "%XX"; case blind for Renegade; ENiGMA adds view codes with a number ("%TL1").
    case percent(caseBlind: Bool, views: Bool)
}

/// How a package names a screen file for a wider terminal.
public enum WidthSuffix: Equatable {
    case none
    /// Synchronet "main.132col.ans".
    case columnsCol
    /// Mystic "test.c132.ans".
    case cColumns
}

public enum NameCase: String, Codable, Equatable { case lower, upper }

/// The file a slot is exported as, and whether that name is documented.
public struct SlotFile: Equatable {
    /// Path from the BBS folder without extension ("text/menu/main").
    public let path: String
    /// Where the name is documented; nil when it is AnsiView's suggestion.
    public let source: String?

    public init(_ path: String, source: String?) {
        self.path = path
        self.source = source
    }
}

/// Folder layout and file naming of a package's display files.
public struct ScreenFileRules: Equatable {
    /// Folder (from the BBS folder) for slots with no documented name.
    public let folder: String
    public let nameCase: NameCase
    /// Extension for ANSI colour files and for files with the package's own codes.
    public let ansiExtension: String
    public let nativeExtension: String
    /// Extension of a UTF-8 file when the package documents one (nil: UTF-8 not documented).
    public let utf8Extension: String?
    public let widthSuffix: WidthSuffix
    public let slots: [ScreenSlot: SlotFile]
    /// True when the package is documented to stop at the SAUCE end of file marker.
    public let readsSauce: Bool
    /// Base names are cut to 8 characters (DOS packages).
    public let eightDotThree: Bool
    public let notes: String
    /// The path part naming the theme ("default" for Mystic), replaced by a profile's theme name.
    public var themeFolder: String? = nil
}

public struct BBSPackageDefinition {
    public let package: BBSPackage
    public let displayName: String
    public let colourCodeName: String
    public let colours: ColourSyntax
    public let macros: [MacroSyntax]
    public let files: ScreenFileRules
    public let source: String
    /// The package's own value, screen and colour codes (the colour codes are added from `colours`).
    let codes: [DisplayCodeRow]
}

typealias DisplayCodeRow = (String, String, DisplayCodeGroup, ScreenField?, DisplayAction?)

/// A BBS package, identified by a short name. Its definition is in the registry.
public struct BBSPackage: RawRepresentable, Hashable, Codable, CaseIterable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let synchronet = BBSPackage(rawValue: "synchronet")
    public static let mystic = BBSPackage(rawValue: "mystic")
    public static let wwiv = BBSPackage(rawValue: "wwiv")
    public static let enigma = BBSPackage(rawValue: "enigma")
    public static let pcboard = BBSPackage(rawValue: "pcboard")
    public static let wildcat = BBSPackage(rawValue: "wildcat")
    public static let renegade = BBSPackage(rawValue: "renegade")

    public static var allCases: [BBSPackage] { BBSPackageRegistry.definitions.map(\.package) }

    public var definition: BBSPackageDefinition {
        BBSPackageRegistry.definitions.first { $0.package == self } ?? BBSPackageRegistry.definitions[0]
    }

    public var displayName: String { definition.displayName }
    public var colourCodeName: String { definition.colourCodeName }
    public var source: String { definition.source }
    public var description: String { rawValue }
}

public enum BBSPackageRegistry {
    static let syncAt = "https://wiki.synchro.net/custom:atcodes"
    static let syncCtrlA = "https://wiki.synchro.net/custom:ctrl-a_codes"
    static let syncMenus = "https://wiki.synchro.net/custom:menu_files"
    static let syncText = "https://wiki.synchro.net/config:text_files"
    static let mysticCodes = "http://wiki.mysticbbs.com/doku.php?id=displaycodes"
    static let mysticFiles = "http://wiki.mysticbbs.com/doku.php?id=display_files"
    static let wwivDocs = "https://docs.wwivbbs.org (cfg/displaying_text.md)"
    static let enigmaMCI = "https://enigma-bbs.github.io/art/mci/"
    static let enigmaArt = "https://enigma-bbs.github.io/art/general/, misc/menu_templates/*.in.hjson"
    static let pcbGuide = "PCBoard PPL Norton Guide PPEDOC.NG (discmaster.textfiles.com, third party)"
    static let renegadeSource = "Renegade 1.19 source COMMON.PAS and LOGON.PAS (github.com/sikofitt/Renegade)"
    static let synchronetColours = "https://wiki.synchro.net/custom:colors (third party)"

    public static let definitions: [BBSPackageDefinition] = [
        BBSPackageDefinition(
            package: .synchronet, displayName: "Synchronet", colourCodeName: "Ctrl-A codes", colours: .ctrlA, macros: [.atSynchronet],
            files: ScreenFileRules(
                folder: "text/menu", nameCase: .lower, ansiExtension: "ans", nativeExtension: "msg", utf8Extension: "utf8",
                widthSuffix: .columnsCol,
                slots: [.mainMenu: SlotFile("text/menu/main", source: syncMenus), .goodbye: SlotFile("text/menu/logoff", source: syncMenus),
                        .welcome: SlotFile("text/menu/logon", source: syncText), .matrix: SlotFile("text/answer", source: syncText)],
                readsSauce: true, eightDotThree: false,
                notes: "For ANSI callers Synchronet shows .ans before .msg before .asc. A SAUCE record makes it stop at the end of file marker."),
            source: "\(syncCtrlA), \(syncAt), \(syncMenus)",
            codes: [
                ("@ALIAS@", "User's alias", .user, .userHandle, nil), ("@NAME@", "User's alias (NAME)", .user, .userHandle, nil),
                ("@USER@", "User's alias (USER)", .user, .userHandle, nil), ("@FIRST@", "First word of the alias", .user, .firstName, nil),
                ("@REALNAME@", "User's real name", .user, .realName, nil), ("@ADDR2@", "User's location", .user, .location, nil),
                ("@FROM@", "User's location (FROM)", .user, .location, nil), ("@CALLS@", "User's total logons", .user, .calls, nil),
                ("@NUMTIMESON@", "User's total logons (NUMTIMESON)", .user, .calls, nil), ("@TIMELEFT@", "Time left in minutes", .user, .timeLeft, nil),
                ("@MINLEFT@", "Time left in minutes (MINLEFT)", .user, .timeLeft, nil), ("@LASTON@", "User's last logon", .user, .lastOn, nil),
                ("@BBS@", "Name of the BBS", .system, .bbsName, nil), ("@BOARDNAME@", "Name of the BBS (BOARDNAME)", .system, .bbsName, nil),
                ("@SYSOP@", "SysOp's name", .system, .sysop, nil), ("@NODE@", "Current node number", .system, .node, nil),
                ("@NN@", "Current node number (NN)", .system, .node, nil),
                ("@TIME@", "Current system time", .time, .time, nil), ("@SYSTIME@", "Current system time (SYSTIME)", .time, .time, nil),
                ("@DATE@", "Current system date", .time, .date, nil), ("@SYSDATE@", "Current system date (SYSDATE)", .time, .date, nil),
                ("@CLS@", "Clear the screen", .screen, nil, .clearScreen), ("@CRLF@", "New line", .screen, nil, .newline),
                ("@PAUSE@", "Pause for a key", .screen, nil, .pause), ("@HOME@", "Cursor home", .screen, nil, .home),
                ("@CLR2EOL@", "Clear to end of line", .screen, nil, .clearToEndOfLine), ("@BEEP@", "Beep", .screen, nil, .beep),
                ("\u{01}L", "Ctrl-A L: clear screen", .screen, nil, .clearScreen), ("\u{01}'", "Ctrl-A ': cursor home", .screen, nil, .home),
                ("\u{01}>", "Ctrl-A >: clear to end of line", .screen, nil, .clearToEndOfLine), ("\u{01}P", "Ctrl-A P: pause", .screen, nil, .pause),
                ("\u{01}D", "Ctrl-A D: date", .time, .date, nil), ("\u{01}T", "Ctrl-A T: time", .time, .time, nil),
            ]),
        BBSPackageDefinition(
            package: .mystic, displayName: "Mystic BBS", colourCodeName: "pipe codes", colours: .pipes(limit: 32), macros: [.pipeLetters],
            files: ScreenFileRules(
                folder: "themes/default/text", nameCase: .lower, ansiExtension: "ans", nativeExtension: "ans", utf8Extension: nil,
                widthSuffix: .cColumns,
                slots: [.matrix: SlotFile("themes/default/text/prelogon", source: mysticFiles),
                        .welcome: SlotFile("themes/default/text/logon1", source: mysticFiles),
                        .newUser: SlotFile("themes/default/text/newuser", source: mysticFiles),
                        .goodbye: SlotFile("themes/default/text/logoff", source: mysticFiles)],
                readsSauce: false, eightDotThree: false,
                notes: "ANSI callers get the .ans file, others the .asc file. Main menus are .mnu files that name a display file; export the screen and set that name in the menu editor.",
                themeFolder: "default"),
            source: "\(mysticCodes), \(mysticFiles)",
            codes: [
                ("|UH", "User's handle", .user, .userHandle, nil), ("|UN", "User's real name", .user, .realName, nil),
                ("|UC", "User's city, state", .user, .location, nil), ("|CS", "User's total calls", .user, .calls, nil),
                ("|TL", "Time left in minutes", .user, .timeLeft, nil), ("|LO", "User's last call date", .user, .lastOn, nil),
                ("|SL", "Security level", .user, .securityLevel, nil),
                ("|BN", "BBS name", .system, .bbsName, nil), ("|SN", "SysOp name", .system, .sysop, nil),
                ("|ND", "Node number", .system, .node, nil), ("|VR", "Mystic version", .system, .version, nil),
                ("|TI", "Time (12 hour)", .time, .time, nil), ("|DA", "Current date", .time, .date, nil),
                ("|CL", "Clear the screen", .screen, nil, .clearScreen), ("|CR", "New line", .screen, nil, .newline),
                ("|PA", "Pause prompt", .screen, nil, .pause), ("|[K", "Clear to end of line", .screen, nil, .clearToEndOfLine),
                ("|BE", "Beep", .screen, nil, .beep), ("|DE", "Half second delay", .screen, nil, .delay),
            ]),
        BBSPackageDefinition(
            package: .wwiv, displayName: "WWIV", colourCodeName: "pipe and heart codes", colours: .wwiv, macros: [.wwivMacros],
            files: ScreenFileRules(
                folder: "gfiles", nameCase: .lower, ansiExtension: "ans", nativeExtension: "msg", utf8Extension: nil, widthSuffix: .none,
                slots: [.matrix: SlotFile("gfiles/welcome", source: wwivDocs), .welcome: SlotFile("gfiles/logon", source: wwivDocs),
                        .goodbye: SlotFile("gfiles/logoff", source: wwivDocs), .newUser: SlotFile("gfiles/newuser", source: wwivDocs)],
                readsSauce: false, eightDotThree: false,
                notes: "WWIV shows .ans to ANSI colour callers, then .b&w, then .msg (which may hold heart and pipe codes). welcome is shown before logon."),
            source: wwivDocs,
            codes: [
                ("|@N", "User name", .user, .userHandle, nil), ("|@R", "Real name", .user, .realName, nil),
                ("|@C", "City", .user, .location, nil), ("|@l", "Total logons", .user, .calls, nil),
                ("|@%", "Time remaining", .user, .timeLeft, nil), ("|@L", "Last call date", .user, .lastOn, nil),
                ("|@Y", "BBS name", .system, .bbsName, nil), ("|@t", "Time", .time, .time, nil), ("|@/", "Today's date", .time, .date, nil),
                ("|@!", "Pause", .screen, nil, .pause), ("|[J", "Clear the screen", .screen, nil, .clearScreen),
                ("|[K", "Clear to end of line", .screen, nil, .clearToEndOfLine),
            ]),
        BBSPackageDefinition(
            package: .enigma, displayName: "ENiGMA\u{00BD}", colourCodeName: "pipe codes", colours: .pipes(limit: 32),
            macros: [.percent(caseBlind: false, views: true)],
            files: ScreenFileRules(
                folder: "art/themes/mytheme", nameCase: .upper, ansiExtension: "ANS", nativeExtension: "ANS", utf8Extension: "UTF8ANS",
                widthSuffix: .none,
                slots: [.matrix: SlotFile("art/themes/mytheme/MATRIX", source: enigmaArt), .welcome: SlotFile("art/themes/mytheme/WELCOME", source: enigmaArt),
                        .mainMenu: SlotFile("art/themes/mytheme/MMENU", source: enigmaArt), .goodbye: SlotFile("art/themes/mytheme/LOGOFF", source: enigmaArt),
                        .ad: SlotFile("art/themes/mytheme/PRELOGAD", source: enigmaArt)],
                readsSauce: true, eightDotThree: false,
                notes: "Change \"mytheme\" to your theme's folder. FOO1.ANS, FOO2.ANS ... are picked at random for art FOO. %TL1 style views are placed by theme.hjson.",
                themeFolder: "mytheme"),
            source: "\(enigmaMCI), \(enigmaArt)",
            codes: [
                ("%UN", "Current user's username", .user, .userHandle, nil), ("%UR", "Current user's real name", .user, .realName, nil),
                ("%LO", "User's location", .user, .location, nil), ("%UC", "User's login/call count", .user, .calls, nil),
                ("%TR", "Time remaining today", .user, .timeLeft, nil),
                ("%BN", "Board name", .system, .bbsName, nil), ("%SN", "SysOp username", .system, .sysop, nil),
                ("%ND", "Connected node number", .system, .node, nil), ("%VN", "Version number", .system, .version, nil),
                ("%DT", "Current date", .time, .date, nil), ("%CT", "Current time", .time, .time, nil),
                ("%TL1", "Text label view 1", .view, nil, .view), ("%ET1", "Edit text view 1", .view, nil, .view),
                ("%VM1", "Vertical menu view 1", .view, nil, .view), ("%HM1", "Horizontal menu view 1", .view, nil, .view),
                ("%BT1", "Button view 1", .view, nil, .view), ("%MT1", "Multi line edit view 1", .view, nil, .view),
            ]),
        BBSPackageDefinition(
            package: .pcboard, displayName: "PCBoard", colourCodeName: "@X codes", colours: .atX, macros: [.atPCBoard],
            files: ScreenFileRules(
                folder: "", nameCase: .upper, ansiExtension: "ANS", nativeExtension: "PCB", utf8Extension: nil, widthSuffix: .none,
                slots: [:], readsSauce: false, eightDotThree: true,
                notes: "PCBoard's display file names and its graphics suffixes are not documented in any source found; every name is AnsiView's suggestion. Check the paths in PCBSetup."),
            source: pcbGuide,
            codes: [
                ("@USER@", "Caller's name in upper case", .user, .userHandle, nil), ("@FIRST@", "Caller's first name", .user, .firstName, nil),
                ("@CITY@", "Caller's city", .user, .location, nil), ("@NUMTIMESON@", "Caller's number of calls", .user, .calls, nil),
                ("@TIMELEFT@", "Minutes left", .user, .timeLeft, nil), ("@LASTDATEON@", "Last date on", .user, .lastOn, nil),
                ("@SECURITY@", "Security level", .user, .securityLevel, nil),
                ("@BOARDNAME@", "Name of the BBS", .system, .bbsName, nil), ("@NODE@", "Current node number", .system, .node, nil),
                ("@CONFNAME@", "Conference name", .system, .messageArea, nil),
                ("@SYSDATE@", "Current system date", .time, .date, nil), ("@SYSTIME@", "Current system time", .time, .time, nil),
                ("@CLS@", "Clear the screen", .screen, nil, .clearScreen), ("@PAUSE@", "Pause (continues after 10 seconds)", .screen, nil, .pause),
                ("@MORE@", "More prompt", .screen, nil, .pause), ("@CLREOL@", "Clear to end of line", .screen, nil, .clearToEndOfLine),
                ("@BEEP@", "Beep", .screen, nil, .beep),
            ]),
        BBSPackageDefinition(
            package: .wildcat, displayName: "Wildcat!", colourCodeName: "@bf@ codes", colours: .atHexAt, macros: [],
            files: ScreenFileRules(
                folder: "", nameCase: .upper, ansiExtension: "ANS", nativeExtension: "BBS", utf8Extension: nil, widthSuffix: .none,
                slots: [:], readsSauce: false, eightDotThree: true,
                notes: "Only Wildcat's colour codes are documented (by third parties); its text macros and file names are not. Every name is AnsiView's suggestion."),
            source: synchronetColours,
            codes: []),
        BBSPackageDefinition(
            package: .renegade, displayName: "Renegade", colourCodeName: "pipe codes", colours: .pipes(limit: 24),
            macros: [.percent(caseBlind: true, views: false)],
            files: ScreenFileRules(
                folder: "MISC", nameCase: .upper, ansiExtension: "ANS", nativeExtension: "ANS", utf8Extension: nil, widthSuffix: .none,
                slots: [.matrix: SlotFile("MISC/PRELOGON", source: renegadeSource), .welcome: SlotFile("MISC/WELCOME", source: renegadeSource)],
                readsSauce: false, eightDotThree: true,
                notes: "Renegade looks in its MISC path for .RIP, .AVT, .ANS, then .ASC. With WELCOME.AN1 to .AN9 present it picks one at random. Set MISC to your MiscPath."),
            source: renegadeSource,
            codes: [
                ("%UN", "User name", .user, .userHandle, nil), ("%RN", "Real name", .user, .realName, nil),
                ("%FN", "First name", .user, .firstName, nil), ("%LO", "City, state", .user, .location, nil),
                ("%TL", "Time left", .user, .timeLeft, nil), ("%TC", "Calls", .user, .calls, nil),
                ("%SL", "Security level", .user, .securityLevel, nil),
                ("%BN", "BBS name", .system, .bbsName, nil), ("%SN", "SysOp name", .system, .sysop, nil),
                ("%ND", "Node", .system, .node, nil), ("%VR", "Version", .system, .version, nil),
                ("%TI", "Time", .time, .time, nil), ("%DA", "Date", .time, .date, nil),
                ("%CL", "Clear the screen", .screen, nil, .clearScreen), ("%LF", "New line", .screen, nil, .newline),
            ]),
    ]
}
