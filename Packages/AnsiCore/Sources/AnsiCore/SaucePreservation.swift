import Foundation

/// What editing and saving an opened file cannot keep, so the user is told instead of the data
/// going silently (editor tools plan, ruling 12). Title, author, group, comments, font name,
/// flag bits, TInfo3/4 and the date are kept by `EditCanvas` and `ArtWriter` and never reported.
public enum SaucePreservation {
    /// Notes for a file opened in the editor.
    public static func openReport(data: Data, fileExtension: String?) -> [String] {
        let raw = [UInt8](data)
        let (sauce, contentLength) = Sauce.read(raw)
        let file = ArtFile(data: data, fileExtension: fileExtension)
        var notes: [String] = []
        if file.format.isStream, AnsiAnalysis(file).isAnimated {
            notes.append("This file is an animation: only its final frame is edited, and saving writes that frame as a still picture.")
        }
        if let sauce {
            let typeNames: [UInt8: String] = [0: "ASCII text", 2: "an ANSiMation", 3: "RIPscrip", 4: "PCBoard",
                                              5: "Avatar", 6: "HTML", 7: "source code", 8: "TundraDraw"]
            switch sauce.dataType {
            case 1:
                if ![1, 4, 5].contains(sauce.fileType), let name = typeNames[sauce.fileType] {
                    let label = sauce.fileType == 2 ? "ANSiMation" : name
                    notes.append("SAUCE marks this file as \(label) (file type \(sauce.fileType)); the editor saves it in the format chosen in Save As, with that format's type.")
                } else if sauce.fileType > 8 {
                    notes.append("SAUCE file type \(sauce.fileType) is not a known character type; saving writes the type of the chosen format.")
                }
            case 0, 5, 6: break
            default:
                notes.append("SAUCE data type \(sauce.dataType) is not character art; saving writes the type of the chosen format.")
            }
        }
        if file.format.isStream, file.format != .avatar {
            let body = raw.prefix(contentLength)
            if let eof = body.firstIndex(of: 0x1A) {
                let after = body[(eof + 1)...]
                if after.contains(where: { $0 != 0 && $0 != 0x1A }) {
                    notes.append("\(after.count) bytes after the end of file marker (hidden from viewers) are not kept.")
                }
            }
        }
        if file.format == .xbin, raw.count > 10, Array(raw.prefix(4)) == Array("XBIN".utf8) {
            let flags = raw[10]
            if flags & 0x01 != 0 {
                notes.append("The file embeds its own palette: XBin, ADF and iCE Draw saves keep it, ANSI saves write its colours as 24 bit colour, and the other formats use the nearest VGA colours.")
            }
            if flags & 0x02 != 0 {
                notes.append("The file embeds its own font: XBin, ADF and iCE Draw saves keep it; other formats save only the font name \"\(sauce?.fontName.isEmpty == false ? sauce!.fontName : "IBM VGA")\".")
            }
            if flags & 0x10 != 0 {
                notes.append("The file uses a 512 character font; characters above 255 cannot be kept.")
            }
        }
        return notes
    }

    /// Notes for saving `canvas` as `format`.
    public static func saveReport(_ canvas: EditCanvas, format: SaveFormat) -> [String] {
        var unmappable = 0, nonVGA = 0
        for row in canvas.rows {
            for cell in row {
                if cell.scalar != nil { unmappable += 1 }
                if Palette.vgaIndex(of: cell.fg) == nil || Palette.vgaIndex(of: cell.bg) == nil { nonVGA += 1 }
            }
        }
        var notes: [String] = []
        if unmappable > 0 {
            notes.append("\(unmappable) \(unmappable == 1 ? "character has" : "characters have") no CP437 equivalent and \(unmappable == 1 ? "is" : "are") saved as \"?\".")
        }
        let name = format.name
        // XBin, ADF and IDF store the canvas's own 16 colours; others only the VGA ones.
        let storesPalette = [SaveFormat.xbin, .adf, .idf].contains(format) && canvas.palette != nil
        if ![.ansi, .ice].contains(format), nonVGA > 0, !storesPalette {
            notes.append("\(nonVGA) \(nonVGA == 1 ? "cell uses" : "cells use") colours outside the 16 VGA colours; \(name) saves the nearest VGA colour.")
        }
        if format == .bin, canvas.columns % 2 == 1 {
            notes.append("BinaryText needs an even width: the odd width \(canvas.columns) gets one blank column.")
        }
        let blinking = !canvas.iceColors && canvas.rows.contains { $0.contains { $0.blink } }
        if [.ice, .adf, .idf].contains(format), blinking {
            notes.append("\(name) files always use iCE colours: blinking cells show a bright background instead.")
        }
        if format == .adf {
            if canvas.columns < 80 { notes.append("Artworx ADF files are always 80 columns wide: the art is padded from \(canvas.columns) columns.") }
            if canvas.columns > 80 { notes.append("Artworx ADF files are always 80 columns wide; this art is \(canvas.columns). Save it as iCE Draw or XBin.") }
        }
        if [.adf, .idf, .wildcat].contains(format), !(canvas.title + canvas.author + canvas.group).isEmpty || !canvas.comments.isEmpty {
            notes.append("\(name) files carry no SAUCE record: the title, author, group and comments are not saved.")
        }
        if [.adf, .idf].contains(format) {
            let font = canvas.embeddedFont ?? BitmapFont.named(canvas.fontName)
            if font.height != 16 || font.width != 8 {
                notes.append("\(name) files hold an 8x16 font: the art is saved with IBM VGA instead of \(font.name) (\(font.width)x\(font.height)).")
            }
        }
        if format == .wildcat {
            if canvas.columns > 80 { notes.append("Wildcat! files carry no width: art \(canvas.columns) columns wide opens as 80 columns.") }
            if canvas.iceColors { notes.append("Wildcat! files carry no iCE flag: bright backgrounds show as blinking when the file is opened again.") }
        }
        if format == .pcboard {
            let blackOnBlack = canvas.rows.reduce(0) { $0 + $1.filter { ArtWriter.attribute($0, ice: canvas.iceColors) == 0x00 && $0.code != 0x20 && $0.code != 0 }.count }
            let whiteOnGrey = canvas.rows.reduce(0) { $0 + $1.filter { ArtWriter.attribute($0, ice: canvas.iceColors) == 0xFF }.count }
            if blackOnBlack > 0 {
                notes.append("PCBoard reads @X00 as \"save the colour\": \(blackOnBlack) black on black \(blackOnBlack == 1 ? "character is" : "characters are") saved dark grey on black.")
            }
            if whiteOnGrey > 0 {
                notes.append("PCBoard reads @XFF as \"restore the colour\": \(whiteOnGrey) bright white on bright grey \(whiteOnGrey == 1 ? "cell is" : "cells are") saved without the bright background.")
            }
        }
        return notes
    }
}
