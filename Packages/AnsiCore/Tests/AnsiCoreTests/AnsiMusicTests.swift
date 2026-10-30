import Foundation
import Testing
@testable import AnsiCore

@Suite struct AnsiMusicTests {
    private let esc: UInt8 = 0x1B
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    private func music(_ introducer: String, _ body: String) -> [UInt8] { [esc] + bytes("[" + introducer + body) + [0x0E] }

    private func screenText(_ stream: [UInt8], mode: MusicMode = .all) -> String {
        var terminal = AnsiTerminal(ArtFile(data: Data(stream), fileExtension: "ans"), musicMode: mode)
        terminal.runToEnd()
        return terminal.screen().rows.map { row in
            String(row.map { Character(UnicodeScalar($0.code)) }).replacingOccurrences(of: " ", with: "", options: [])
        }.joined(separator: "|")
    }

    @Test func findsAllIntroducersWithOffsets() {
        let a = bytes("Hi")
        let m = music("M", "FT120C")
        let n = music("N", "C")
        let p = music("|", "D")
        let stream = a + m + bytes("x") + n + p + bytes("!")
        let scan = AnsiMusic.scan(stream)
        #expect(scan.sequences.map(\.offset) == [2, 2 + m.count + 1, 2 + m.count + 1 + n.count])
        #expect(scan.sequences.map(\.length) == [m.count, n.count, p.count])
        #expect(scan.sequences.map(\.introducer) == [.m, .n, .pipe])
        #expect(scan.sequences.allSatisfy { $0.isTerminated })
        #expect(scan.visual == bytes("Hix!"))
        #expect(scan.sequences[0].body == "FT120C")
        #expect(scan.sequences[0].notes.map(\.semitone) == [48])
        #expect(scan.sequences[1].notes.map(\.semitone) == [48])
        #expect(scan.sequences[2].notes.map(\.semitone) == [50])
    }

    @Test func modeGatesIntroducers() {
        let stream = music("M", "C") + music("N", "D") + music("|", "E")
        #expect(AnsiMusic.scan(stream, mode: .pipe).sequences.map(\.introducer) == [.pipe])
        #expect(AnsiMusic.scan(stream, mode: .bananaCom).sequences.map(\.introducer) == [.n, .pipe])
        #expect(AnsiMusic.scan(stream, mode: .off).sequences.isEmpty)
        #expect(AnsiMusic.scan(stream, mode: .off).visual == stream)
    }

    @Test func deleteLineWithParameterIsNotMusic() {
        let stream = [esc] + bytes("[2MCDE") + [0x0E]
        #expect(AnsiMusic.scan(stream).sequences.isEmpty)
        let semicolon = [esc] + bytes("[;MCDE") + [0x0E]
        #expect(AnsiMusic.scan(semicolon).sequences.isEmpty)
    }

    @Test func ctsamSwitchesMode() {
        let stream = [esc] + bytes("[=2M") + music("M", "C")
        let scan = AnsiMusic.scan(stream, mode: .pipe)
        #expect(scan.sequences.count == 1)
        #expect(scan.visual == [esc] + bytes("[=2M"))
        let back = [esc] + bytes("[=0M") + music("N", "C")
        #expect(AnsiMusic.scan(back, mode: .all).sequences.isEmpty)
        // Off stays off.
        #expect(AnsiMusic.scan(stream, mode: .off).sequences.isEmpty)
    }

    @Test func firstCharacterRule() {
        let mb = AnsiMusic.scan(music("M", "B C")).sequences[0]
        #expect(mb.notes.map(\.semitone) == [48])
        #expect(mb.notes[0].background)
        #expect(!mb.blocksDisplay)
        #expect(AnsiMusic.scan(music("N", "B")).sequences[0].notes.map(\.semitone) == [59])
        #expect(AnsiMusic.scan(music("M", "N37")).sequences[0].notes.map(\.semitone) == [36])
        let mn = AnsiMusic.scan(music("M", "N C")).sequences[0]
        #expect(mn.notes.map(\.semitone) == [48])
        let ml = AnsiMusic.scan(music("|", "L C")).sequences[0]
        #expect(ml.notes[0].sounding == ml.notes[0].duration)
        // Lowercase too.
        #expect(AnsiMusic.scan(music("M", "s c")).sequences[0].notes[0].sounding == 0.375)
    }

