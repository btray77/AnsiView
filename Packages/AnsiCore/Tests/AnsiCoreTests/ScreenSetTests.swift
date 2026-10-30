import Foundation
import Testing
@testable import AnsiCore

private let day = Date(timeIntervalSince1970: 1_800_000_000)

@Test func screenSetStatusFollowsExportAndEdits() {
    var entry = ScreenSetEntry(slot: .mainMenu, fileName: "text/menu/main.ans")
    entry.sourcePath = "/art/main.ans"
    #expect(ScreenSet.status(entry, current: Data([1]), inFolder: nil) == .notExported)

    // The file (with SAUCE, whose date changes daily) is compared with the folder; the body
    // (what the screen draws) with the source as it exports now.
    entry.recordExport(file: Data([1, 9]), body: Data([1]), at: day)
    #expect(ScreenSet.status(entry, current: Data([1]), inFolder: Data([1, 9])) == .exported(day))
    #expect(ScreenSet.status(entry, current: Data([2]), inFolder: Data([1, 9])) == .modifiedSince(day))
    #expect(ScreenSet.status(entry, current: Data([1]), inFolder: Data([3])) == .changedInFolder(day))
    #expect(ScreenSet.status(entry, current: Data([1]), inFolder: nil) == .missingInFolder(day))
    #expect(ScreenSet.status(entry, current: nil, inFolder: Data([1, 9])) == .sourceMissing(day))
}

@Test func screenExportedFromAnUnsavedEditorIsNotASourceProblem() {
    var entry = ScreenSetEntry(slot: .mainMenu, fileName: "main.ans")
    entry.recordExport(file: Data([1]), body: Data([1]), at: day)
    // No source path: nothing to compare with, so it stays Exported while the folder matches.
    #expect(ScreenSet.status(entry, current: nil, inFolder: Data([1])) == .exported(day))
    entry.sourcePath = "/gone.ans"
    #expect(ScreenSet.status(entry, current: nil, inFolder: Data([1])) == .sourceMissing(day))
}

@Test func screenSetStatusLabels() {
    #expect(ScreenSetStatus.notExported.label == "Not exported")
    #expect(ScreenSetStatus.modifiedSince(day).label.hasPrefix("Modified since export"))
    #expect(!ScreenSetStatus.exported(day).needsExport)
    #expect(ScreenSetStatus.modifiedSince(day).needsExport)
}

@Test func screenSetRoundTripsAsJSON() throws {
    var set = ScreenSet(profileID: UUID())
    var entry = ScreenSetEntry(slot: .goodbye, fileName: "GOODBYE.ANS")
    entry.sourcePath = "/tmp/bye.ans"
    entry.recordExport(file: Data("x".utf8), body: Data("y".utf8), at: day)
    set.upsert(entry)
    var replacement = entry
    replacement.fileName = "LOGOFF.ANS"
    set.upsert(replacement)
    #expect(set.entries.count == 1)
    let decoded = try ScreenSet(data: set.data())
    #expect(decoded == set)
    #expect(decoded.entries[0].fileName == "LOGOFF.ANS")
    #expect(decoded.entries[0].exportedSHA256 == ScreenSet.sha256(Data("x".utf8)))
    #expect(decoded.entries[0].bodySHA256 == ScreenSet.sha256(Data("y".utf8)))
}
