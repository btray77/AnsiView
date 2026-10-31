import Foundation

// The AnsiView glossary (item 62): every word a newcomer meets in AnsiView, in plain English for
// someone who never used a BBS. The app shows it in Help > AnsiView Glossary, in the Help menu's
// search and behind the (?) buttons beside jargon controls. Pure Foundation so iOS can use it too.

/// One glossary entry's identity. The (?) buttons and related links use these, so the compiler
/// checks that every hint points at an entry that exists.
public enum GlossaryTerm: String, CaseIterable, Sendable {
    // Art and files
    case ansiArt, asciiArt, escapeCodes, cp437, textModeFont, iceColours, blink, sauce, artPack, sixteenColors, artScene
    case fileIDDiz, nfo, xbin, adf, idf, binFormat, pcboard, avatar, ripscrip, ascFormat
    // Drawing
    case halfBlocks, shadingBlocks, lineDrawing, letterSpacing, aspectRatio, palette, layers, frames, onionSkin
    case theDrawFonts, figlet, columns
    // Playback
    case baud, crPadding, ansiMusic, bansi, crtEffect
    // Terminal
    case bbs, terminal, terminalType, ansiBBS, vt100, vt52, petscii, atascii, viewdata, mode7, appleII, amigaAnsi
    case iemsi, displayCodes, bbsPackage, sixel, doorGames, scrollback, sessionCapture
    // Connecting
    case dialingDirectory, telnet, ssh, legacySSH, tls, hostKey, rlogin, webSocket, rawTCP
    // File transfers
    case fileTransfer, xmodem, ymodem, zmodem, kermit, checksum
    // Using AnsiView
    case library, smartFolder, duplicates, compare, autoScroll, minimap
}

/// What an entry is about, for grouping.
public enum GlossaryCategory: String, CaseIterable, Sendable {
    case art, drawing, playback, terminal, connecting, transfers, usingAnsiView

    public var label: String {
        switch self {
        case .usingAnsiView: return "Using AnsiView"
        case .art: return "Art and files"
        case .drawing: return "Drawing"
        case .playback: return "Playback"
        case .terminal: return "Terminal"
        case .connecting: return "Connecting"
        case .transfers: return "File transfers"
        }
    }
}

public struct GlossaryEntry: Sendable, Identifiable, Equatable {
    public let term: GlossaryTerm
    /// The name shown as the heading ("iCE colours").
    public let title: String
    /// Other names people search for ("ice colors", "high intensity backgrounds").
    public let aliases: [String]
    /// One short line: the tooltip and the list subtitle.
    public let hint: String
    /// A few plain sentences for someone who never used a BBS.
    public let explanation: String
    public let related: [GlossaryTerm]
    /// Where the idea shows up in AnsiView, when it does.
    public let whereInApp: String?
    public let category: GlossaryCategory

    public var id: String { term.rawValue }
}

public enum Glossary {
    /// Every entry, in the order written below.
    public static let entries: [GlossaryEntry] = all

    /// Every entry, alphabetical by title (ignoring case).
    public static let sorted: [GlossaryEntry] = all.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

    private static let byTerm: [GlossaryTerm: GlossaryEntry] = Dictionary(all.map { ($0.term, $0) }, uniquingKeysWith: { first, _ in first })

    public static func entry(_ term: GlossaryTerm) -> GlossaryEntry {
        guard let entry = byTerm[term] else { preconditionFailure("glossary entry missing for \(term)") }
        return entry
    }

    /// Entries matching `query`, best first: every word of the query must appear somewhere in the entry;
    /// title matches outrank alias matches, which outrank matches in the hint and explanation (where a
    /// query word must start a word, so "ice" does not find "services"). Case, colour/color and
    /// favourite/favorite do not matter; a hyphen counts as a space ("9-dot") or as nothing ("z-modem").
    /// An empty query lists every entry alphabetically.
    public static func search(_ query: String) -> [GlossaryEntry] {
        let spaced = normalize(query)
        guard !spaced.isEmpty else { return sorted }
        let closed = normalize(query.replacingOccurrences(of: "-", with: ""))
        var scored: [(GlossaryEntry, Int)] = []
        for entry in sorted {
            let best = [score(entry, spaced), closed == spaced ? nil : score(entry, closed)].compactMap { $0 }.max()
            if let best { scored.append((entry, best)) }
        }
        // Stable: equal scores keep alphabetical order.
        return scored.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map(\.element.0)
    }

    /// How well `entry` matches the normalized `query`, or nil when one of its words is missing.
    private static func score(_ entry: GlossaryEntry, _ query: String) -> Int? {
        let title = normalize(entry.title)
        let aliases = entry.aliases.map(normalize)
        let hintWords = normalize(entry.hint).split(separator: " ")
        let textWords = normalize(entry.explanation + " " + (entry.whereInApp ?? "")).split(separator: " ")
        var score = 0
        if title == query { score += 1000 }
        if aliases.contains(query) { score += 600 }
        if title.hasPrefix(query) { score += 200 }
        for word in query.split(separator: " ") {
            var points = 0
            if title.contains(word) { points += 50 }
            if aliases.contains(where: { $0.contains(word) }) { points += 30 }
            if hintWords.contains(where: { $0.hasPrefix(word) }) { points += 10 }
            if textWords.contains(where: { $0.hasPrefix(word) }) { points += 3 }
            if points == 0 { return nil }
            score += points
        }
        return score
    }

