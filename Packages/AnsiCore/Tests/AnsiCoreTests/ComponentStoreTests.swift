import Foundation
import Testing
@testable import AnsiCore

private func storeFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("components-\(UUID().uuidString)")
}

@Test func savedComponentKeepsEveryCellExactly() throws {
    let store = ComponentStore(directory: storeFolder())
    #expect(store.all().isEmpty)
    let cells = [[AnsiCell(code: 0xC9, fg: Palette.vga[14], bg: Palette.vga[1]), AnsiCell(code: 0x41, fg: Palette.vga[7], bg: Palette.vga[0], blink: true)],
                 [AnsiCell(code: 0xDB, fg: RGB(r: 1, g: 2, b: 3), bg: Palette.vga[0]), AnsiCell()]]
    let saved = try store.save(name: "My header", region: CanvasRegion(cells: cells))
    let all = store.all()
    #expect(all.count == 1)
    #expect(all[0].name == "My header")
    #expect(all[0].id == saved.id)
    #expect(all[0].region == CanvasRegion(cells: cells))
}

@Test func componentStoreRenamesAndDeletes() throws {
    let store = ComponentStore(directory: storeFolder())
    let a = try store.save(name: "A", region: CanvasRegion(cells: [[AnsiCell(code: 0x41)]]))
    _ = try store.save(name: "B", region: CanvasRegion(cells: [[AnsiCell(code: 0x42)]]))
    try store.rename(a.id, to: "Alpha")
    #expect(store.all().map(\.name) == ["Alpha", "B"])
    try store.delete(a.id)
    #expect(store.all().map(\.name) == ["B"])
}

@Test func componentStoreRefusesEmptyRegionsAndSkipsDamagedFiles() throws {
    let folder = storeFolder()
    let store = ComponentStore(directory: folder)
    #expect(throws: ComponentStore.StoreError.empty) { try store.save(name: "x", region: CanvasRegion(cells: [])) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: folder.appendingPathComponent("junk.json"))
    #expect(store.all().isEmpty)
}
