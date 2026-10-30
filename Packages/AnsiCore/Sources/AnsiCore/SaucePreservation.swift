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
                if sauce.fileType != 1, let name = typeNames[sauce.fileType] {
                    let label = sauce.fileType == 2 ? "ANSiMation" : name
                    notes.append("SAUCE marks this file as \(label) (file type \(sauce.fileType)); the editor saves it as ANSI art, BinaryText or XBin with the matching type.")
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
                notes.append("The file embeds its own palette: the colours are kept exactly in ANSI saves; BinaryText and XBin saves use the nearest VGA colours and no palette.")
            }
            if flags & 0x02 != 0 {
                notes.append("The file embeds its own font, which is not saved; the art is saved with the font name \"\(sauce?.fontName.isEmpty == false ? sauce!.fontName : "IBM VGA")\".")
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
        if format != .ansi, nonVGA > 0 {
            notes.append("\(nonVGA) \(nonVGA == 1 ? "cell uses" : "cells use") colours outside the 16 VGA colours; \(format == .bin ? "BinaryText" : "XBin") saves the nearest VGA colour.")
        }
        if format == .bin, canvas.columns % 2 == 1 {
            notes.append("BinaryText needs an even width: the odd width \(canvas.columns) gets one blank column.")
        }
        return notes
    }
}
