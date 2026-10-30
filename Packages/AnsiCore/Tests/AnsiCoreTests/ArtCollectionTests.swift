import Foundation
import Testing
@testable import AnsiCore

struct ArtCollectionTests {
    @Test func filtersAndSortsLikeFinder() {
        let names = ["b.ANS", "a10.ans", "a2.ans", ".hidden.ans", "readme.txt", "__MACOSX/x.ans", "pic.XB", "noext"]
        #expect(ArtFiles.ordered(names) == ["a2.ans", "a10.ans", "b.ANS", "pic.XB"])
        #expect(ArtFiles.isArt("DIR/SUB/LOGO.Nfo"))
        #expect(!ArtFiles.isArt("DIR/._LOGO.ans"))
    }

    @Test func emptyListStepsNowhere() {
        #expect(ArtFiles.ordered([]).isEmpty)
        #expect(SlideOrder.step(0, by: 1, count: 0) == 0)
        #expect(SlideOrder.step(5, by: -1, count: 0) == 0)
    }

    @Test func stepWraps() {
        #expect(SlideOrder.step(2, by: 1, count: 3) == 0)
        #expect(SlideOrder.step(0, by: -1, count: 3) == 2)
        #expect(SlideOrder.step(1, by: 1, count: 3) == 2)
        #expect(SlideOrder.step(0, by: 1, count: 1) == 0)
    }

    /// Builds a zip with /usr/bin/zip: "art/one.ans" deflated, "two.ans" stored, "notes.txt".
    func makeZip() throws -> (Data, [String: Data]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("art"), withIntermediateDirectories: true)
        let one = Data(String(repeating: "\u{1B}[31mHELLO ", count: 200).utf8)
        let two = Data("plain stored text".utf8)
        try one.write(to: dir.appendingPathComponent("art/one.ans"))
        try two.write(to: dir.appendingPathComponent("two.ans"))
        try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        func zip(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = dir
            p.arguments = ["-q"] + args
            try p.run()
            p.waitUntilExit()
        }
        try zip(["pack.zip", "art/one.ans", "notes.txt"])
        try zip(["-0", "pack.zip", "two.ans"])
        let data = try Data(contentsOf: dir.appendingPathComponent("pack.zip"))
        try? FileManager.default.removeItem(at: dir)
        return (data, ["one.ans": one, "two.ans": two])
    }

    @Test func readsStoredAndDeflated() throws {
        let (data, expected) = try makeZip()
        let archive = try ZipArchive(data: data)
        #expect(archive.entries.count == 3)
        #expect(archive.artEntries.map(\.name) == ["one.ans", "two.ans"])
        #expect(archive.artEntries.map(\.path) == ["art/one.ans", "two.ans"])
        #expect(archive.entries.first { $0.name == "one.ans" }?.method == 8)
        #expect(archive.entries.first { $0.name == "two.ans" }?.method == 0)
        for entry in archive.artEntries {
            #expect(try archive.data(for: entry) == expected[entry.name])
        }
        #expect(archive.skippedCount == 0)
    }

    @Test func corruptZipThrows() throws {
        #expect(throws: ZipError.self) { try ZipArchive(data: Data((0..<500).map { UInt8($0 % 251) })) }
        #expect(throws: ZipError.self) { try ZipArchive(data: Data()) }
        let (data, _) = try makeZip()
        #expect(throws: ZipError.self) { try ZipArchive(data: data.prefix(data.count - 10)) }
    }

    /// Offset of the central directory header for `name`.
    func centralHeader(_ data: Data, _ name: String) -> Int {
        let bytes = [UInt8](data)
        let needle = Array(name.utf8)
        for i in 0..<(bytes.count - 46) where bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 1 && bytes[i + 3] == 2 {
            let length = Int(bytes[i + 28]) | Int(bytes[i + 29]) << 8
            if Array(bytes[(i + 46)..<(i + 46 + length)]) == needle { return i }
        }
        return -1
    }

    @Test func truncatedEntryIsSkipped() throws {
        var (data, _) = try makeZip()
        let header = centralHeader(data, "two.ans")
        // Compressed and uncompressed sizes far past the end of the file.
        for offset in [20, 24] { data.replaceSubrange((header + offset)..<(header + offset + 4), with: [0xFF, 0xFF, 0xFF, 0x0F]) }
        let archive = try ZipArchive(data: data)
        let entry = try #require(archive.entries.first { $0.name == "two.ans" })
        #expect(throws: ZipError.self) { try archive.data(for: entry) }
    }

    @Test func unsupportedMethodCounted() throws {
        var (data, _) = try makeZip()
        let header = centralHeader(data, "art/one.ans")
        data.replaceSubrange((header + 10)..<(header + 12), with: [6, 0])
        let archive = try ZipArchive(data: data)
        #expect(archive.artEntries.map(\.name) == ["two.ans"])
        #expect(archive.skippedCount == 1)
        let entry = try #require(archive.entries.first { $0.name == "one.ans" })
        #expect(throws: ZipError.self) { try archive.data(for: entry) }
    }

    @Test func garbageDeflateThrows() throws {
        var (data, _) = try makeZip()
        let header = centralHeader(data, "art/one.ans")
        let bytes = [UInt8](data)
        let local = Int(bytes[header + 42]) | Int(bytes[header + 43]) << 8 | Int(bytes[header + 44]) << 16
        let start = local + 30 + Int(bytes[local + 26]) + Int(bytes[local + 28])
        data.replaceSubrange(start..<(start + 8), with: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let archive = try ZipArchive(data: data)
        let entry = try #require(archive.entries.first { $0.name == "one.ans" })
        #expect(throws: ZipError.self) { try archive.data(for: entry) }
    }

    @Test func emptyDeflateDataThrows() throws {
        var (data, _) = try makeZip()
        let header = centralHeader(data, "art/one.ans")
        data.replaceSubrange((header + 20)..<(header + 24), with: [0, 0, 0, 0])
        let archive = try ZipArchive(data: data)
        let entry = try #require(archive.entries.first { $0.name == "one.ans" })
        #expect(throws: ZipError.self) { try archive.data(for: entry) }
    }

    @Test func zipErrorsReadWell() {
        #expect(ZipError.notAZip.localizedDescription == "This file is not a ZIP archive.")
        #expect(ZipError.corrupt.localizedDescription == "This ZIP archive is damaged or uses a format AnsiView cannot read.")
        #expect(ZipError.unsupportedMethod(6).localizedDescription == "This ZIP entry uses compression method 6, which AnsiView cannot read.")
    }
}
