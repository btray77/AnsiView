import Foundation
import Testing
@testable import AnsiCore

// Final review fixes (Important 1 to 4 and two minors), written before the fixes.

@Test func hugePaddingWidthsAreClamped() {
    let started = Date()
    for (code, package) in [("@USER:999999999999@", BBSPackage.pcboard), ("@ALIAS|L99999999@", .synchronet), ("|$R99|UH", .mystic)] {
        let out = BBSDisplay.render(Array(code.utf8), package: package, samples: SampleValues())
        #expect(out.count <= 1024, "\(code) gave \(out.count) bytes")
    }
    #expect(Date().timeIntervalSince(started) < 1)
}

@Test func exportAgainKeepsTheExactFileName() {
    var c = EditCanvas(columns: 132, height: 1)
    c.set(AnsiCell(code: 0x41), x: 0, y: 0)
    let project = ArtProject(layers: [CanvasLayer(name: "b", canvas: c)])
    let profile = ExportProfile(package: .synchronet)
    let first = ScreenExporter.export(project, profile: profile, slot: .bulletinList)
    #expect(first.relativePath == "text/menu/bulletin.132col.ans")
    let again = ScreenExporter.export(project, profile: profile, slot: .bulletinList, exactPath: first.relativePath)
    #expect(again.relativePath == first.relativePath)
}

@Test func theOriginalBackupIsNeverLost() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bak-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("MAIN.ANS")
    try Data("A".utf8).write(to: target)
    let first = try ScreenExportWriter.write(Data("B".utf8), to: target, replacing: true)
    let second = try ScreenExportWriter.write(Data("C".utf8), to: target, replacing: true)
    let third = try ScreenExportWriter.write(Data("D".utf8), to: target, replacing: true)
    #expect(try Data(contentsOf: root.appendingPathComponent("MAIN.ANS.bak")) == Data("A".utf8))
    #expect(try Data(contentsOf: root.appendingPathComponent("MAIN.ANS.bak2")) == Data("C".utf8))
    #expect(first.backupURL?.lastPathComponent == "MAIN.ANS.bak")
    #expect(second.backupURL?.lastPathComponent == "MAIN.ANS.bak2" && third.backupURL?.lastPathComponent == "MAIN.ANS.bak2")
}

@Test func packagesWithoutColourCodesFallBackToANSI() {
    var c = EditCanvas(columns: 10, height: 1)
    c.set(AnsiCell(code: 0x41, fg: Palette.vga[12]), x: 0, y: 0)
    var profile = ExportProfile(package: .proboard)
    profile.colourCodes = .native
    profile.sauce = false
    let out = ScreenExporter.export(ArtProject(layers: [CanvasLayer(name: "b", canvas: c)]), profile: profile, slot: .welcome)
    #expect(out.data.contains(0x1B))
    #expect(out.warnings.contains { $0.kind == .noColourCodes })
    #expect(!ColourCodeMode.modes(for: .proboard).contains(.native))
    #expect(ColourCodeMode.modes(for: .mystic) == [.ansi, .native])
}

@Test func themeNamesCannotChangeTheFolderLevel() {
    var profile = ExportProfile(package: .mystic)
    profile.themeName = "."
    #expect(profile.relativePath(slot: .welcome, columns: 80) == "themes/default/text/logon1.ans")
    profile.themeName = "../x"
    #expect(profile.relativePath(slot: .welcome, columns: 80) == "themes/x/text/logon1.ans")
}
