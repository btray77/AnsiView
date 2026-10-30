import Foundation
import Testing
@testable import AnsiCore

func makeTransferTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func directoryNames(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

@Suite struct TransferFileNameTests {
    @Test(arguments: [
        ("REPORT.ZIP", "REPORT.ZIP"),
        ("../../etc/passwd", "passwd"),
        ("/etc/passwd", "passwd"),
        ("C:\\DOS\\COMMAND.COM", "COMMAND.COM"),
        ("A:FILE.TXT", "FILE.TXT"),
        ("..", "download"),
        (".", "download"),
        ("", "download"),
        ("dir/", "download"),
        (".hidden", "_hidden"),
        ("...profile", "_profile"),
        ("bad\u{07}name\u{1B}[2J.txt", "bad_name_[2J.txt"),
        ("del\u{7F}.txt", "del_.txt"),
        ("trailing. . ", "trailing"),
        ("CON", "_CON"),
        ("con.txt", "_con.txt"),
        ("LPT1.DOC", "_LPT1.DOC"),
        ("COM9", "_COM9"),
        ("CONSOLE.TXT", "CONSOLE.TXT"),
        ("caf\u{E9}.txt", "caf\u{E9}.txt"),
    ])
    func sanitize(_ input: String, _ expected: String) {
        #expect(TransferFileName.sanitize(input) == expected)
    }

    @Test func lengthIsCappedKeepingTheExtension() {
        let name = String(repeating: "a", count: 400) + ".zip"
        let clean = TransferFileName.sanitize(name)
        #expect(clean.utf8.count <= TransferFileName.maxLength)
        #expect(clean.hasSuffix(".zip"))
    }

    @Test func multibyteNamesAreCutOnACharacterBoundary() {
        let name = String(repeating: "\u{E9}", count: 300)
        let clean = TransferFileName.sanitize(name)
        #expect(clean.utf8.count <= TransferFileName.maxLength)
        #expect(clean.allSatisfy { $0 == "\u{E9}" })
    }

    @Test func nonUTF8NameBytesAreReadAsCP437() {
        // 0x82 is e acute in CP437 and not valid UTF-8 on its own.
        #expect(TransferFileName.decode([0x43, 0x41, 0x46, 0x82]) == "CAF\u{E9}")
        #expect(TransferFileName.decode(Array("plain.txt".utf8)) == "plain.txt")
    }
}

@Suite struct DownloadsDirectorySinkTests {
    @Test func writesInsideTheDirectoryAndReportsSHA256() throws {
        let dir = makeTransferTempDir()
        let sink = DownloadsDirectorySink(directory: dir)
        #expect(sink.open(FileOffer(name: "../../escape.bin", size: 3)) == .accept(offset: 0))
        try sink.write([1, 2, 3])
        let file = try sink.finish()
        #expect(file.name == "escape.bin")
        #expect(file.url?.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(file.sha256 == "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81")
        #expect(directoryNames(dir) == ["escape.bin"])
    }

    @Test func neverOverwritesAnExistingFile() throws {
        let dir = makeTransferTempDir()
        try Data([9]).write(to: dir.appendingPathComponent("a.txt"))
        let sink = DownloadsDirectorySink(directory: dir)
        for _ in 0..<2 {
            _ = sink.open(FileOffer(name: "a.txt", size: 1))
            try sink.write([7])
            _ = try sink.finish()
        }
        #expect(directoryNames(dir) == ["a-1.txt", "a-2.txt", "a.txt"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data([9]))
    }

    @Test func refusesAnAnnouncedSizeOverTheLimit() {
        let dir = makeTransferTempDir()
        var options = DownloadsDirectorySink.Options()
        options.maxFileSize = 100
        let sink = DownloadsDirectorySink(directory: dir, options: options)
        if case .skip = sink.open(FileOffer(name: "big.bin", size: 101)) {} else { Issue.record("not refused") }
        #expect(directoryNames(dir).isEmpty)
    }

    @Test func failsWhenDataExceedsTheLimitOrTheAnnouncedSize() throws {
        let dir = makeTransferTempDir()
        var options = DownloadsDirectorySink.Options()
        options.maxFileSize = 10
        let sink = DownloadsDirectorySink(directory: dir, options: options)
        _ = sink.open(FileOffer(name: "unknown.bin", size: nil))
        try sink.write(Array(repeating: 0, count: 10))
        #expect(throws: TransferFileError.tooLarge(limit: 10)) { try sink.write([0]) }
        sink.abort(resumable: false)
        _ = sink.open(FileOffer(name: "liar.bin", size: 4))
        try sink.write([1, 2, 3, 4])
        #expect(throws: TransferFileError.exceedsAnnounced(size: 4)) { try sink.write([5]) }
        sink.abort(resumable: false)
        #expect(directoryNames(dir).isEmpty)
    }

    @Test func abortRemovesThePartialUnlessKeptForResume() throws {
        let dir = makeTransferTempDir()
        let sink = DownloadsDirectorySink(directory: dir)
        _ = sink.open(FileOffer(name: "x.bin", size: 10))
        try sink.write([1, 2])
        sink.abort(resumable: true)
        #expect(directoryNames(dir).isEmpty)

        var keep = DownloadsDirectorySink.Options()
        keep.keepPartialForResume = true
        let keeper = DownloadsDirectorySink(directory: dir, options: keep)
        _ = keeper.open(FileOffer(name: "x.bin", size: 10))
        try keeper.write([1, 2])
        keeper.abort(resumable: false)
        #expect(directoryNames(dir).isEmpty, "a protocol that cannot resume never keeps a part")
        _ = keeper.open(FileOffer(name: "x.bin", size: 10))
        try keeper.write([1, 2])
        keeper.abort(resumable: true)
        #expect(directoryNames(dir) == ["x.bin.part"])
    }

    @Test func resumesFromAKeptPartialAndHashesTheWholeFile() throws {
        let dir = makeTransferTempDir()
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("r.bin.part"))
        let sink = DownloadsDirectorySink(directory: dir)
        #expect(sink.open(FileOffer(name: "r.bin", size: 5, resumeRequested: true)) == .accept(offset: 3))
        try sink.write([4, 5])
        let file = try sink.finish()
        #expect(file.resumedFrom == 3)
        #expect(file.bytes == 5)
        #expect(try Data(contentsOf: dir.appendingPathComponent("r.bin")) == Data([1, 2, 3, 4, 5]))
        #expect(file.sha256 == TransferHash.sha256Hex([1, 2, 3, 4, 5]))
    }

    @Test func doesNotResumeWithoutARequestOrWhenThePartIsNotShorter() throws {
        let dir = makeTransferTempDir()
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("r.bin.part"))
        let sink = DownloadsDirectorySink(directory: dir)
        #expect(sink.open(FileOffer(name: "r.bin", size: 5)) == .accept(offset: 0))
        sink.abort(resumable: false)
        #expect(sink.open(FileOffer(name: "r.bin", size: 3, resumeRequested: true)) == .accept(offset: 0))
        sink.abort(resumable: false)
        #expect(directoryNames(dir) == ["r.bin.part"], "the old part is left alone")
    }

    @Test func refusesToFollowASymlinkPlantedAtThePartPath() throws {
        let dir = makeTransferTempDir()
        let outside = makeTransferTempDir().appendingPathComponent("victim")
        try Data([0]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("v.bin.part"), withDestinationURL: outside)
        let sink = DownloadsDirectorySink(directory: dir)
        #expect(sink.open(FileOffer(name: "v.bin", size: 4, resumeRequested: true)) == .accept(offset: 0))
        try sink.write([1, 2, 3, 4])
        _ = try sink.finish()
        #expect(try Data(contentsOf: outside) == Data([0]), "the symlink target is untouched")
        #expect(try Data(contentsOf: dir.appendingPathComponent("v.bin")) == Data([1, 2, 3, 4]))
    }
}

@Suite struct OutgoingFileTests {
    @Test func readsFromDiskWithAttributes() throws {
        let dir = makeTransferTempDir()
        let url = dir.appendingPathComponent("send me.bin")
        try Data(0..<200).write(to: url)
        let file = try OutgoingFile(url: url)
        #expect(file.name == "send me.bin")
        #expect(file.size == 200)
        #expect(file.modified != nil)
        #expect(try file.read(offset: 190, count: 50) == Array(190..<200))
        #expect(try file.sha256() == TransferHash.sha256Hex(Array(0..<200)))
    }
}
