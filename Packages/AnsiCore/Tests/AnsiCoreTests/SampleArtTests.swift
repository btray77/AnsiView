import Foundation
import Testing
@testable import AnsiCore

/// The bundled samples in `Samples/`, made by `Packaging/samples/generate.swift`.
struct SampleArtTests {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let samples = repo.appendingPathComponent("Samples")

    func load(_ name: String) throws -> ArtFile {
        let url = Self.samples.appendingPathComponent(name)
        return ArtFile(data: try Data(contentsOf: url), fileExtension: url.pathExtension)
    }

    @Test func welcomeHasSauce() throws {
        let file = try load("Welcome.ans")
        let sauce = try #require(file.sauce)
        #expect(sauce.title == "Welcome to AnsiView")
        #expect(sauce.author == "AnsiView")
        #expect(sauce.group == "AnsiView Samples")
        #expect(sauce.fontName == "IBM VGA")
        #expect(sauce.comments.count == 2)
        #expect(sauce.date == DateComponents(year: 2026, month: 10, day: 30))
        #expect(file.format == .ansi)
        let analysis = AnsiAnalysis(file)
        #expect(!analysis.isAnimated)
        #expect(ArtText.plainText(analysis.finalScreen).contains("Welcome to AnsiView."))
        #expect(analysis.canvasRows == 25)
    }

    @Test func rocketIsAnimated() throws {
        let file = try load("Rocket Launch.ans")
        let analysis = AnsiAnalysis(file)
        #expect(analysis.isAnimated)
        #expect(ArtText.plainText(analysis.finalScreen).contains("LIFTOFF!"))
        #expect(file.sauce?.title == "Rocket Launch")
        #expect(analysis.canvasRows == 25)
    }

    @Test func sunsetIsTrueColour() throws {
        let file = try load("Sunset 24-bit.ans")
        let screen = AnsiAnalysis(file).finalScreen
        var colours = Set<RGB>()
        for row in screen.rows { for cell in row { colours.insert(cell.fg); colours.insert(cell.bg) } }
        #expect(colours.count > 100)
        #expect(screen.rows.count == 25)
        #expect(screen.rows.allSatisfy { $0.prefix(80).allSatisfy { $0.code == 0xDF } })
        #expect(file.sauce?.title == "Sunset in 24-bit Colour")
    }

    @Test func customFontXBin() throws {
        let file = try load("Custom Font.xb")
        #expect(file.format == .xbin)
        #expect(file.columns == 80)
        let screen = AnsiAnalysis(file).finalScreen
        #expect(screen.rows.count == 25)
        #expect(screen.font.height == 16)
        // Its own letters: the embedded "A" is not the VGA "A".
        #expect(screen.font.pixels(for: 0x41) != BitmapFont.vga.pixels(for: 0x41))
        #expect(screen.font.pixels(for: 0xDB).allSatisfy { $0 })
        // Its own palette: the background of the first row is not VGA black.
        #expect(screen.rows[0][0].bg != Palette.vga[0])
        #expect(ArtText.plainText(screen).contains("CUSTOM FONT"))
    }

    /// Regenerating gives the committed bytes.
    @Test func generatorIsDeterministic() throws {
        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        guard FileManager.default.isExecutableFile(atPath: swift.path) else { return }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("samples-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let process = Process()
        process.executableURL = swift
        process.arguments = [Self.repo.appendingPathComponent("Packaging/samples/generate.swift").path, out.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        for name in ["Welcome.ans", "Rocket Launch.ans", "Sunset 24-bit.ans", "Custom Font.xb"] {
            let fresh = try Data(contentsOf: out.appendingPathComponent(name))
            let committed = try Data(contentsOf: Self.samples.appendingPathComponent(name))
            #expect(fresh == committed, "\(name) differs from a fresh run of the generator")
        }
    }
}
