import Foundation
import Testing
@testable import AnsiCore

@Suite struct SaucePreservationTests {
    private func ansFile(dataType: UInt8 = 1, fileType: UInt8 = 1, flags: UInt8 = 0x01 | 0x04 | 0x20,
                         tInfo: [UInt16] = [80, 1, 7, 9], comments: [String] = ["  indented comment", "second"],
                         body: [UInt8] = Array("\u{1B}[1;33mHi".utf8), trailing: [UInt8] = []) -> Data {
        let sauce = Sauce(title: "Title", author: "Author", group: "Group", date: DateComponents(year: 1994, month: 7, day: 4),
                          dataType: dataType, fileType: fileType, tInfo: tInfo, flags: flags, fontName: "IBM VGA50",
                          comments: comments)
        // The marker, then data a viewer never shows, then the SAUCE (the encoder adds its own marker).
        let tail = trailing.isEmpty ? [] : [0x1A] + trailing
        return Data(body + tail + sauce.encoded(fileSize: body.count))
    }

    @Test func commentsKeepLeadingSpaces() {
        let (sauce, _) = Sauce.read([UInt8](ansFile()))
        #expect(sauce?.comments == ["  indented comment", "second"])
    }

    @Test func sauceFieldsSurviveLoadAndSave() throws {
        let file = ArtFile(data: ansFile(), fileExtension: "ans")
        let canvas = EditCanvas(file: file)
        let saved = try ArtWriter.data(canvas, format: .ansi, date: Date(timeIntervalSince1970: 0))
        let (sauce, _) = Sauce.read([UInt8](saved))
        let s = try #require(sauce)
        #expect(s.title == "Title" && s.author == "Author" && s.group == "Group")
        #expect(s.comments == ["  indented comment", "second"])
        #expect(s.flags == 0x01 | 0x04 | 0x20)
        #expect(s.fontName == "IBM VGA50")
        #expect(Array(s.tInfo[2...3]) == [7, 9])
        // The SAUCE date is the creation date: an edited file keeps it.
        #expect(s.date == DateComponents(year: 1994, month: 7, day: 4))
        // XBin keeps them too.
        let xb = try ArtWriter.data(canvas, format: .xbin)
        let x = try #require(Sauce.read([UInt8](xb)).sauce)
        #expect(Array(x.tInfo[2...3]) == [7, 9] && x.comments == s.comments && x.flags == s.flags)
        // New art is dated when saved.
        let fresh = try ArtWriter.data(EditCanvas(), format: .ansi, date: Date(timeIntervalSince1970: 86_400 * 400))
        #expect(Sauce.read([UInt8](fresh)).sauce?.date?.year == 1971)
    }

    @Test func plainFileReportsNothing() {
        let data = ansFile(flags: 0x01, tInfo: [80, 1, 0, 0])
        let file = ArtFile(data: data, fileExtension: "ans")
        #expect(SaucePreservation.openReport(data: data, fileExtension: "ans").isEmpty)
        #expect(SaucePreservation.saveReport(EditCanvas(file: file), format: .ansi).isEmpty)
    }

    @Test func reportsWhatCannotBeKept() {
        let ansimation = SaucePreservation.openReport(data: ansFile(fileType: 2), fileExtension: "ans")
        #expect(ansimation.contains { $0.contains("ANSiMation") })
        let ascii = SaucePreservation.openReport(data: ansFile(fileType: 0), fileExtension: "ans")
        #expect(ascii.contains { $0.contains("ASCII") })
        let trailing = SaucePreservation.openReport(data: ansFile(trailing: Array("hidden".utf8)), fileExtension: "ans")
        #expect(trailing.contains { $0.contains("6 bytes") })
        // Padding after the marker (NULs or more markers) is not worth a report.
        #expect(SaucePreservation.openReport(data: ansFile(flags: 0x01, tInfo: [80, 1, 0, 0], trailing: [0, 0, 0x1A]),
                                             fileExtension: "ans").isEmpty)
        // An animation edits its final frame only.
        var frames: [UInt8] = []
        for frame in 0..<6 { frames += Array("\u{1B}[2J\u{1B}[1;1HFrame \(frame)".utf8) }
        let animated = SaucePreservation.openReport(data: Data(frames), fileExtension: "ans")
        #expect(animated.contains { $0.contains("final frame") })
    }

    @Test func reportsEmbeddedXBinFontAndPalette() {
        var bytes = Array("XBIN".utf8) + [0x1A, 1, 0, 1, 0, 16, 0x03]
        bytes += Array(repeating: 0x10, count: 48) // palette
        bytes += Array(repeating: 0xFF, count: 256 * 16) // font
        bytes += [0x41, 0x07]
        let report = SaucePreservation.openReport(data: Data(bytes), fileExtension: "xb")
        #expect(report.contains { $0.contains("font") } && report.contains { $0.contains("palette") })
    }

    @Test func saveReports() {
        var canvas = EditCanvas(columns: 3, height: 1)
        canvas.set(AnsiCell(code: 0x3F, scalar: "€"), x: 0, y: 0)
        canvas.set(AnsiCell(code: 0x41, fg: RGB(r: 1, g: 2, b: 3)), x: 1, y: 0)
        let ansi = SaucePreservation.saveReport(canvas, format: .ansi)
        #expect(ansi.contains { $0.contains("1 character") } && !ansi.contains { $0.contains("VGA") })
        let bin = SaucePreservation.saveReport(canvas, format: .bin)
        #expect(bin.contains { $0.contains("VGA") } && bin.contains { $0.contains("odd") })
    }
}