    @Test func invalidByteAborts() {
        let stream = [esc] + bytes("[MC D\r\nHi")
        let scan = AnsiMusic.scan(stream)
        #expect(scan.sequences.count == 1)
        #expect(!scan.sequences[0].isTerminated)
        #expect(scan.sequences[0].notes.isEmpty)
        #expect(scan.sequences[0].length == 6)
        #expect(scan.visual == bytes("\r\nHi"))
        // An ESC inside a body aborts it and starts a new sequence.
        let restart = [esc] + bytes("[MC") + music("N", "D")
        let second = AnsiMusic.scan(restart)
        #expect(second.sequences.map(\.isTerminated) == [false, true])
        #expect(second.sequences[1].offset == 4)
    }

    @Test func unterminatedAtEnd() {
        let scan = AnsiMusic.scan([esc] + bytes("[MCDE"))
        #expect(scan.sequences.count == 1)
        #expect(!scan.sequences[0].isTerminated)
        #expect(scan.visual.isEmpty)
    }

    @Test func statePersistsBetweenSequences() {
        let scan = AnsiMusic.scan(music("M", "T240 O2 L8 MS") + music("M", " C"))
        let note = scan.sequences[1].notes[0]
        #expect(note.semitone == 24)
        #expect(abs(note.duration - 0.125) < 1e-9)
        #expect(scan.sequences[1].startState.tempo == 240)
        // An aborted sequence does not change the state.
        let aborted = AnsiMusic.scan([esc] + bytes("[MT32\r") + music("M", " C"))
        #expect(aborted.sequences[1].notes[0].duration == 0.5)
    }

    @Test func blocksDisplayAndDuration() {
        let seq = AnsiMusic.scan(music("M", "F C D")).sequences[0]
        #expect(seq.blocksDisplay)
        #expect(seq.duration == 1.0)
        #expect(!AnsiMusic.scan(music("|", "")).sequences[0].blocksDisplay)
    }

    @Test func shiftInAfterMusicIsDropped() {
        let stream = bytes("A") + music("M", "C") + [0x0F] + bytes("B") + [0x0F]
        let scan = AnsiMusic.scan(stream)
        #expect(scan.visual == bytes("AB") + [0x0F])
        #expect(scan.shiftInsDropped == 1)
        #expect(screenText(stream).hasPrefix("AB"))
    }

    @Test func filterMatchesScanAcrossSplits() {
        let stream = bytes("xy") + music("M", "FT120 L8 CDE") + [0x0F] + [esc] + bytes("[1;31mR") + music("|", "MB G")
            + [esc] + bytes("[MC\nZ")
        let whole = AnsiMusic.scan(stream)
        for split in 0...stream.count {
            var filter = MusicStreamFilter(mode: .all)
            var visual: [UInt8] = []
            var sequences: [MusicSequence] = []
            for part in [Array(stream[..<split]), Array(stream[split...])] {
                let out = filter.feed(part)
                visual += out.visual
                sequences += out.finished
            }
            sequences += filter.finish()
            #expect(visual == whole.visual, "split \(split)")
            #expect(sequences == whole.sequences, "split \(split)")
        }
    }

    @Test func terminalSkipsMusic() {
        let stream = bytes("A") + music("M", "FT120C") + bytes("B") + music("N", "C") + bytes("C")
        #expect(screenText(stream) == "ABC")
        // Off: the body prints as before (the sequence is just an unknown CSI).
        #expect(screenText(bytes("A") + music("|", "CD") + bytes("B"), mode: .off).hasPrefix("ACD"))
        // Aborted bodies are removed, the aborting byte is processed.
        #expect(screenText([esc] + bytes("[MC D\r\nHi")) == "|Hi")
    }

    @Test func terminalSkipsMusicAcrossAdvanceCalls() {
        let stream = bytes("A") + music("M", "FT120 L8 CDEFG") + bytes("B")
        let source = ArtFile(data: Data(stream), fileExtension: "ans")
        var terminal = AnsiTerminal(source)
        terminal.advance(byteCount: 3)
        #expect(terminal.position == 1 + music("M", "FT120 L8 CDEFG").count)
        terminal.runToEnd()
        #expect(terminal.screen().rows[0].prefix(2).map(\.code) == [0x41, 0x42])
        // Seeking back keeps the configured mode.
        var off = AnsiTerminal(source, musicMode: .off)
        off.runToEnd()
        off.seek(to: 0)
        off.runToEnd()
        #expect(off.screen().rows[0][1].code == UInt8(ascii: "F"))
    }

    @Test func terminalHonoursCtsam() {
        let stream = [esc] + bytes("[=0M") + bytes("A") + music("M", "CD") + bytes("B")
        // In pipe mode ESC[M is Delete Line (ignored by the file player), so CD prints.
        #expect(screenText(stream).hasPrefix("ACD"))
    }

