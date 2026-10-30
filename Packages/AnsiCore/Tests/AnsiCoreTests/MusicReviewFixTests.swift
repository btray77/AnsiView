import Foundation
import Testing
@testable import AnsiCore

/// Findings from the final review of the music branch.
@Suite struct MusicReviewFixTests {
    private let esc: UInt8 = 0x1B
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func exportedMusicIsSelfContained() {
        let tune = MusicTune(play: "C D E")
        let alone = AnsiMusic.scan(AnsiMusic.escape(tune.selfContainedPlay)).sequences[0].notes
        let stream = AnsiMusic.escape("T200 O2 L8 MB MS C") + bytes("art") + AnsiMusic.escape(tune.selfContainedPlay)
        let after = AnsiMusic.scan(stream).sequences[1].notes
        #expect(after == alone)
        #expect(alone.map(\.semitone) == [48, 50, 52])
        #expect(tune.selfContainedPlay == "T120 L4 MN MF O4 C D E")
        // Leading commands become the reset itself, and it still round trips.
        let fast = MusicTune(play: "T90 MS O2 L8 C D")
        #expect(fast.selfContainedPlay == "T90 L8 MS MF O2 C D")
        #expect(MusicTune(play: fast.selfContainedPlay) == fast)
        #expect(MusicTune().selfContainedPlay == "T120 L4 MN MF")
    }

    @Test func skippedMusicClearsPendingWrapLikeOtherSequences() {
        let stream = bytes(String(repeating: "x", count: 80)) + [esc] + bytes("[MC") + [0x0E] + bytes("Z")
        var terminal = AnsiTerminal(ArtFile(data: Data(stream), fileExtension: "ans"))
        terminal.runToEnd()
        let screen = terminal.screen()
        #expect(screen.rows.count == 1)
        #expect(screen.rows[0][79].code == UInt8(ascii: "Z"))
    }

    @Test func ctsamParsedTheSameWayEverywhere() {
        for ctsam in ["[= 2M", "[=\u{01}2M", "[=>2M", "[=2;5M", "[=M", "[=2M"] {
            let stream = [esc] + bytes("[=0M") + [esc] + bytes(ctsam) + [esc] + bytes("[MCDE") + [0x0E] + bytes("XY")
            let scan = AnsiMusic.scan(stream, mode: .all)
            var terminal = AnsiTerminal(ArtFile(data: Data(stream), fileExtension: "ans"))
            terminal.runToEnd()
            let first = terminal.screen().rows.first.map { $0.prefix(2).map(\.code) } ?? []
            let skipped = first == bytes("XY")
            #expect(skipped == (scan.sequences.count == 1), "\(ctsam.debugDescription)")
        }
        // The space form selects mode 2 in both.
        let spaced = [esc] + bytes("[=0M") + [esc] + bytes("[= 2M") + [esc] + bytes("[MC") + [0x0E]
        #expect(AnsiMusic.scan(spaced).sequences.count == 1)
    }

    @Test func clickPositionNeverLandsInsideTheNoteBefore() {
        let tune = MusicTune(play: "C32")
        #expect(tune.snappedPosition(0.05, grid: 1.0 / 16) == 1.0 / 32)
        let rest = MusicTune(play: "C32 P4 D")
        #expect(rest.snappedPosition(0.05, grid: 1.0 / 16) == 1.0 / 32)
        #expect(rest.snappedPosition(0.2, grid: 1.0 / 16) == 0.1875)
        var edit = MusicTune(play: "C32")
        edit.addNote(semitone: 50, at: tune.snappedPosition(0.05, grid: 1.0 / 16), length: 16)
        #expect(edit.play == "C32 D16")
    }

    @Test func libraryDecodesLeniently() {
        let documented = MusicLibrary.decode(Data(#"{"version":1,"snippets":[{"name":"Fanfare","play":"C E G"}]}"#.utf8))
        #expect(documented.snippets.map(\.name) == ["Fanfare"])
        let noVersion = MusicLibrary.decode(Data(#"{"snippets":[{"name":"A","play":"C"}]}"#.utf8))
        #expect(noVersion.snippets.count == 1)
        let id = UUID()
        let json = #"{"version":1,"snippets":[{"id":"ID","name":"Kept","play":"C"},{"name":"No id","play":"D"},{"bad":true},5]}"#
            .replacingOccurrences(of: "ID", with: id.uuidString)
        let mixed = MusicLibrary.decode(Data(json.utf8))
        #expect(mixed.snippets.map(\.name) == ["Kept", "No id"])
        #expect(mixed.snippets.first?.id == id)
    }

    @Test func finishReturnsPendingBytes() {
        var filter = MusicStreamFilter()
        let out = filter.feed(bytes("A") + [esc] + bytes("[2"))
        #expect(out.visual == bytes("A"))
        let end = filter.finish()
        #expect(end.visual == [esc] + bytes("[2"))
        #expect(end.finished.isEmpty)
    }

    @Test func embedLeavesUnknownSauceSizeAlone() {
        let art = bytes("hello\r\n")
        let sauce = Sauce(title: "T", author: "", group: "", date: nil, dataType: 1, fileType: 1,
                          tInfo: [80, 1, 0, 0], flags: 0, fontName: "", comments: [])
        let out = AnsiMusic.embed(bytes("#"), into: art + sauce.encoded(fileSize: 0), at: .end)
        let start = out.count - Sauce.recordLength
        #expect(Array(out[(start + 90)..<(start + 94)]) == [0, 0, 0, 0])
    }

    @Test func deleteTrimsRestsBeforeTrailingCommands() {
        var tune = MusicTune(play: "C D T200")
        tune.delete(index: tune.placed[1].index)
        #expect(tune.play == "C")
    }
}
