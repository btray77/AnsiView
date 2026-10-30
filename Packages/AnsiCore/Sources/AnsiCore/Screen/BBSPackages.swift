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
    /// Celerity |letter: k b g c r m y w low, d B G C R M Y W high, |S swaps, |X / |x blink.
    case celerity
    /// RemoteAccess Ctrl-K [ then hex background (8 to F blink) and hex foreground.
    case ctrlKBracket
    /// Impulse files: %00 to %15 foreground, %B0 to %BF background (B8 and up iCE or blink).
    case impulse
    /// Searchlight \BK ... \WH colour names, \IV inverse, \BI blink, \NO normal.
    case searchlight
    /// Maximus MECCA tokens: [lightgreen on blue], [blink], [steady].
    case mecca
    /// No colour codes of its own (ANSI only).
    case none

    /// True when the syntax can send the blink bit (blink, or a bright background with iCE).
    public var sendsHighBit: Bool {
        switch self {
        case .pipes(let limit): return limit > 24
        case .wwiv, .none: return false
        default: return true
        }
    }

    /// The character that starts this syntax's codes and is written twice to mean itself.
    public var literalEscape: UInt8? {
        switch self {
        case .celerity: return 0x7C
        case .searchlight: return 0x5C
        case .mecca: return 0x5B
        default: return nil
        }
    }
}

/// How a package writes value and screen codes.
public enum MacroSyntax: Equatable {
    public enum AtStyle: Equatable {
        /// Synchronet: modifiers after | or - ("|R20", "|Z3", "|U", "|R####").
        case synchronet
        /// PCBoard: a width after a colon ("@USER:30C@").
        case pcboard
        /// Celerity: ":L", ":R" or ":C", a two digit width and an optional fill ("@BBS:C79.@").
        case celerity
        /// Talisman: '#' up to the size ("@MSGCONF####@": the width is the whole code's length).
        case hashes
    }

    case atCodes(AtStyle)
    /// Mystic "|XX" letters with "|$L##" padding.
    case pipeLetters
    /// WWIV "|@x" macros and "|[x" cursor codes.
    case wwivMacros
    /// A prefix and two letters ("%UN", "~UH", "~#RN", "\\%N" is one letter); case blind for
    /// Renegade; ENiGMA adds view codes with a number ("%TL1").
    case letters(prefix: String, count: Int, caseBlind: Bool, views: Bool)
    /// RemoteAccess, ProBoard, QuickBBS: Ctrl-F (user) or Ctrl-K (system) then a letter. RA pads
    /// with '.' (one space each); ProBoard with '@' left, '#' right, '%' centre (the whole code's length).
    case controlFK
    /// Maximus MECCA "[user]" tokens, case blind.
    case brackets
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
    /// Other colour syntaxes the package also reads (DayDream reads pipes, @X and hearts).
    public var alsoReads: [ColourSyntax] = []

    /// Every colour syntax the package reads, its own first.
    public var colourSyntaxes: [ColourSyntax] { [colours] + alsoReads }
}

typealias DisplayCodeRow = (String, String, DisplayCodeGroup, ScreenField?, DisplayAction?)

