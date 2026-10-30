import Foundation
import Testing
@testable import AnsiCore

struct ArtLibraryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func sauced(_ text: String, title: String, author: String, group: String, date: String) -> Data {
        let body = Array(text.utf8)
        var components = DateComponents()
        components.year = Int(date.prefix(4))
        components.month = Int(date.dropFirst(4).prefix(2))
        components.day = Int(date.suffix(2))
        let sauce = Sauce(title: title, author: author, group: group, date: components, dataType: 1, fileType: 1,
                          tInfo: [80, 1, 0, 0], flags: 0, fontName: "IBM VGA", comments: ["first line", "second"])
        return Data(body + [0x1A] + sauce.encoded(fileSize: body.count))
    }

    func tempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func run(_ tool: String, _ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.currentDirectoryURL = dir
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }

    @Test func recordHasSauceTextAndHashes() {
        let data = sauced("\u{1B}[1;33mWELCOME TO THE BOARD", title: "Welcome", author: "Lord Jazz", group: "ACiD",
                          date: "19960412")
        let record = LibraryScanner.record(data: data, path: "/art/WELCOME.ANS", entry: nil, size: data.count,
                                           modified: now, now: now)
        #expect(record.name == "WELCOME.ANS")
        #expect(record.key == "/art/WELCOME.ANS")
        #expect(record.title == "Welcome")
        #expect(record.author == "Lord Jazz")
        #expect(record.group == "ACiD")
        #expect(record.date == "19960412")
        #expect(record.year == 1996)
        #expect(record.comments == "first line\nsecond")
        #expect(record.format == "ANSI")
        #expect(record.columns == 80)
        #expect(record.rows == 1)
        #expect(record.text == "WELCOME TO THE BOARD")
        #expect(record.byteHash == ByteHash.of(data))
        #expect(record.identity == ArtFile(data: data).identity)
        #expect(record.cellHash == CellHash.of(AnsiAnalysis(ArtFile(data: data, fileExtension: "ans")).finalScreen))
        #expect(record.added == now)
        #expect(record.haystack.matches(words: ArtSearch.words("acid board")))
        let packed = LibraryScanner.record(data: data, path: "/p.zip", entry: "art/W.ANS", size: 9, modified: now, now: now)
        #expect(packed.key == "/p.zip#art/W.ANS")
        #expect(packed.name == "W.ANS")
        #expect(packed.packName == "p.zip")
    }

    @Test func longTextIsCapped() {
        let data = Data(String(repeating: "ABCDEFGHIJ\r\n", count: 4000).utf8)
        let record = LibraryScanner.record(data: data, path: "/t.asc", entry: nil, size: data.count, modified: now, now: now)
        #expect(record.text.count <= LibraryScanner.textLimit)
    }

    @Test func listingRecursesAndFindsPacks() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for sub in ["sub", ".hidden", "__MACOSX"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data("A".utf8).write(to: dir.appendingPathComponent("one.ans"))
        try Data("B".utf8).write(to: dir.appendingPathComponent("sub/two.ASC"))
        try Data("C".utf8).write(to: dir.appendingPathComponent(".hidden/three.ans"))
        try Data("D".utf8).write(to: dir.appendingPathComponent("__MACOSX/four.ans"))
        try Data("E".utf8).write(to: dir.appendingPathComponent("readme.txt"))
        try run("/usr/bin/zip", ["-q", "sub/pack.zip", "one.ans"], in: dir)
        let listed = LibraryScanner.listing(folder: dir)
        let names = listed.map { $0.url.lastPathComponent }.sorted()
        #expect(names == ["one.ans", "pack.zip", "two.ASC"])
        #expect(listed.first { $0.url.lastPathComponent == "pack.zip" }?.isPack == true)
        #expect(listed.first { $0.url.lastPathComponent == "one.ans" }?.size == 1)
    }

    @Test func listingKeepsTheFolderPathAsGiven() throws {
        // The temporary folder is under /var, a symbolic link to /private/var: listed paths must
        // start with the folder's path as given, so rescans recognise the files they read before.
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data("A".utf8).write(to: dir.appendingPathComponent("a/x.ans"))
        for form in [dir.standardizedFileURL, dir.resolvingSymlinksInPath()] {
            let listed = LibraryScanner.listing(folder: form)
            #expect(listed.map(\.url.path) == [form.path + "/a/x.ans"])
        }
    }

    @Test func packRecordsOnePerEntry() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("art"), withIntermediateDirectories: true)
        try Data("HELLO".utf8).write(to: dir.appendingPathComponent("art/a.ans"))
        try Data("WORLD".utf8).write(to: dir.appendingPathComponent("FILE_ID.DIZ"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try run("/usr/bin/zip", ["-q", "pack.zip", "art/a.ans", "FILE_ID.DIZ", "notes.txt"], in: dir)
        let zip = dir.appendingPathComponent("pack.zip")
        let records = try LibraryScanner.records(pack: zip, size: 10, modified: now, now: now)
        #expect(records.map(\.entry) == ["art/a.ans", "FILE_ID.DIZ"])
        #expect(records.allSatisfy { $0.path == zip.path && $0.size == 10 })
        #expect(records[0].text == "HELLO")
    }

    func record(_ path: String, entry: String? = nil, size: Int = 1, modified: Date) -> IndexRecord {
        LibraryScanner.record(data: Data("X".utf8), path: path, entry: entry, size: size, modified: modified, now: modified)
    }

    @Test func plannerSkipsUnchanged() {
        let date = Date(timeIntervalSince1970: 1000)
        let existing = [record("/f/a.ans", modified: date), record("/f/p.zip", entry: "x.ans", modified: date),
                        record("/f/p.zip", entry: "y.ans", modified: date)]
        let listed = [ListedFile(url: URL(fileURLWithPath: "/f/a.ans"), size: 1, modified: date, isPack: false),
                      ListedFile(url: URL(fileURLWithPath: "/f/p.zip"), size: 1, modified: date.addingTimeInterval(0.0004), isPack: true)]
        let plan = IndexPlanner.plan(existing: existing, listed: listed)
        #expect(plan.scan.isEmpty)
        #expect(plan.keep.count == 3)
        #expect(plan.removed.isEmpty)
    }

    @Test func plannerRescansChangedAndForgetsRemoved() {
        let date = Date(timeIntervalSince1970: 1000)
        let existing = [record("/f/a.ans", modified: date), record("/f/b.ans", modified: date),
                        record("/f/gone.ans", modified: date)]
        let listed = [ListedFile(url: URL(fileURLWithPath: "/f/a.ans"), size: 2, modified: date, isPack: false),
                      ListedFile(url: URL(fileURLWithPath: "/f/b.ans"), size: 1, modified: date.addingTimeInterval(5), isPack: false),
                      ListedFile(url: URL(fileURLWithPath: "/f/new.ans"), size: 1, modified: date, isPack: false)]
        let plan = IndexPlanner.plan(existing: existing, listed: listed)
        #expect(plan.scan.map(\.url.lastPathComponent) == ["a.ans", "b.ans", "new.ans"])
        #expect(plan.keep.isEmpty)
        #expect(plan.removed == ["/f/gone.ans"])
    }

    @Test func recordsRoundTripThroughJSON() throws {
        let data = sauced("HI", title: "T", author: "A", group: "G", date: "19950101")
        let records = [LibraryScanner.record(data: data, path: "/a.ans", entry: nil, size: 3, modified: now, now: now)]
        let file = try tempFolder().appendingPathComponent("index.json")
        try LibraryFiles.save(LibraryIndex(records: records), to: file)
        let loaded = LibraryFiles.load(LibraryIndex.self, from: file)
        #expect(loaded?.records == records)
        #expect(loaded?.version == LibraryIndex.currentVersion)
    }
}

