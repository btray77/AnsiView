import Foundation
import Testing
@testable import AnsiCore

@Suite struct TransferStartDetectorTests {
    // What lrzsz sz sends first (captured from our own ZRQINIT encoder, identical to lrzsz's).
    let zrqinit = Array("rz\r".utf8) + ZFrame.hexHeader(ZHeader(type: ZType.rqinit))
    let zrinit = ZFrame.hexHeader(ZHeader(type: ZType.rinit, flags: 0x23))
    // C-Kermit 9.0.302 `kermit -s` and `kermit -r` openings, captured on a pty.
    let kermitS = Array("\u{01}9 S~/ @-#Y3~^>J)0___N\"U1AH\r".utf8)
    let kermitNak = Array("\u{01}# N3\r".utf8)

    @Test func detectsEachStart() {
        var detector = TransferStartDetector()
        let text = Array("Welcome to the BBS\r\n".utf8)
        #expect(detector.scan(text) == nil)
        let match = detector.scan(Array("Sending...\r\n".utf8) + zrqinit)
        #expect(match?.kind == .zmodemReceive)
        #expect(match?.terminalBytes == Array("Sending...\r\nrz\r".utf8))
        #expect(match?.transferBytes == Array(zrqinit.dropFirst(3)))
        #expect(TransferStartDetector().scanned(zrinit)?.kind == .zmodemSend)
        #expect(TransferStartDetector().scanned(kermitS)?.kind == .kermitReceive)
        #expect(TransferStartDetector().scanned(kermitS)?.transferBytes == kermitS)
        #expect(TransferStartDetector().scanned(kermitNak)?.kind == .kermitSend)
    }

    @Test func detectsAcrossEverySplit() {
        for stream in [Array("abc".utf8) + zrqinit, Array("xy".utf8) + kermitS] {
            let whole = TransferStartDetector().scanned(stream)!
            for split in 1..<stream.count {
                var detector = TransferStartDetector()
                var terminal: [UInt8] = []
                var found: TransferStartDetector.Match?
                var later: [UInt8] = []
                if let m = detector.scan(Array(stream[..<split])) {
                    found = m
                    later = Array(stream[split...])  // the next feed goes straight to the session
                } else {
                    terminal += stream[..<split]
                    found = detector.scan(Array(stream[split...]))
                }
                #expect(found?.kind == whole.kind, "split \(split)")
                // The session gets the whole start sequence and everything after it.
                let delivered = (found?.transferBytes ?? []) + later
                #expect(delivered == whole.transferBytes, "split \(split)")
                #expect(terminal.count + (found?.terminalBytes.count ?? 0) + delivered.count >= stream.count)
            }
        }
    }

    /// The terminal flow: BBS text, then the remote starts a sender; the detector hands the
    /// stream to a new receive session, which completes the transfer.
    @Test(arguments: [TransferProtocolKind.zmodem, .kermit])
    func detectedStartHandsOffToASession(kind: TransferProtocolKind) {
        let clock = ManualTransferClock()
        let data = TestData.random(30_000, seed: 3)
        let remote = TransferEngineFactory.sender(kind: kind, files: [OutgoingFile(name: "auto.bin", data: data)], clock: clock)
        remote.start()
        var detector = TransferStartDetector()
        var shown: [UInt8] = []
        var session: FileTransferSession?
        let sink = MemoryTransferSink()
        var stream = Array("Downloading auto.bin, start your transfer...\r\n".utf8)
        for _ in 0..<200_000 where session?.outcome == nil {
            stream += remote.takeOutput(max: 700)
            if let session {
                session.feed(stream)
                remote.receive(session.takeOutput())
            } else if let match = detector.scan(stream) {
                shown += match.terminalBytes
                #expect(match.kind.kind == kind && match.kind.direction == .receive)
                let started = FileTransferSession(receivingInto: sink, kind: kind, clock: clock)
                started.start()
                started.feed(match.transferBytes)
                remote.receive(started.takeOutput())
                session = started
            } else {
                shown += stream
            }
            stream = []
            clock.advance(0.01)
            remote.tick()
            session?.tick()
        }
        guard case .completed = session?.outcome else { Issue.record("\(String(describing: session?.outcome))"); return }
        #expect(sink.files.first?.data == data)
        #expect(String(decoding: shown, as: UTF8.self).hasPrefix("Downloading auto.bin"))
    }

    @Test func ordinaryTerminalTrafficDoesNotTrigger() {
        var detector = TransferStartDetector()
        var rng = SeededRandom(5)
        // ANSI art style output: escape sequences, CP437 blocks, asterisks, the letter B, digits.
        for _ in 0..<2000 {
            let line = Array("\u{1B}[1;33m** B00 **\u{1B}[0m \u{01}A-S \u{01}".utf8) + rng.bytes(64).map { $0 | 0x80 } + [13, 10]
            #expect(detector.scan(line) == nil)
        }
    }
}
