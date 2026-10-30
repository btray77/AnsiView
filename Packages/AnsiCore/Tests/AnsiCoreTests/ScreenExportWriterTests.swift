import Foundation
import Testing
@testable import AnsiCore

private func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-export-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func exportWriterCreatesSubfoldersAndWrites() throws {
    let root = tempFolder()
    let target = root.appendingPathComponent("text/menu/main.ans")
    #expect(ScreenExportWriter.conflict(at: target) == nil)
    let result = try ScreenExportWriter.write(Data([1, 2, 3]), to: target, replacing: false)
    #expect(try Data(contentsOf: target) == Data([1, 2, 3]))
    #expect(result.backupURL == nil)
    #expect(!result.replaced)
    #expect(result.bytesWritten == 3)
}

@Test func exportWriterRefusesToOverwriteWithoutConfirmation() throws {
    let root = tempFolder()
    let target = root.appendingPathComponent("MAIN.ANS")
    try Data([9]).write(to: target)
    #expect(ScreenExportWriter.conflict(at: target)?.size == 1)
    #expect(throws: ScreenExportWriter.WriteError.wouldOverwrite("MAIN.ANS")) {
        try ScreenExportWriter.write(Data([1]), to: target, replacing: false)
    }
    #expect(try Data(contentsOf: target) == Data([9]))
}

@Test func exportWriterKeepsBackupWhenReplacing() throws {
    let root = tempFolder()
    let target = root.appendingPathComponent("MAIN.ANS")
    try Data([9]).write(to: target)
    let first = try ScreenExportWriter.write(Data([1]), to: target, replacing: true)
    #expect(first.replaced)
    #expect(first.backupURL?.lastPathComponent == "MAIN.ANS.bak")
    #expect(try Data(contentsOf: root.appendingPathComponent("MAIN.ANS.bak")) == Data([9]))
    #expect(try Data(contentsOf: target) == Data([1]))
    // A second replace keeps the original in .bak and the previous version in .bak2 (review fix).
    _ = try ScreenExportWriter.write(Data([2]), to: target, replacing: true)
    #expect(try Data(contentsOf: root.appendingPathComponent("MAIN.ANS.bak")) == Data([9]))
    #expect(try Data(contentsOf: root.appendingPathComponent("MAIN.ANS.bak2")) == Data([1]))
}

@Test func exportWriterRejectsPathsOutsideTheFolder() {
    #expect(ScreenExportWriter.safeRelativePath("../etc/passwd") == nil)
    #expect(ScreenExportWriter.safeRelativePath("/abs/main.ans") == nil)
    #expect(ScreenExportWriter.safeRelativePath("text/menu/main.ans") == "text/menu/main.ans")
    #expect(ScreenExportWriter.safeRelativePath("text//menu/./main.ans") == "text/menu/main.ans")
    #expect(ScreenExportWriter.safeRelativePath("") == nil)
}