struct LibraryDataTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func record(author: String = "", group: String = "", title: String = "", text: String = "", date: String? = nil,
                identity: String, added: Date? = nil, path: String = "/f/a.ans") -> IndexRecord {
        var r = LibraryScanner.record(data: Data("X".utf8), path: path, entry: nil, size: 1, modified: now, now: added ?? now)
        r.author = author
        r.group = group
        r.title = title
        r.text = text
        r.date = date
        r.byteHash = identity + String(repeating: "0", count: 48)
        return r
    }

    @Test func ratingsClampAndTagsNormalise() {
        var data = LibraryData()
        data.setRating(7, for: "abc")
        #expect(data.notes(for: "abc").rating == 5)
        data.setRating(-1, for: "abc")
        #expect(data.notes(for: "abc").rating == 0)
        data.setTags(["  Logos ", "ansi", "logos", "", "ANSI"], for: "abc")
        #expect(data.notes(for: "abc").tags == ["ansi", "Logos"])
        data.toggleFavourite("abc")
        #expect(data.notes(for: "abc").favourite)
        data.setTags(["Big"], for: "def")
        #expect(data.allTags == ["ansi", "Big", "Logos"])
        // A piece with no notes left is forgotten.
        data.setTags([], for: "def")
        #expect(data.notes["def"] == nil)
        #expect(data.notes(for: "zzz") == PieceNotes())
    }

    @Test func smartFolderAllAndAny() {
        let r = record(author: "Lord Jazz", group: "ACiD", text: "welcome", identity: "id1")
        var notes = PieceNotes()
        notes.tags = ["logos"]
        notes.rating = 3
        let all = SmartFolder(name: "x", matchAll: true, rules: [.tagIs("Logos"), .ratingAtLeast(3), .authorContains("jazz")])
        #expect(all.matches(r, notes: notes, now: now))
        let fails = SmartFolder(name: "x", matchAll: true, rules: [.tagIs("logos"), .ratingAtLeast(4)])
        #expect(!fails.matches(r, notes: notes, now: now))
        let any = SmartFolder(name: "x", matchAll: false, rules: [.favourite, .groupContains("acid")])
        #expect(any.matches(r, notes: notes, now: now))
        #expect(SmartFolder(name: "x", matchAll: true, rules: [.tagIsNot("logos")]).matches(r, notes: notes, now: now) == false)
        #expect(SmartFolder(name: "x", matchAll: true, rules: [.textContains("WELCOME")]).matches(r, notes: notes, now: now))
        #expect(SmartFolder(name: "x", matchAll: true, rules: [.formatIs("ansi")]).matches(r, notes: notes, now: now))
        #expect(SmartFolder(name: "x", matchAll: true, rules: [.folderIs("/f")]).matches(r, notes: notes, now: now))
        #expect(!SmartFolder(name: "x", matchAll: true, rules: [.folderIs("/g")]).matches(r, notes: notes, now: now))
        // No rules: everything.
        #expect(SmartFolder(name: "x", matchAll: false, rules: []).matches(r, notes: notes, now: now))
    }

    @Test func builtInSmartFolders() {
        let folders = SmartFolder.builtIn
        #expect(folders.map(\.name) == ["Favourites", "Rated 4 Stars or More", "Untagged", "Recently Added"])
        let fresh = record(identity: "a", added: now.addingTimeInterval(-86_400))
        let old = record(identity: "b", added: now.addingTimeInterval(-40 * 86_400))
        var starred = PieceNotes()
        starred.rating = 4
        starred.favourite = true
        #expect(folders[0].matches(fresh, notes: starred, now: now))
        #expect(!folders[0].matches(fresh, notes: PieceNotes(), now: now))
        #expect(folders[1].matches(fresh, notes: starred, now: now))
        #expect(folders[2].matches(fresh, notes: PieceNotes(), now: now))
        #expect(folders[3].matches(fresh, notes: PieceNotes(), now: now))
        #expect(!folders[3].matches(old, notes: PieceNotes(), now: now))
    }

    @Test func yearRulesUseSauceDate() {
        let r = record(date: "19960412", identity: "a")
        let folder = SmartFolder(name: "90s", matchAll: true, rules: [.yearFrom(1995), .yearTo(1996)])
        #expect(folder.matches(r, notes: PieceNotes(), now: now))
        #expect(!folder.matches(record(date: "19970101", identity: "b"), notes: PieceNotes(), now: now))
        #expect(!folder.matches(record(identity: "c"), notes: PieceNotes(), now: now))
    }

    @Test func roundTripsThroughJSON() throws {
        var data = LibraryData()
        data.folders = [LibraryFolder(path: "/Users/x/Art", bookmark: Data([1, 2, 3]))]
        data.setRating(4, for: "abc")
        data.smartFolders = [SmartFolder(name: "Mine", matchAll: false, rules: [.tagIs("a"), .yearFrom(1990), .untagged])]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try LibraryFiles.save(data, to: file)
        let loaded = LibraryFiles.load(LibraryData.self, from: file)
        #expect(loaded == data)
    }

    @Test func corruptFileLoadsNilAndIsKept() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{not json".utf8).write(to: file)
        #expect(LibraryFiles.load(LibraryData.self, from: file) == nil)
        // The broken file is set aside, not lost.
        #expect(FileManager.default.fileExists(atPath: file.path + ".broken"))
        #expect(LibraryFiles.load(LibraryData.self, from: file.appendingPathExtension("missing")) == nil)
    }
}