    @Test func escapeKeepsLeadingNoteLetters() {
        for play in ["B C", "F", "L8 C", "S", "N C", "b", "N37"] {
            let sequence = AnsiMusic.escape(play)
            let scanned = AnsiMusic.scan(sequence).sequences
            #expect(scanned.count == 1)
            let direct = PlayString.parse(play)
            #expect(scanned[0].items == direct.items, "\(play)")
        }
        #expect(AnsiMusic.escape("N37") == [esc] + bytes("[MN37") + [0x0E, 0x0F])
        #expect(AnsiMusic.escape("C", introducer: .pipe, shiftIn: false) == [esc] + bytes("[|C") + [0x0E])
        // Characters a terminal would reject are dropped; line breaks become spaces.
        #expect(AnsiMusic.escape("C\nD;E", shiftIn: false) == [esc] + bytes("[MC DE") + [0x0E])
    }

    @Test func escapeRoundTrip() {
        let play = "T150 O3 L8 C D E F G4 P8 MS A B > C2."
        let scan = AnsiMusic.scan(bytes("art") + AnsiMusic.escape(play, introducer: .n) + bytes("more"))
        #expect(scan.sequences.count == 1)
        #expect(scan.sequences[0].items == PlayString.parse(play).items)
        #expect(scan.visual == bytes("artmore"))
    }

    @Test func embedKeepsSauceAndPatchesSize() {
        let art = bytes("line1\r\nline2\r\n")
        var sauce = Sauce(title: "Tune", author: "Me", group: "", date: nil, dataType: 1, fileType: 1,
                          tInfo: [80, 2, 0, 0], flags: 0, fontName: "IBM VGA", comments: ["first comment"])
        sauce.comments = ["first comment", "second"]
        let file = art + sauce.encoded(fileSize: art.count)
        let sequence = AnsiMusic.escape("C D E")
        let out = AnsiMusic.embed(sequence, into: file, at: .end)
        let (read, contentLength) = Sauce.read(out)
        #expect(read?.title == "Tune")
        #expect(read?.comments == ["first comment", "second"])
        #expect(contentLength == art.count + sequence.count)
        #expect(Array(out.prefix(contentLength)) == art + sequence)
        let start = out.count - Sauce.recordLength
        let size = Int(out[start + 90]) | Int(out[start + 91]) << 8 | Int(out[start + 92]) << 16
        #expect(size == art.count + sequence.count)
        // Everything after the art is unchanged except the size field.
        let oldTail = Array(file[art.count...]), newTail = Array(out[contentLength...])
        #expect(oldTail.count == newTail.count)
        #expect(zip(oldTail, newTail).enumerated().filter { $0.element.0 != $0.element.1 }.allSatisfy {
            (oldTail.count - Sauce.recordLength + 90..<oldTail.count - Sauce.recordLength + 94).contains($0.offset)
        })
    }

    @Test func embedPositions() {
        let art = bytes("a\nb\nc")
        let seq = bytes("#")
        #expect(AnsiMusic.embed(seq, into: art, at: .start) == bytes("#a\nb\nc"))
        #expect(AnsiMusic.embed(seq, into: art, at: .afterLine(1)) == bytes("a\n#b\nc"))
        #expect(AnsiMusic.embed(seq, into: art, at: .afterLine(2)) == bytes("a\nb\n#c"))
        #expect(AnsiMusic.embed(seq, into: art, at: .afterLine(9)) == bytes("a\nb\nc#"))
        // Without SAUCE, the music goes before a DOS end of file marker.
        #expect(AnsiMusic.embed(seq, into: art + [0x1A, 0, 0], at: .end) == art + seq + [0x1A, 0, 0])
    }

    @Test func fuzzStreamsNeverCrash() {
        var generator = SeededGenerator(seed: 42)
        let alphabet: [UInt8] = [0x1B, 0x5B, 0x4D, 0x4E, 0x7C, 0x0E, 0x0F, 0x3D, 0x32, 0x3B, 0x0D, 0x0A, 0x41, 0x43, 0x2E, 0x20, 0x54, 0x4C, 0xFF, 0x00]
        for _ in 0..<500 {
            let count = Int.random(in: 0...400, using: &generator)
            let stream = (0..<count).map { _ in
                Bool.random(using: &generator) ? alphabet.randomElement(using: &generator)! : UInt8.random(in: 0...255, using: &generator)
            }
            let scan = AnsiMusic.scan(stream)
            #expect(scan.visual.count + scan.sequences.map(\.length).reduce(0, +) + scan.shiftInsDropped == stream.count)
            var terminal = AnsiTerminal(ArtFile(data: Data(stream), fileExtension: "ans"))
            terminal.runToEnd()
            #expect(terminal.isFinished)
        }
    }
}