/// A BBS package, identified by a short name. Its definition is in the registry.
public struct BBSPackage: RawRepresentable, Hashable, Codable, CaseIterable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let synchronet = BBSPackage(rawValue: "synchronet")
    public static let telegard = BBSPackage(rawValue: "telegard")
    public static let iniquity = BBSPackage(rawValue: "iniquity")
    public static let oblivion2 = BBSPackage(rawValue: "oblivion2")
    public static let impulse = BBSPackage(rawValue: "impulse")
    public static let celerity = BBSPackage(rawValue: "celerity")
    public static let remoteaccess = BBSPackage(rawValue: "remoteaccess")
    public static let proboard = BBSPackage(rawValue: "proboard")
    public static let quickbbs = BBSPackage(rawValue: "quickbbs")
    public static let spitfire = BBSPackage(rawValue: "spitfire")
    public static let searchlight = BBSPackage(rawValue: "searchlight")
    public static let daydream = BBSPackage(rawValue: "daydream")
    public static let talisman = BBSPackage(rawValue: "talisman")
    public static let maximus = BBSPackage(rawValue: "maximus")
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

    /// Distribution files mirrored on discmaster.textfiles.com (item 43430, BBS_Software/DOS).
    static let dm = "https://discmaster.textfiles.com/view/43430/BBS_Software/DOS/"

    /// The Ctrl-F (user) and Ctrl-K (system) codes RemoteAccess, ProBoard and QuickBBS share.
    static let raCodes: [DisplayCodeRow] = [
        ("\u{06}A", "Full name", .user, .userHandle, nil), ("\u{06}W", "First name", .user, .firstName, nil),
        ("\u{06}B", "City", .user, .location, nil), ("\u{06}O", "Security level", .user, .securityLevel, nil),
        ("\u{06}P", "Total calls", .user, .calls, nil), ("\u{0B}O", "Minutes remaining", .user, .timeLeft, nil),
        ("\u{0B}I", "Time", .time, .time, nil), ("\u{0B}J", "Date", .time, .date, nil),
    ]

    /// DOS package rules: upper case 8.3 names in the BBS folder itself, .ANS files.
    static func dosRules(slots: [ScreenSlot: SlotFile], notes: String) -> ScreenFileRules {
        ScreenFileRules(folder: "", nameCase: .upper, ansiExtension: "ANS", nativeExtension: "ANS", utf8Extension: nil, widthSuffix: .none,
                        slots: slots, readsSauce: false, eightDotThree: true, notes: notes)
    }

    public static let definitions: [BBSPackageDefinition] = [
        BBSPackageDefinition(
            package: .synchronet, displayName: "Synchronet", colourCodeName: "Ctrl-A codes", colours: .ctrlA, macros: [.atCodes(.synchronet)],
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
            macros: [.letters(prefix: "%", count: 2, caseBlind: false, views: true)],
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
            package: .pcboard, displayName: "PCBoard", colourCodeName: "@X codes", colours: .atX, macros: [.atCodes(.pcboard)],
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
            macros: [.letters(prefix: "%", count: 2, caseBlind: true, views: false)],
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
        // Packages added for the owner's "work with ALL BBSes" (second research pass; primary
        // distribution files on discmaster.textfiles.com item 43430 unless noted).
        BBSPackageDefinition(
            package: .telegard, displayName: "Telegard 3", colourCodeName: "colour codes", colours: .none,
            macros: [.letters(prefix: "~", count: 2, caseBlind: false, views: false)],
            files: dosRules(slots: [:], notes: "Telegard's `xx colour codes have no documented value table, so screens export with ANSI colours. MCI codes work in display files (.ANS, .MSG, .AVT, .RIP). No standard screen names are documented."),
            source: "\(dm)TELEGARD/tg309sp3.zip (MCI.REF, ENGLISH.TXT), \(dm)TELEGARD/tg_301.zip/TELEGARD.DOC",
            codes: [("~UH", "Handle", .user, .userHandle, nil), ("~UR", "Real name", .user, .realName, nil), ("~UF", "First name", .user, .firstName, nil),
                    ("~UA", "Location", .user, .location, nil), ("~US", "Security level", .user, .securityLevel, nil),
                    ("~CM", "Time left (minutes)", .user, .timeLeft, nil), ("~SA", "System name", .system, .bbsName, nil),
                    ("~SS", "SysOp name", .system, .sysop, nil), ("~CN", "Node number", .system, .node, nil),
                    ("~SD", "System date", .time, .date, nil), ("~ST", "System time", .time, .time, nil),
                    ("~SC", "Clear screen", .screen, nil, .clearScreen), ("~SP", "Pause", .screen, nil, .pause), ("~SM", "New line", .screen, nil, .newline)]),
        BBSPackageDefinition(
            package: .iniquity, displayName: "Iniquity", colourCodeName: "pipe codes", colours: .pipes(limit: 24),
            macros: [.letters(prefix: "%", count: 2, caseBlind: false, views: false), .letters(prefix: "|", count: 2, caseBlind: false, views: false)],
            files: dosRules(slots: [.matrix: SlotFile("PRELOGON", source: "\(dm)INIQUITY/inq26src.zip/src/go/CONSTANT.PAS"),
                                    .welcome: SlotFile("WELCOME", source: "\(dm)INIQUITY/inq26src.zip/src/go/CONSTANT.PAS"),
                                    .goodbye: SlotFile("LOGOFF", source: "\(dm)INIQUITY/inq26src.zip/src/go/CONSTANT.PAS")],
                            notes: "Iniquity shows .RIP, .AVT, .ANS, then .ASC; NAME.AN1 to .AN9 are picked at random with NAME.ANS."),
            source: "\(dm)INIQUITY/inq26src.zip (MCICODES.PAS, SHOWFILE.PAS, CONSTANT.PAS)",
            codes: [("%UN", "User name", .user, .userHandle, nil), ("%RN", "Real name", .user, .realName, nil), ("%LO", "Location", .user, .location, nil),
                    ("%SL", "Security level", .user, .securityLevel, nil), ("%TL", "Time left (minutes)", .user, .timeLeft, nil),
                    ("%UC", "User's calls", .user, .calls, nil), ("%BN", "BBS name", .system, .bbsName, nil), ("%SN", "SysOp alias", .system, .sysop, nil),
                    ("%ND", "Node", .system, .node, nil), ("%TI", "Time (12 hour)", .time, .time, nil), ("%DT", "Date", .time, .date, nil),
                    ("|CS", "Clear screen", .screen, nil, .clearScreen), ("|LF", "New line", .screen, nil, .newline), ("|PA", "Pause", .screen, nil, .pause)]),
        BBSPackageDefinition(
            package: .oblivion2, displayName: "Oblivion/2", colourCodeName: "pipe codes", colours: .pipes(limit: 24),
            macros: [.letters(prefix: "%", count: 2, caseBlind: false, views: false)],
            files: dosRules(slots: [.matrix: SlotFile("PRELOGON", source: "\(dm)OBLIVION2/obv2-240.zip/OBV.DOC"),
                                    .welcome: SlotFile("WELCOME", source: "\(dm)OBLIVION2/obv2-240.zip/OBV.DOC"),
                                    .goodbye: SlotFile("GOODBYE", source: "\(dm)OBLIVION2/obv2-240.zip/OBV.DOC")],
                            notes: "Oblivion/2 can show a random WELCOME.x from the text file folder."),
            source: "\(dm)OBLIVION2/obv2-240.zip/OBV.DOC",
            codes: [("%UN", "Handle", .user, .userHandle, nil), ("%RN", "Real name", .user, .realName, nil), ("%LO", "Location", .user, .location, nil),
                    ("%TL", "Time left", .user, .timeLeft, nil), ("%CS", "Calls", .user, .calls, nil), ("%UL", "Level", .user, .securityLevel, nil),
                    ("%BN", "Board name", .system, .bbsName, nil), ("%SN", "SysOp name", .system, .sysop, nil), ("%NN", "Node", .system, .node, nil),
                    ("%DT", "Date", .time, .date, nil), ("%TM", "Time", .time, .time, nil), ("%PA", "Pause", .screen, nil, .pause)]),
        BBSPackageDefinition(
            package: .impulse, displayName: "Impulse", colourCodeName: "% colour codes", colours: .impulse,
            macros: [.letters(prefix: "%", count: 2, caseBlind: false, views: false)],
            files: dosRules(slots: [.welcome: SlotFile("WELCOME", source: "\(dm)IMPULSE/imp71.zip/IMP.DOC")],
                            notes: "In files Impulse codes start with %, in strings with |. WELCOME1 to 9 are shown at random; LOGON.ANS after login."),
            source: "\(dm)IMPULSE/imp71.zip (MCI.TXT, IMP.DOC)",
            codes: [("%UN", "User name", .user, .userHandle, nil), ("%RN", "Real name", .user, .realName, nil), ("%LO", "City, state", .user, .location, nil),
                    ("%TL", "Time left", .user, .timeLeft, nil), ("%BN", "BBS name", .system, .bbsName, nil), ("%SN", "SysOp name", .system, .sysop, nil),
                    ("%NN", "Node", .system, .node, nil), ("%DT", "Date", .time, .date, nil), ("%CL", "Clear screen", .screen, nil, .clearScreen),
                    ("%PA", "Pause", .screen, nil, .pause), ("%NL", "New line", .screen, nil, .newline)]),
        BBSPackageDefinition(
            package: .celerity, displayName: "Celerity", colourCodeName: "|letter codes", colours: .celerity,
            macros: [.atCodes(.celerity), .letters(prefix: "|", count: 1, caseBlind: false, views: false)],
            files: dosRules(slots: [:], notes: "Celerity picks welcome screens at random by terminal: *.WEL (ANSI), *.WAS (ASCII), *.WTX, *.WNA, *.WNR. Give a welcome screen your own name with the .WEL extension."),
            source: "\(dm)CELERITY/cel204r.zip/CEL204-3.ZIP/CELERITY.TXT, https://wiki.synchro.net/custom:colors",
            codes: [("@USER@", "Handle", .user, .userHandle, nil), ("@NAME@", "Handle (NAME)", .user, .userHandle, nil),
                    ("@REALNAME@", "Real name", .user, .realName, nil), ("@TIMELEFT@", "Time left", .user, .timeLeft, nil),
                    ("@NUMCALLS@", "Calls", .user, .calls, nil), ("@BBS@", "BBS name", .system, .bbsName, nil), ("@SYSOP@", "SysOp", .system, .sysop, nil),
                    ("@NODE@", "Node", .system, .node, nil), ("@DATE@", "Date", .time, .date, nil), ("@TIME@", "Time", .time, .time, nil),
                    ("@CLS@", "Clear screen", .screen, nil, .clearScreen), ("@PAUSE@", "Pause", .screen, nil, .pause),
                    ("|D", "Date", .time, .date, nil), ("|T", "Time", .time, .time, nil), ("|P", "Pause", .screen, nil, .pause),
                    ("|H", "Home (clear screen)", .screen, nil, .clearScreen)]),
        BBSPackageDefinition(
            package: .remoteaccess, displayName: "RemoteAccess", colourCodeName: "Ctrl-K [ codes", colours: .ctrlKBracket, macros: [.controlFK],
            files: dosRules(slots: [.matrix: SlotFile("LOGO", source: "\(dm)REMOTEACCESS/radoc252.zip/RA.DOC"),
                                    .welcome: SlotFile("WELCOME", source: "\(dm)REMOTEACCESS/radoc252.zip/RA.DOC"),
                                    .newUser: SlotFile("NEWUSER1", source: "\(dm)REMOTEACCESS/radoc252.zip/RA.DOC"),
                                    .goodbye: SlotFile("GOODBYE", source: "\(dm)REMOTEACCESS/radoc252.zip/RA.DOC")],
                            notes: "RemoteAccess shows .AVT, then .ANS, then .ASC (and .RIP to RIP callers). Ctrl-F and Ctrl-K codes show as their CP437 glyphs in the editor; pad a code with dots (one space each)."),
            source: "\(dm)REMOTEACCESS/radoc252.zip/RA.DOC",
            codes: raCodes + [("\u{06}3", "Handle", .user, .userHandle, nil), ("\u{06}_", "Time remaining this session", .user, .timeLeft, nil),
                              ("\u{0B}/", "Clear to end of line", .screen, nil, .clearToEndOfLine)]),
        BBSPackageDefinition(
            package: .proboard, displayName: "ProBoard", colourCodeName: "colour codes", colours: .none, macros: [.controlFK],
            files: dosRules(slots: [.matrix: SlotFile("INTRO", source: "\(dm)PROBOARD/pb_216.zip/PB216.DOC"),
                                    .welcome: SlotFile("WELCOME", source: "\(dm)PROBOARD/pb_216.zip/PB216.DOC"),
                                    .newUser: SlotFile("NEWUSER", source: "\(dm)PROBOARD/pb_216.zip/PB216.DOC"),
                                    .goodbye: SlotFile("GOODBYE", source: "\(dm)PROBOARD/pb_216.zip/PB216.DOC")],
                            notes: "ProBoard shows .AVP, .AVT, .ANS, then .ASC. Text files have no documented colour codes: use ANSI colours. Pad a code with @ (left), # (right) or % (centre)."),
            source: "\(dm)PROBOARD/pb_216.zip/PB216.DOC",
            codes: raCodes + [("\u{06}1", "Alias", .user, .userHandle, nil), ("\u{0B}P", "ProBoard version", .system, .version, nil)]),
        BBSPackageDefinition(
            package: .quickbbs, displayName: "QuickBBS", colourCodeName: "colour codes", colours: .none, macros: [.controlFK],
            files: dosRules(slots: [.welcome: SlotFile("WELCOME", source: "\(dm)QUICKBBS/qdoc_261.zip/MANUAL.DOC"),
                                    .goodbye: SlotFile("GOODBYE", source: "\(dm)QUICKBBS/qdoc_261.zip/MANUAL.DOC")],
                            notes: "QuickBBS 2.61 reads .ASC and .ANS; LOGO.ASC (before the name prompt) has no ANSI form. No colour codes are documented: use ANSI colours."),
            source: "\(dm)QUICKBBS/qdoc_261.zip/MANUAL.DOC",
            codes: raCodes),
        BBSPackageDefinition(
            package: .spitfire, displayName: "Spitfire", colourCodeName: "colour codes", colours: .none, macros: [.atCodes(.pcboard)],
            files: ScreenFileRules(folder: "", nameCase: .upper, ansiExtension: "CLR", nativeExtension: "CLR", utf8Extension: nil, widthSuffix: .none,
                                   slots: [.newUser: SlotFile("NEWUSER", source: "\(dm)SPITFIRE/sf351-2.zip/SPITFIRE.DOC"),
                                           .goodbye: SlotFile("GOODBYE", source: "\(dm)SPITFIRE/sf351-2.zip/SPITFIRE.DOC"),
                                           .mainMenu: SlotFile("MAIN", source: "\(dm)SPITFIRE/sf351-2.zip/SPITFIRE.DOC"),
                                           .bulletinList: SlotFile("BULLET", source: "\(dm)SPITFIRE/sf351-2.zip/SPITFIRE.DOC")],
                                   readsSauce: false, eightDotThree: true,
                                   notes: "Spitfire uses .CLR for ANSI colour files, .BBS for plain ASCII and .RIP. SFPRELOG.BBS (the first file at log on) is ASCII only. Keep value codes out of boxes, as its manual warns."),
            source: "\(dm)SPITFIRE/sf351-2.zip/SPITFIRE.DOC",
            codes: [("@NAME@", "Caller's name", .user, .userHandle, nil), ("@FNAME@", "First name", .user, .firstName, nil),
                    ("@CITYSTATE@", "City and state", .user, .location, nil), ("@LASTCALL@", "Last call", .user, .lastOn, nil),
                    ("@SLEVEL@", "Security level", .user, .securityLevel, nil), ("@CLS@", "Clear screen", .screen, nil, .clearScreen),
                    ("@BEEP@", "Beep", .screen, nil, .beep)]),
        BBSPackageDefinition(
            package: .searchlight, displayName: "Searchlight BBS", colourCodeName: "\\ colour codes", colours: .searchlight,
            macros: [.letters(prefix: "\\%", count: 1, caseBlind: false, views: false), .letters(prefix: "\\", count: 2, caseBlind: false, views: false)],
            files: dosRules(slots: [.newUser: SlotFile("NEWUSER", source: "\(dm)SEARCHLIGHT/sldoc450.zip/MANUAL.TXT"),
                                    .goodbye: SlotFile("LOGOFF", source: "\(dm)SEARCHLIGHT/sldoc450.zip/MANUAL.TXT")],
                            notes: "Searchlight reads .TXT (ASCII), .ANS and .RIP; LOGIN, GREETING, INFO and FILES are other standard names. A background is set with \\IV (inverse)."),
            source: "\(dm)SEARCHLIGHT/sldoc450.zip/MANUAL.TXT",
            codes: [("\\%N", "User's name", .user, .userHandle, nil), ("\\%K", "First name", .user, .firstName, nil),
                    ("\\%A", "Access level", .user, .securityLevel, nil), ("\\%M", "Time left", .user, .timeLeft, nil),
                    ("\\%S", "BBS name", .system, .bbsName, nil), ("\\%O", "Node", .system, .node, nil),
                    ("\\SB", "Current subboard", .system, .messageArea, nil), ("\\FD", "Current file directory", .system, .fileArea, nil)]),
        BBSPackageDefinition(
            package: .daydream, displayName: "DayDream BBS", colourCodeName: "pipe codes", colours: .pipes(limit: 24),
            macros: [.letters(prefix: "~#", count: 2, caseBlind: false, views: false)],
            files: ScreenFileRules(folder: "display/iso", nameCase: .lower, ansiExtension: "gfx", nativeExtension: "gfx", utf8Extension: nil,
                                   widthSuffix: .none, slots: [:], readsSauce: false, eightDotThree: false,
                                   notes: "DayDream shows name.gfx to ANSI callers and name.txt otherwise, from display/iso. It also reads @X codes and WWIV heart codes."),
            source: "https://github.com/ryanfantus/daydream (SRC/main/typetext.c, DOCS/manual/config.html)",
            codes: [("~#HA", "Handle", .user, .userHandle, nil), ("~#RN", "Real name", .user, .realName, nil), ("~#LO", "Location", .user, .location, nil),
                    ("~#SE", "Security level", .user, .securityLevel, nil), ("~#TC", "Connections", .user, .calls, nil),
                    ("~#CN", "Conference", .system, .messageArea, nil), ("~#DA", "Date", .time, .date, nil), ("~#PA", "Pause", .screen, nil, .pause)],
            alsoReads: [.atX, .wwiv]),
        BBSPackageDefinition(
            package: .talisman, displayName: "Talisman", colourCodeName: "colour codes", colours: .none, macros: [.atCodes(.hashes)],
            files: ScreenFileRules(folder: "gfiles", nameCase: .lower, ansiExtension: "ans", nativeExtension: "ans", utf8Extension: nil,
                                   widthSuffix: .none, slots: [:], readsSauce: true, eightDotThree: false,
                                   notes: "Talisman shows the .ans or .asc version of a gfile; name.132x37.ans for that screen size. It ignores SAUCE. Its pipe colour table is not documented, so screens export with ANSI colours."),
            source: "https://web.archive.org/web/20211128175555id_/https://talismanbbs.com/docs/gfilemacros/, https://web.archive.org/web/20211202041718id_/https://www.talismanbbs.com/docs/",
            codes: [("@UNAME@", "User name", .user, .userHandle, nil), ("@UFULLNAME@", "Full name", .user, .realName, nil),
                    ("@ULOCATION@", "Location", .user, .location, nil), ("@TIMELEFT@", "Time left", .user, .timeLeft, nil),
                    ("@SECLEVEL@", "Security level", .user, .securityLevel, nil), ("@MSGCONF@", "Message conference", .system, .messageArea, nil),
                    ("@PAUSE@", "Pause", .screen, nil, .pause)]),
        BBSPackageDefinition(
            package: .maximus, displayName: "Maximus (MECCA)", colourCodeName: "MECCA tokens", colours: .mecca, macros: [.brackets],
            files: ScreenFileRules(folder: "misc", nameCase: .lower, ansiExtension: "ans", nativeExtension: "mec", utf8Extension: nil,
                                   widthSuffix: .none,
                                   slots: [.matrix: SlotFile("misc/logo", source: "https://raw.githubusercontent.com/sdudley/maximus/master/ctl/max.ctl"),
                                           .welcome: SlotFile("misc/welcome", source: "https://raw.githubusercontent.com/sdudley/maximus/master/ctl/max.ctl"),
                                           .newUser: SlotFile("misc/newuser1", source: "https://raw.githubusercontent.com/sdudley/maximus/master/ctl/max.ctl"),
                                           .goodbye: SlotFile("misc/byebye", source: "https://raw.githubusercontent.com/sdudley/maximus/master/ctl/max.ctl")],
                                   readsSauce: false, eightDotThree: true,
                                   notes: "The export is MECCA source (.mec): compile it with MECCA into the .bbs file Maximus shows. A literal [ is written [[."),
            source: "https://raw.githubusercontent.com/sdudley/maximus/master/docs/max_mast.txt",
            codes: [("[user]", "User's full name", .user, .userHandle, nil), ("[first]", "First name", .user, .firstName, nil),
                    ("[realname]", "Real name", .user, .realName, nil), ("[city]", "City", .user, .location, nil),
                    ("[remain]", "Time remaining", .user, .timeLeft, nil), ("[usercall]", "User's calls", .user, .calls, nil),
                    ("[sys_name]", "System name", .system, .bbsName, nil), ("[sysop_name]", "SysOp name", .system, .sysop, nil),
                    ("[node_num]", "Node", .system, .node, nil), ("[date]", "Date", .time, .date, nil), ("[time]", "Time", .time, .time, nil),
                    ("[cls]", "Clear screen", .screen, nil, .clearScreen), ("[enter]", "Press ENTER to continue", .screen, nil, .pause),
                    ("[more]", "More prompt", .screen, nil, .pause), ("[cleol]", "Clear to end of line", .screen, nil, .clearToEndOfLine)]),
    ]
}