    /// Lowercased, "colour" as "color" and "favourite" as "favorite", hyphens and other punctuation as
    /// spaces (a dot stays, for ".ans"), spaces collapsed.
    static func normalize(_ text: String) -> String {
        var result = text.lowercased().replacingOccurrences(of: "colour", with: "color")
        result = result.replacingOccurrences(of: "favourite", with: "favorite")
        result = String(result.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : " " })
        return result.split(separator: " ").joined(separator: " ")
    }

    // swiftlint:disable line_length
    private static let all: [GlossaryEntry] = [
        // MARK: Art and files
        GlossaryEntry(term: .ansiArt, title: "ANSI art", aliases: ["ans", ".ans", "ansi"],
                      hint: "Pictures made of coloured text characters, as drawn for 1990s bulletin board systems",
                      explanation: "ANSI art is a picture built from the 256 characters of an IBM PC screen, each with a foreground and background colour. Artists drew logos, menus and whole scenes this way for bulletin board systems (BBSes), and the files (usually .ANS) are a stream of text plus escape codes that move the cursor and change colours. AnsiView reads the stream the way a terminal did and shows the finished picture.",
                      related: [.escapeCodes, .cp437, .bbs, .artPack, .asciiArt], whereInApp: "Open any .ans file; File > Open Sample has examples.", category: .art),
        GlossaryEntry(term: .asciiArt, title: "ASCII art", aliases: ["text art", "ascii"],
                      hint: "Pictures made only of plain typewriter characters, with no colour",
                      explanation: "ASCII art uses only the plain letters, digits and punctuation every computer has, so it looks the same in an email, a forum post or a text file. It has no colour and no special block characters. Many art packs include ASCII pieces, and AnsiView's Text to ASCII window makes big lettering from fonts.",
                      related: [.ansiArt, .ascFormat, .figlet, .nfo], whereInApp: "Window > Text to ASCII; Export Text.", category: .art),
        GlossaryEntry(term: .escapeCodes, title: "ANSI escape codes", aliases: ["escape sequences", "esc codes", "csi"],
                      hint: "Hidden instructions inside a file that move the cursor and change colours",
                      explanation: "An escape code starts with the Escape character (number 27) followed by a short instruction such as \"move up 3 lines\" or \"red text on blue\". Terminals act on them instead of printing them. ANSI art files are mostly these codes plus the characters to draw, which is why the art appears line by line when played at modem speed.",
                      related: [.ansiArt, .terminal, .ansiBBS, .vt100], whereInApp: "Copy As > ANSI copies art as escape codes.", category: .art),
        GlossaryEntry(term: .cp437, title: "CP437 (code page 437)", aliases: ["code page 437", "ibm pc character set", "extended ascii", "dos characters"],
                      hint: "The 256 character set of the original IBM PC, with blocks, lines and symbols",
                      explanation: "Code page 437 is the character set built into IBM PC video cards. Besides letters it has shaded blocks, half blocks, single and double box lines, card suits, smiley faces and accented letters. ANSI art depends on these shapes, so AnsiView translates every byte through CP437 rather than the Mac's own text encoding.",
                      related: [.halfBlocks, .shadingBlocks, .lineDrawing, .textModeFont], whereInApp: "Editor > Character Picker shows all 256.", category: .art),
        GlossaryEntry(term: .textModeFont, title: "Text mode font", aliases: ["bitmap font", "ibm vga font", "topaz", "microknight", "font"],
                      hint: "The fixed pixel font a computer used for its screen text, such as IBM VGA or Amiga Topaz",
                      explanation: "Old computers drew text from a small grid of pixels per character, built into the machine. The same file looks different in each machine's font, so SAUCE records can name the font the artist used (IBM VGA, IBM EGA, Amiga Topaz, MicroKnight and others) and AnsiView draws the art with it.",
                      related: [.cp437, .letterSpacing, .aspectRatio, .sauce], whereInApp: "Get Info shows the font; the editor's font menu changes it.", category: .art),
        GlossaryEntry(term: .iceColours, title: "iCE colours", aliases: ["ice colors", "ice", "high intensity backgrounds", "bright backgrounds", "16 background colours"],
                      hint: "Bright background colours in place of blinking text, giving 16 backgrounds instead of 8",
                      explanation: "On a PC text screen each character has one bit that means \"blink\". Artists found that video cards could be told to use that bit for a bright background instead, so the background gets all 16 colours rather than 8. Art that relies on this is called iCE (named after the iCE art group). A SAUCE flag says whether a file wants iCE colours; with it off, the same file shows blinking text and darker backgrounds.",
                      related: [.blink, .sauce, .palette, .xbin], whereInApp: "Art > Toggle iCE Colours in the editor; Get Info shows the flag.", category: .art),
        GlossaryEntry(term: .blink, title: "Blink", aliases: ["blinking text", "flashing text", "sgr 5"],
                      hint: "Text that flashes on and off, from the PC's blink attribute",
                      explanation: "PC text mode could make characters flash on and off about twice a second. ANSI art used it for neon signs and cursors. The same attribute bit gives bright backgrounds when iCE colours are on, so a file shows either blinking text or bright backgrounds, never both.",
                      related: [.iceColours, .escapeCodes, .sauce], whereInApp: "The viewer animates blinking text; Get Info says whether a file blinks.", category: .art),
        GlossaryEntry(term: .sauce, title: "SAUCE", aliases: ["sauce record", "standard architecture for universal comment extensions", "metadata"],
                      hint: "A 128 byte record at the end of many art files: title, author, group, date and display settings",
                      explanation: "SAUCE (Standard Architecture for Universal Comment Extensions) is a small block added to the end of an art file. It holds the title, the artist, the group, the date, the width, the font and flags such as iCE colours and letter spacing. Viewers that do not know SAUCE simply never show it. AnsiView reads it, uses its settings, and lets you edit it.",
                      related: [.iceColours, .letterSpacing, .aspectRatio, .textModeFont, .artPack], whereInApp: "File > Get Info; Art > Edit SAUCE in the editor.", category: .art),
        GlossaryEntry(term: .artPack, title: "Art pack", aliases: ["pack", "artpack", "monthly pack", "zip pack"],
                      hint: "A ZIP of art released together by an art group, usually once a month",
                      explanation: "Art groups collected their members' work into a pack, a ZIP file with the art, a FILE_ID.DIZ description and often an NFO with greetings and member lists, and spread it from BBS to BBS. Archives such as 16colo.rs keep thousands of packs. AnsiView opens a pack as a gallery without unzipping it.",
                      related: [.sixteenColors, .fileIDDiz, .nfo, .artScene], whereInApp: "File > Open Folder or Art Pack; the gallery's Pack Info pane.", category: .art),
        GlossaryEntry(term: .sixteenColors, title: "16colo.rs", aliases: ["16colors", "sixteen colors", "16colo"],
                      hint: "The online archive of ANSI art packs, sorted by year and group",
                      explanation: "16colo.rs is a free website that preserves art packs from 1990 to today, with every piece viewable in a browser. AnsiView can browse it, preview pieces and download whole packs, and only asks it for something when you do.",
                      related: [.artPack, .artScene, .ansiArt], whereInApp: "File > Browse 16colo.rs.", category: .art),
        GlossaryEntry(term: .artScene, title: "Art scene and groups", aliases: ["art group", "art scene", "acid", "ice group", "blocktronics"],
                      hint: "The community of artists and groups (ACiD, iCE, Blocktronics) who made and traded ANSI art",
                      explanation: "From the late 1980s, artists joined groups that competed to release the best monthly packs, and drew logos and menus for BBSes. Groups such as ACiD, iCE and later Blocktronics are still known today. The group name appears in SAUCE records and in pack names.",
                      related: [.artPack, .sixteenColors, .sauce], whereInApp: "The library's artist and group pages.", category: .art),
        GlossaryEntry(term: .fileIDDiz, title: "FILE_ID.DIZ", aliases: ["diz", ".diz", "file id"],
                      hint: "The short description file a BBS showed in its file list",
                      explanation: "When a ZIP was uploaded to a BBS, the board looked inside for FILE_ID.DIZ (\"description in zip\"), a text file at most 45 characters wide, and showed it in the file list. Art packs made theirs into small pieces of art. AnsiView shows a pack's DIZ beside its pieces.",
                      related: [.artPack, .nfo, .bbs], whereInApp: "The gallery's Pack Info pane (View > Show or Hide Pack Info).", category: .art),
        GlossaryEntry(term: .nfo, title: "NFO file", aliases: ["nfo", ".nfo", "info file"],
                      hint: "The release notes text file inside a pack: credits, greetings and member lists",
                      explanation: "An NFO (\"info\") file comes with a pack or release. It lists who made what, sends greetings to other groups, and often has an ASCII or ANSI logo at the top. AnsiView opens NFO files as art and shows them in the Pack Info pane.",
                      related: [.fileIDDiz, .artPack, .asciiArt], whereInApp: "The gallery's Pack Info pane.", category: .art),
        GlossaryEntry(term: .xbin, title: "XBin", aliases: ["xb", ".xb", "extended bin"],
                      hint: "An art format that carries its own palette and font inside the file",
                      explanation: "XBin (.XB) stores the screen as plain cells, like BIN, but adds a header with the width and height and can include a custom 16 colour palette and a custom font. That lets artists use colours and characters no PC had. AnsiView reads XBin and can save it.",
                      related: [.binFormat, .palette, .textModeFont, .adf], whereInApp: "Save As in the editor; Image Import's fitted colours make XBin.", category: .art),
        GlossaryEntry(term: .adf, title: "ADF (Artworx)", aliases: ["adf", ".adf", "artworx"],
                      hint: "An art format that carries its own palette and font, from the Artworx group",
                      explanation: "ADF files hold a palette (64 EGA entries, of which the art uses 16) and a font, followed by the screen cells, so art can use custom colours. Amiga emulators use .adf for Amiga disk images too, so AnsiView is only an alternate viewer for the extension.",
                      related: [.xbin, .idf, .palette], whereInApp: nil, category: .art),
        GlossaryEntry(term: .idf, title: "IDF (iCE Draw)", aliases: ["idf", ".idf", "ice draw"],
                      hint: "The iCE Draw format: screen cells compressed, with a font and palette at the end",
                      explanation: "iCE Draw saved art as IDF: a header, the screen cells packed to save space, then a font and a palette. It always uses iCE colours. AnsiView reads IDF files.",
                      related: [.iceColours, .adf, .xbin], whereInApp: nil, category: .art),
        GlossaryEntry(term: .binFormat, title: "BIN", aliases: ["bin", ".bin", "binary text"],
                      hint: "Raw screen memory: two bytes per cell, character then colour, with no escape codes",
                      explanation: "A BIN file is a copy of PC text mode memory: each cell is one byte for the character and one for its colours. It has no line breaks, so the width usually comes from SAUCE (160 columns is common). macOS uses .bin for other things too, so AnsiView is an alternate viewer for it.",
                      related: [.xbin, .sauce, .columns], whereInApp: nil, category: .art),
        GlossaryEntry(term: .pcboard, title: "PCBoard codes (PCB)", aliases: ["pcb", ".pcb", "pcboard", "@x codes"],
                      hint: "Art that sets colours with @X codes from the PCBoard BBS instead of escape codes",
                      explanation: "PCBoard was a popular BBS package. Its screens set colours with short codes like @X1F (bright white on blue) instead of ANSI escape codes. Files saved this way usually end in .PCB, and AnsiView draws them like ANSI.",
                      related: [.displayCodes, .bbsPackage, .avatar], whereInApp: nil, category: .art),
        GlossaryEntry(term: .avatar, title: "Avatar (AVT)", aliases: ["avt", ".avt", "avatar", "avt/0", "avt/0+"],
                      hint: "A compact alternative to ANSI codes with its own control codes, used by some BBSes",
                      explanation: "Avatar (Advanced Video Attribute Terminal Assembler and Recreator) was designed to be shorter and faster than ANSI over slow modems, with single byte codes for colour, cursor moves and repeated characters. Files end in .AVT, and AnsiView's terminal can also speak Avatar.",
                      related: [.terminalType, .ansiBBS, .pcboard], whereInApp: "Dialing directory > Terminal type.", category: .art),
        GlossaryEntry(term: .ripscrip, title: "RIPscrip (RIP)", aliases: ["rip", ".rip", "remote imaging protocol", "ripterm"],
                      hint: "Vector graphics for BBSes: lines, shapes, icons and mouse buttons drawn by commands",
                      explanation: "RIPscrip (Remote Imaging Protocol script) let a BBS send drawing commands such as \"circle here\" or \"button there\" so callers saw a graphical screen with clickable buttons at 640 by 350 pixels. AnsiView's terminal draws RIP screens and opens .RIP files.",
                      related: [.terminalType, .ansiBBS, .bbs], whereInApp: "Terminal > RIP Icon Folder; Terminal type RIPscrip.", category: .art),
        GlossaryEntry(term: .ascFormat, title: "ASC", aliases: ["asc", ".asc", "ascii file"],
                      hint: "A plain text art file, usually ASCII art with no colours",
                      explanation: "Files ending in .ASC are text art. Most use only plain ASCII characters, though some use the CP437 blocks too. AnsiView shows them with the PC font so lines and blocks look right.",
                      related: [.asciiArt, .cp437, .nfo], whereInApp: nil, category: .art),

        // MARK: Drawing
        GlossaryEntry(term: .halfBlocks, title: "Half blocks", aliases: ["half block", "upper half block", "lower half block", "pixels"],
                      hint: "Characters filled on the top or bottom half, giving two colour pixels per cell",
                      explanation: "CP437 has characters that fill only the top half, bottom half, left half or right half of a cell. With the foreground colour on one half and the background on the other, each cell becomes two pixels, which doubles the vertical detail. Image import and the editor's half block brush use them.",
                      related: [.shadingBlocks, .cp437, .aspectRatio], whereInApp: "Editor tools; Image Import > Characters.", category: .drawing),
        GlossaryEntry(term: .shadingBlocks, title: "Shading blocks", aliases: ["shade", "dither blocks", "light shade", "medium shade", "dark shade"],
                      hint: "Light, medium and dark dotted blocks that mix two colours for in between shades",
                      explanation: "Three CP437 characters fill a cell with a pattern of dots at a quarter, half and three quarters density. Seen from a distance they blend the foreground and background into a new shade, which artists use for gradients and texture.",
                      related: [.halfBlocks, .cp437, .palette], whereInApp: "Editor > Character Picker; Image Import > Characters.", category: .drawing),
        GlossaryEntry(term: .lineDrawing, title: "Line drawing characters", aliases: ["box drawing", "line drawing", "box characters", "frames", "borders"],
                      hint: "Single and double line pieces (corners, edges, crossings) for boxes and frames",
                      explanation: "CP437 includes pieces of single and double lines: straight edges, corners, T shapes and crossings, in every mix. Joined together they draw the boxes and borders of BBS menus. The editor's line tool picks the right piece for each joint.",
                      related: [.cp437, .halfBlocks, .displayCodes], whereInApp: "The editor's line and box tools.", category: .drawing),
        GlossaryEntry(term: .letterSpacing, title: "Letter spacing (8 or 9 dot)", aliases: ["9 dot", "8 dot", "9 pixel", "letter spacing", "character width"],
                      hint: "Whether each character is 8 or 9 pixels wide, as on VGA text screens",
                      explanation: "VGA cards drew text 9 pixels wide: 8 from the font plus a ninth column, which was blank except for line drawing characters, so their lines join up. Some art was drawn for 8 pixel cells. SAUCE can say which one a piece wants, and AnsiView follows it.",
                      related: [.aspectRatio, .textModeFont, .sauce, .lineDrawing], whereInApp: "Get Info shows it; the viewer follows the file's SAUCE.", category: .drawing),
        GlossaryEntry(term: .aspectRatio, title: "Aspect ratio", aliases: ["legacy aspect", "stretch", "square pixels", "dos aspect"],
                      hint: "Whether to stretch the art taller, as old 4:3 monitors showed it",
                      explanation: "A DOS text screen was 640 by 400 pixels shown on a 4:3 monitor, so every pixel was a little taller than wide. On a modern screen with square pixels the same art looks squashed. SAUCE can ask for the old proportions, and AnsiView can stretch the art about 20 percent taller to match.",
                      related: [.letterSpacing, .sauce, .halfBlocks], whereInApp: "Get Info; export options.", category: .drawing),
        GlossaryEntry(term: .palette, title: "Palette", aliases: ["colour palette", "16 colours", "vga palette", "colours", "pal"],
                      hint: "The set of 16 colours a piece is drawn with",
                      explanation: "Classic ANSI art has 16 colours: 8 normal and 8 bright. Which exact shades those are depends on the machine (IBM VGA, Amiga, C64) or on a palette stored in the file (XBin, ADF, IDF). Changing the palette recolours the whole piece without changing what is drawn.",
                      related: [.iceColours, .xbin, .adf, .shadingBlocks], whereInApp: "View > Palette.", category: .drawing),
        GlossaryEntry(term: .layers, title: "Layers", aliases: ["layer"],
                      hint: "Separate sheets of art stacked on top of each other, edited one at a time",
                      explanation: "Layers let you draw a background, then a logo on its own layer above, and move or hide one without disturbing the other. When saved as ANSI the layers are flattened into one picture; the AnsiView project format keeps them.",
                      related: [.frames, .columns], whereInApp: "The editor's Layers panel.", category: .drawing),
        GlossaryEntry(term: .frames, title: "Frames and animation", aliases: ["animation", "ansimation", "frame", "animated ansi"],
                      hint: "A piece that redraws over itself to move, like a flip book",
                      explanation: "Because ANSI files are played as a stream, an artist can draw one picture, move the cursor back and draw changes over it. At modem speed this looks like animation (called ansimation). AnsiView's editor builds animations from frames and exports them as ANSI, GIF or MP4.",
                      related: [.baud, .onionSkin, .layers, .crPadding], whereInApp: "The editor's animation timeline.", category: .drawing),
        GlossaryEntry(term: .onionSkin, title: "Onion skin", aliases: ["onion skinning", "ghost frame"],
                      hint: "Shows the previous frame faintly while you draw the next one",
                      explanation: "Animators drew on thin paper so the previous drawing showed through. With onion skin on, the previous frame is drawn faintly over the frame you are editing: cells that are the same look normal, and cells that differ show a ghost of the previous frame, so you can see exactly what moved.",
                      related: [.frames, .layers], whereInApp: "The animation timeline.", category: .drawing),
        GlossaryEntry(term: .theDrawFonts, title: "TheDraw fonts (TDF)", aliases: ["tdf", ".tdf", "thedraw", "the draw"],
                      hint: "Big lettering fonts made of coloured blocks, from the TheDraw ANSI editor",
                      explanation: "TheDraw was the most popular DOS ANSI editor. Its fonts (.TDF files) draw each letter several lines tall out of coloured blocks and line characters, and BBS sysops used them for headings. AnsiView can import TDF fonts and type with them.",
                      related: [.figlet, .ansiArt, .cp437], whereInApp: "Window > Text to ASCII; Font Manager.", category: .drawing),
        GlossaryEntry(term: .figlet, title: "FIGlet fonts", aliases: ["figlet", "flf", ".flf", "tlf", "toilet"],
                      hint: "Big lettering fonts made of ordinary characters, from the FIGlet program",
                      explanation: "FIGlet is a program from 1991 that prints large letters made of ordinary characters such as slashes and underscores. Its fonts (.FLF, and the colourful .TLF from TOIlet) are plain text, so the lettering works anywhere. AnsiView includes FIGlet fonts and can import more.",
                      related: [.theDrawFonts, .asciiArt], whereInApp: "Window > Text to ASCII; Font Manager.", category: .drawing),
        GlossaryEntry(term: .columns, title: "Columns and canvas width", aliases: ["80 columns", "width", "canvas size", "132 columns", "40 columns"],
                      hint: "How many characters fit across the screen: usually 80",
                      explanation: "PC text screens were 80 characters wide and 25 lines tall, so most ANSI art is 80 columns. Some machines used 40 (C64, Atari, teletext) and some BBSes allow 132. Art can be any height; it scrolls.",
                      related: [.binFormat, .sauce, .terminalType], whereInApp: "Art > Canvas Size in the editor; Terminal > Size.", category: .drawing),

        // MARK: Playback
        GlossaryEntry(term: .baud, title: "Baud and emulated speed", aliases: ["baud rate", "bps", "modem speed", "emulated speed", "bits per second"],
                      hint: "How fast a modem sent data; AnsiView can play art at that speed",
                      explanation: "A modem's speed was measured in bits per second (loosely called baud). At 2400 an 80 by 25 screen of ANSI took several seconds to appear, line by line, and artists designed for that. AnsiView's emulated speed plays the file at the speed you choose, so you see it drawn as callers did; Instant shows the finished picture.",
                      related: [.frames, .crPadding, .ansiMusic, .bbs], whereInApp: "Playback > Speed; Terminal > Speed.", category: .playback),
        GlossaryEntry(term: .crPadding, title: "CR padding", aliases: ["carriage return padding", "padding", "cr", "delay padding"],
                      hint: "Extra do nothing bytes added to make an animation pause at modem speed",
                      explanation: "ANSI has no \"wait\" command, so animators added harmless bytes (carriage returns, character 13) that take time to send but change nothing on screen. The more padding, the longer the pause at a given baud rate. AnsiView's animation export adds padding for each frame's delay.",
                      related: [.frames, .baud, .escapeCodes], whereInApp: "The animation export options.", category: .playback),
        GlossaryEntry(term: .ansiMusic, title: "ANSI music", aliases: ["music", "basic play", "play tunes", "pc speaker music"],
                      hint: "Simple tunes hidden in an art file, played through the PC speaker",
                      explanation: "Some terminals understood a special escape code followed by notes in the BASIC PLAY language (\"T120 O4 C D E\"). Art could carry a tune that played while it drew. AnsiView plays it with a synthesized PC speaker sound and has a music editor.",
                      related: [.bansi, .baud, .escapeCodes], whereInApp: "Playback > Play ANSI Music; Window > ANSI Music Editor.", category: .playback),
        GlossaryEntry(term: .bansi, title: "BANSI", aliases: ["bananacom", "banana ansi", "esc[n"],
                      hint: "The BananaCom style of ANSI music, started by ESC [ N instead of ESC [ M",
                      explanation: "The first ANSI music code, ESC [ M, also means Delete Line, so a terminal can mistake one for the other. The BananaCom terminal started its tunes with ESC [ N instead, and SyncTERM calls that style, together with its own ESC [ |, BANSI. AnsiView plays all three; choose which ones a BBS may use in its dialing directory entry.",
                      related: [.ansiMusic, .escapeCodes], whereInApp: "The music editor's export choices.", category: .playback),
        GlossaryEntry(term: .crtEffect, title: "CRT effect", aliases: ["crt", "scanlines", "glow", "tube"],
                      hint: "Makes the art look as if shown on an old tube monitor, with scanlines and glow",
                      explanation: "Old monitors were glass tubes that drew the picture in horizontal lines, leaving dark gaps between them and a soft glow around bright colours. The CRT effect imitates that look. It changes only how the art is shown, never the file.",
                      related: [.aspectRatio, .palette], whereInApp: "View > CRT Effect.", category: .playback),

        // MARK: Terminal
        GlossaryEntry(term: .bbs, title: "BBS (bulletin board system)", aliases: ["bbs", "bulletin board", "board", "sysop"],
                      hint: "A computer you dialled into with a modem for messages, files and games, before the web",
                      explanation: "Before the web, people ran bulletin board systems on home computers connected to phone lines. Callers dialled in with a modem and a terminal program to read messages, trade files and play door games. The person running the board was the sysop. Hundreds of BBSes still run today, reached over the internet with telnet or SSH.",
                      related: [.terminal, .telnet, .dialingDirectory, .doorGames, .bbsPackage], whereInApp: "File > Connect to BBS.", category: .terminal),
        GlossaryEntry(term: .terminal, title: "Terminal", aliases: ["terminal program", "terminal emulator", "client"],
                      hint: "The program that shows a BBS's screen and sends what you type",
                      explanation: "A terminal shows the text and escape codes a BBS sends and passes your keystrokes back. Old ones were programs like Telix and Qmodem; AnsiView includes one, with the terminal types, transfers and settings BBSes expect.",
                      related: [.terminalType, .bbs, .escapeCodes, .scrollback], whereInApp: "File > Connect to BBS; the Terminal menu.", category: .terminal),
        GlossaryEntry(term: .terminalType, title: "Terminal type (emulation)", aliases: ["emulation", "terminal emulation", "term type"],
                      hint: "Which machine's screen codes the terminal understands: ANSI, VT100, PETSCII and others",
                      explanation: "Each kind of computer had its own way of coding colours and cursor moves. The terminal type tells AnsiView which one this BBS speaks, so its screens draw correctly: ANSI-BBS for PC boards, PETSCII for Commodore 64 boards, Viewdata for Prestel style pages, and so on. Most boards want ANSI-BBS.",
                      related: [.ansiBBS, .vt100, .vt52, .petscii, .atascii, .viewdata, .mode7, .appleII, .amigaAnsi, .avatar, .ripscrip], whereInApp: "Dialing directory entry; Terminal > Terminal Type.", category: .terminal),
        GlossaryEntry(term: .ansiBBS, title: "ANSI-BBS", aliases: ["ansi bbs", "ansi.sys", "pc ansi"],
                      hint: "The PC flavour of ANSI codes most BBSes use, with CP437 characters and 16 colours",
                      explanation: "ANSI-BBS is the set of escape codes MS-DOS's ANSI.SYS understood, plus the CP437 characters and BBS habits such as ANSI music. It is the right choice for nearly every PC BBS.",
                      related: [.terminalType, .vt100, .cp437, .escapeCodes], whereInApp: "Terminal type ANSI-BBS.", category: .terminal),
        GlossaryEntry(term: .vt100, title: "VT100 and VT220", aliases: ["vt100", "vt102", "vt220", "dec vt"],
                      hint: "The DEC video terminals whose codes became the standard for Unix terminals",
                      explanation: "The DEC VT100 (1978) and VT220 were video terminals for minicomputers. Their escape codes became the base of the ANSI standard and of every Unix terminal today. Choose VT100 for Unix style hosts and some BBSes that expect it.",
                      related: [.terminalType, .ansiBBS, .vt52], whereInApp: "Terminal type VT100 or VT220.", category: .terminal),
        GlossaryEntry(term: .vt52, title: "VT52", aliases: ["vt52", "atari st"],
                      hint: "An older DEC terminal code set, also built into the Atari ST",
                      explanation: "The VT52 used short ESC plus letter codes, simpler than VT100. The Atari ST's screen understood them, so Atari ST BBSes use VT52.",
                      related: [.vt100, .terminalType, .atascii], whereInApp: "Terminal type VT52 (Atari ST).", category: .terminal),
        GlossaryEntry(term: .petscii, title: "PETSCII", aliases: ["petscii", "c64", "commodore 64", "c128", "commodore"],
                      hint: "The Commodore 64 and 128 character set, with its own graphics and colour codes",
                      explanation: "Commodore computers used PETSCII instead of ASCII: different codes for the letters, block graphics on the keyboard, and single byte codes for colours and cursor moves. Commodore BBSes send PETSCII at 40 columns (80 on a C128).",
                      related: [.terminalType, .atascii, .columns], whereInApp: "Terminal type PETSCII.", category: .terminal),
        GlossaryEntry(term: .atascii, title: "ATASCII", aliases: ["atascii", "atari 8 bit", "atari 800", "inverse video"],
                      hint: "The Atari 8 bit computers' character set, with graphics and inverse video",
                      explanation: "Atari 400, 800 and XL machines used ATASCII: its own graphics characters, inverse video for highlighting and 40 column screens. Atari BBSes send ATASCII.",
                      related: [.terminalType, .petscii, .vt52], whereInApp: "Terminal type ATASCII; Terminal > Atari Inverse Video Key.", category: .terminal),
        GlossaryEntry(term: .viewdata, title: "Viewdata and Prestel", aliases: ["viewdata", "prestel", "videotex", "teletext", "minitel"],
                      hint: "Page based colour text services from the UK, 40 columns with block graphics",
                      explanation: "Viewdata (Prestel in the UK) delivered pages of 40 by 24 coloured text and chunky block graphics over the phone line, like teletext on TV. Some boards still serve Viewdata pages, which can hide text such as quiz answers until revealed.",
                      related: [.mode7, .terminalType, .columns], whereInApp: "Terminal type Viewdata; Terminal > Reveal Concealed Text.", category: .terminal),
        GlossaryEntry(term: .mode7, title: "Mode 7 (BBC Micro)", aliases: ["mode 7", "bbc micro", "bbc"],
                      hint: "The BBC Micro's teletext screen mode, used by BBC BBSes",
                      explanation: "The BBC Micro's Mode 7 displayed teletext style pages: 40 columns, 8 colours and block graphics, using very little memory. BBC Micro BBSes send Mode 7 screens.",
                      related: [.viewdata, .terminalType], whereInApp: "Terminal type Mode 7.", category: .terminal),
        GlossaryEntry(term: .appleII, title: "Apple II", aliases: ["apple ii", "apple 2", "apple2", "mousetext"],
                      hint: "The Apple II's text screen, including its MouseText symbols",
                      explanation: "Apple II BBSes send plain text for the Apple II's 40 or 80 column screen, sometimes with MouseText, a set of small symbols for windows and icons. AnsiView draws them with an Apple II style font.",
                      related: [.terminalType, .columns], whereInApp: "Terminal type Apple II.", category: .terminal),
        GlossaryEntry(term: .amigaAnsi, title: "Amiga ANSI", aliases: ["amiga", "topaz", "amiga ansi"],
                      hint: "ANSI as Amiga computers showed it, with the Topaz font and Amiga colours",
                      explanation: "Amiga terminals understood ANSI codes but drew them with the Amiga's Topaz font and palette, and Amiga art was made for that look. Choose Amiga ANSI for Amiga BBSes.",
                      related: [.terminalType, .ansiBBS, .textModeFont, .palette], whereInApp: "Terminal type Amiga ANSI.", category: .terminal),
        GlossaryEntry(term: .iemsi, title: "IEMSI", aliases: ["iemsi", "interactive emsi", "auto login"],
                      hint: "A handshake that lets a terminal log you in to a BBS automatically",
                      explanation: "IEMSI (Interactive Electronic Mail Standard Identification) lets the terminal send your name, password and preferences when the BBS asks, so you skip typing them. Only some BBS packages support it; others simply ignore it.",
                      related: [.bbs, .dialingDirectory, .terminal], whereInApp: "Dialing directory entry > IEMSI.", category: .terminal),
        GlossaryEntry(term: .displayCodes, title: "Display codes (pipe and MCI codes)", aliases: ["mci codes", "pipe codes", "@ codes", "heart codes", "ctrl a codes", "display codes", "|01"],
                      hint: "Short codes a BBS replaces with colours or live values, such as |01 or @USER@",
                      explanation: "BBS screens are templates. Codes like |14 (yellow), @USER@ (the caller's name) or %UN are swapped by the BBS for colours or live values when the screen is shown. Each BBS package has its own codes. AnsiView's screen designer inserts them, previews them with sample values and exports for the package you pick.",
                      related: [.bbsPackage, .pcboard, .bbs], whereInApp: "Editor > Insert Display Code; Sample Values.", category: .terminal),
        GlossaryEntry(term: .bbsPackage, title: "BBS package", aliases: ["bbs software", "synchronet", "mystic", "wwiv", "renegade", "enigma", "pcboard"],
                      hint: "The software that runs a BBS, such as Synchronet, Mystic, WWIV or Renegade",
                      explanation: "Sysops run a BBS package: the program that handles callers, menus, messages and files. Each one reads screens from its own folders with its own file names and display codes, so AnsiView's export profiles know where each package expects its files.",
                      related: [.displayCodes, .bbs, .doorGames], whereInApp: "Export Profiles and Screen Set.", category: .terminal),
        GlossaryEntry(term: .sixel, title: "Sixel and inline pictures", aliases: ["sixel", "iterm2 images", "inline images", "graphics"],
                      hint: "A way for a host to send real pictures to a terminal, six pixel rows at a time",
                      explanation: "Sixel is an old DEC graphics format that sends a picture as text, six rows of pixels per line of characters. Some modern BBSes and Unix tools use it (or the iTerm2 picture code) to show photos inside the terminal. AnsiView draws both.",
                      related: [.terminal, .vt100, .ripscrip], whereInApp: "The terminal shows them as they arrive.", category: .terminal),
        GlossaryEntry(term: .doorGames, title: "Door games", aliases: ["door", "doors", "door game", "trade wars", "lord"],
                      hint: "Games a BBS runs for its callers, like Trade Wars or Legend of the Red Dragon",
                      explanation: "A door is a separate program the BBS hands the caller to: usually a game played a few turns a day, such as Trade Wars 2002 or Legend of the Red Dragon. Doors draw with ANSI and often need the right terminal type and size.",
                      related: [.bbs, .terminalType, .bbsPackage], whereInApp: nil, category: .terminal),
        GlossaryEntry(term: .scrollback, title: "Scrollback", aliases: ["scroll back", "history", "buffer"],
                      hint: "The lines that scrolled off the top of the terminal, kept so you can scroll up to read them",
                      explanation: "As a BBS sends more text, older lines scroll off the top. The terminal keeps them in its scrollback so you can scroll up and read them again. Clearing it frees the memory.",
                      related: [.terminal, .sessionCapture], whereInApp: "Terminal > Clear Scrollback.", category: .terminal),
        GlossaryEntry(term: .sessionCapture, title: "Session capture", aliases: ["capture", "log", "capture to file"],
                      hint: "Saves everything the BBS sends to a file, so you can replay or keep it",
                      explanation: "A capture writes the raw stream from the BBS, escape codes and all, to a file. Opened in AnsiView it plays back exactly as it arrived, which is how many people kept copies of favourite boards' screens.",
                      related: [.scrollback, .terminal, .ansiArt], whereInApp: "Terminal > Capture Session.", category: .terminal),

        // MARK: Connecting
        GlossaryEntry(term: .dialingDirectory, title: "Dialing directory", aliases: ["phone book", "address book", "dial directory", "bbs list"],
                      hint: "Your list of BBSes to call, with each one's address and settings",
                      explanation: "Terminal programs kept a dialing directory: the boards you call, their phone numbers (now internet addresses), and per board settings such as terminal type, speed and login. AnsiView's looks and works like the classic ones, with keyboard control and redial.",
                      related: [.bbs, .telnet, .ssh, .terminalType, .iemsi], whereInApp: "Window > Dialing Directory.", category: .connecting),
        GlossaryEntry(term: .telnet, title: "Telnet", aliases: ["telnet", "port 23"],
                      hint: "The plain, unencrypted way most BBSes accept internet callers",
                      explanation: "Telnet is a simple protocol from 1969 for typing to a remote computer. Most BBSes accept callers by telnet, usually on port 23. It is not encrypted, so anyone on the network path could read what you type, including passwords; use SSH or TLS when the board offers them.",
                      related: [.ssh, .tls, .rlogin, .rawTCP, .bbs], whereInApp: "Dialing directory entry > Protocol.", category: .connecting),
        GlossaryEntry(term: .ssh, title: "SSH", aliases: ["secure shell", "ssh", "port 22"],
                      hint: "An encrypted connection, so nobody in between can read what you type",
                      explanation: "SSH (Secure Shell) encrypts everything between you and the BBS and checks the board's identity with a host key. Many modern BBSes offer it alongside telnet. You may need a username, a password or a key file.",
                      related: [.legacySSH, .hostKey, .telnet, .tls], whereInApp: "Dialing directory entry > Protocol.", category: .connecting),
        GlossaryEntry(term: .legacySSH, title: "Legacy SSH encryption", aliases: ["legacy ssh", "old ssh", "weak ciphers", "ssh compatibility", "3des", "blowfish", "diffie hellman group1"],
                      hint: "Older, weaker SSH methods some BBSes still need; off unless a board requires them",
                      explanation: "Some BBS software only knows SSH methods from years ago that are now considered weak, such as 3DES or Blowfish ciphers and small key exchanges. Modern apps refuse them. AnsiView can turn them on for one board at a time; the connection is still encrypted, just less strongly.",
                      related: [.ssh, .hostKey, .tls], whereInApp: "Dialing directory entry > SSH settings.", category: .connecting),
        GlossaryEntry(term: .tls, title: "TLS", aliases: ["tls", "ssl", "secure telnet", "telnets", "certificate", "client certificate"],
                      hint: "The encryption websites use, also offered by some BBSes for telnet",
                      explanation: "TLS (Transport Layer Security) is the encryption behind https. Some BBSes offer telnet over TLS on a separate port. The board proves its identity with a certificate; boards with home made certificates ask you to trust them the first time, and a few accept a client certificate from you instead of a password.",
                      related: [.telnet, .ssh, .hostKey], whereInApp: "Dialing directory entry > Protocol and TLS settings.", category: .connecting),
        GlossaryEntry(term: .hostKey, title: "Host key and fingerprint", aliases: ["host key", "fingerprint", "known hosts", "server key", "sha256 fingerprint"],
                      hint: "A board's identity for SSH, shown as a fingerprint to compare and remember",
                      explanation: "Every SSH server has a host key. The first time you connect, AnsiView shows its fingerprint (a short summary of the key) and asks whether to trust it, then remembers it. If the key changes later, you are warned: either the board was reinstalled or someone is pretending to be it.",
                      related: [.ssh, .legacySSH, .tls], whereInApp: "Shown when you first connect to an SSH board.", category: .connecting),
        GlossaryEntry(term: .rlogin, title: "RLogin", aliases: ["rlogin", "port 513"],
                      hint: "An old Unix protocol some BBSes use to log you in by name without a prompt",
                      explanation: "RLogin sends your user name with the connection, so boards that support it can skip the login prompt. Like telnet it is not encrypted.",
                      related: [.telnet, .ssh], whereInApp: "Dialing directory entry > Protocol.", category: .connecting),
        GlossaryEntry(term: .webSocket, title: "WebSocket", aliases: ["websocket", "ws", "wss", "web terminal"],
                      hint: "The connection web based BBS terminals use, sometimes the only way in",
                      explanation: "Some BBSes let callers in through a web page, which talks to the board over a WebSocket. AnsiView can connect the same way, with or without encryption (wss).",
                      related: [.telnet, .tls], whereInApp: "Dialing directory entry > Protocol.", category: .connecting),
        GlossaryEntry(term: .rawTCP, title: "Raw TCP", aliases: ["raw", "raw socket", "tcp"],
                      hint: "A bare connection with no telnet negotiation, for boards that do not speak telnet",
                      explanation: "A raw connection sends bytes both ways with nothing added. A few boards and devices expect this instead of telnet, whose option messages they would show as junk.",
                      related: [.telnet, .rlogin], whereInApp: "Dialing directory entry > Protocol.", category: .connecting),

        // MARK: File transfers
        GlossaryEntry(term: .fileTransfer, title: "File transfer protocols", aliases: ["upload", "download", "transfer", "protocol"],
                      hint: "The rules a BBS and a terminal follow to send a file safely over the connection",
                      explanation: "A BBS cannot simply send a file the way a website does; both ends follow a protocol that splits it into blocks, checks each one and resends any that arrive damaged. XMODEM, YMODEM, ZMODEM and Kermit are the common ones. Start the transfer on the BBS first, then in AnsiView (ZMODEM and Kermit downloads start by themselves).",
                      related: [.xmodem, .ymodem, .zmodem, .kermit, .checksum], whereInApp: "Terminal > Upload File(s), Download, Transfer Log.", category: .transfers),
        GlossaryEntry(term: .xmodem, title: "XMODEM", aliases: ["xmodem", "xmodem crc", "xmodem 1k"],
                      hint: "The oldest common transfer protocol: one file, small blocks, slow but simple",
                      explanation: "XMODEM (1977) sends one file in 128 byte blocks (1024 with XMODEM-1K), waiting for an answer after each. It does not send the file name, so you name it yourself. Use it when nothing else works.",
                      related: [.ymodem, .zmodem, .fileTransfer], whereInApp: "Terminal > Upload or Download.", category: .transfers),
        GlossaryEntry(term: .ymodem, title: "YMODEM", aliases: ["ymodem", "ymodem batch", "ymodem-g"],
                      hint: "XMODEM with bigger blocks that also sends file names, several files at once",
                      explanation: "YMODEM improves XMODEM with 1024 byte blocks and a first block holding the file name and size, so it can send several files in a row. YMODEM-G skips the checks for error free connections.",
                      related: [.xmodem, .zmodem, .fileTransfer], whereInApp: "Terminal > Upload or Download.", category: .transfers),
        GlossaryEntry(term: .zmodem, title: "ZMODEM", aliases: ["zmodem", "z-modem", "rz", "sz"],
                      hint: "The fast, popular transfer protocol that starts by itself and can resume",
                      explanation: "ZMODEM streams data without waiting after each block, starts automatically when the BBS begins a download, and can resume an interrupted transfer. It is the best choice when a board offers it.",
                      related: [.ymodem, .kermit, .fileTransfer], whereInApp: "Downloads start automatically; Terminal > Upload File(s).", category: .transfers),
        GlossaryEntry(term: .kermit, title: "Kermit", aliases: ["kermit", "c-kermit"],
                      hint: "A careful transfer protocol that works over almost any connection",
                      explanation: "Kermit, from Columbia University, was built to get files through difficult links, such as ones that cannot pass every byte. It is slower than ZMODEM in its simple form but very dependable.",
                      related: [.zmodem, .xmodem, .fileTransfer], whereInApp: "Terminal > Upload or Download.", category: .transfers),
        GlossaryEntry(term: .checksum, title: "Checksum (SHA-256)", aliases: ["sha256", "sha-256", "hash", "crc"],
                      hint: "A short fingerprint of a file, to check that two copies are identical",
                      explanation: "A checksum is a number calculated from every byte of a file. If two files have the same SHA-256 checksum they are, for all practical purposes, identical. AnsiView's transfer log records one for every file sent or received.",
                      related: [.fileTransfer, .hostKey], whereInApp: "Terminal > Transfer Log.", category: .transfers),

        // MARK: Using AnsiView
        GlossaryEntry(term: .library, title: "Library", aliases: ["art library", "index", "tags", "ratings", "favourites"],
                      hint: "All your art folders and packs in one searchable place, with tags and ratings",
                      explanation: "The library indexes the folders you add (and the ZIP art packs in them) in the background: each piece's text, its SAUCE record and a thumbnail. Tags, ratings and favourites stay with a piece even if you rename or move it. Keys: 0 to 5 rate, F favourite, T tags, Return or Space opens.",
                      related: [.smartFolder, .duplicates, .sauce, .artScene], whereInApp: "Window > Library.", category: .usingAnsiView),
        GlossaryEntry(term: .smartFolder, title: "Smart folder", aliases: ["smart folders", "saved search", "rules"],
                      hint: "A saved search in the library that keeps itself up to date",
                      explanation: "A smart folder lists every piece that matches its rules, for example every piece rated 4 stars or more, or tagged \"logos\" from 1995 on, and updates as the library changes. Tag rules match your tags (case does not matter); SAUCE rules look at the title, author and group in the file; year rules use the SAUCE date, so pieces without one never match.",
                      related: [.library, .sauce], whereInApp: "Library sidebar > + button.", category: .usingAnsiView),
        GlossaryEntry(term: .duplicates, title: "Duplicates (exact and same art)", aliases: ["duplicate", "exact copies", "same art", "dupes"],
                      hint: "Copies of the same art across your folders: byte for byte, or the same picture",
                      explanation: "Exact copies have the same bytes. \"Same art\" means the finished pictures are cell for cell the same (same characters, colours and blink) although the files differ, usually because of a different SAUCE record, other line endings or redundant colour codes. Blank space at the end does not count.",
                      related: [.library, .compare, .checksum], whereInApp: "Window > Duplicates in Library.", category: .usingAnsiView),
        GlossaryEntry(term: .compare, title: "Compare", aliases: ["diff", "compare with", "differences"],
                      hint: "Shows two pieces side by side with the cells that differ tinted red",
                      explanation: "Compare looks at the finished art cell by cell: a cell differs when its character, colours or blink differ. Blank cells only compare their background, since their text colour cannot be seen. For animations the last frame is compared.",
                      related: [.duplicates, .frames], whereInApp: "File > Compare With.", category: .usingAnsiView),
        GlossaryEntry(term: .autoScroll, title: "Auto scroll", aliases: ["autoscroll", "scrolling", "reading mode"],
                      hint: "Moves tall art up the window at a steady speed, so you can sit back and read",
                      explanation: "Auto scroll moves tall art up the window at a steady speed, the way a BBS showed it line by line. Speed is in lines of the art per second and is remembered. Keys while it runs: + or Up faster, - or Down slower, Space pauses, Escape stops.",
                      related: [.minimap, .baud], whereInApp: "View > Auto Scroll.", category: .usingAnsiView),
        GlossaryEntry(term: .minimap, title: "Minimap", aliases: ["overview", "mini map"],
                      hint: "A strip beside tall art showing the whole piece; click or drag in it to jump",
                      explanation: "Much ANSI art is far taller than a window. The minimap draws the whole piece small at the right edge with a box for the part you are looking at, so you can jump anywhere with one click.",
                      related: [.autoScroll, .columns], whereInApp: "View > Show Minimap.", category: .usingAnsiView),
    ]
    // swiftlint:enable line_length
}
