import Foundation
import Testing
@testable import AnsiCore

/// Findings of the final review of the transfers branch, each reproduced first.
@Suite struct TransferReviewFixTests {
    // Critical 1: a huge "!" (size in K) attribute overflowed Int and trapped.
    @Test func hugeOrNegativeKermitSizesDoNotTrap() {
        let huge = KermitAttributes.parse([UInt8(ascii: "!"), tochar(17)] + Array("99999999999999999".utf8))
        #expect(huge.size == nil || huge.size! > 0)
        let negative = KermitAttributes.parse([UInt8(ascii: "1"), tochar(3)] + Array("-50".utf8))
        #expect(negative.size == nil)
        #expect(MemoryTransferSink().open(FileOffer(name: "n", size: -1)) != .accept(offset: 0))
    }

    // Critical 2: an extension of one character with many combining marks emptied the stem and trapped.
    @Test func combiningMarksInTheExtensionDoNotTrap() {
        let name = "aaaaaaaaaa.e" + String(repeating: "\u{0301}", count: 300)
        let clean = TransferFileName.sanitize(name)
        #expect(clean.utf8.count <= TransferFileName.maxLength)
        #expect(!clean.isEmpty)
        #expect(TransferFileName.sanitize(String(repeating: "\u{0301}", count: 500)).utf8.count <= TransferFileName.maxLength)
    }

    // Important 3: a sender's resume request appended to any existing .part, like a browser's.
    @Test func onlyOurOwnPartialsAreResumed() throws {
        let dir = makeTransferTempDir()
        try Data("USER'S OWN FILE".utf8).write(to: dir.appendingPathComponent("report.part"))
        let sink = DownloadsDirectorySink(directory: dir)
        #expect(sink.open(FileOffer(name: "report", size: 1000, resumeRequested: true)) == .accept(offset: 0))
        try sink.write(Array("HOSTILE".utf8))
        _ = try sink.finish()
        #expect(try String(contentsOf: dir.appendingPathComponent("report.part"), encoding: .utf8) == "USER'S OWN FILE")
        #expect(try String(contentsOf: dir.appendingPathComponent("report"), encoding: .utf8) == "HOSTILE")
    }

    // Important 4: duplicates and noise kept a transfer alive forever.
    @Test func duplicateFloodsAndNoiseEndTheTransfer() {
        let clock = ManualTransferClock()
        let receiver = XModemReceiver(kind: .xmodemCRC, sink: MemoryTransferSink(), clock: clock)
        receiver.start()
        let one = xmodemPacket(number: 1, data: [1], length: 128, pad: 0x1A, crc: true)
        receiver.receive(one)
        for _ in 0..<1000 where receiver.status == .running {
            receiver.receive(one)
            clock.advance(5)
            receiver.tick()
        }
        guard case .failed = receiver.status else { Issue.record("duplicates: \(receiver.status)"); return }

        let noisy = XModemReceiver(kind: .xmodemCRC, sink: MemoryTransferSink(), clock: clock)
        noisy.start()
        noisy.receive(one)
        for _ in 0..<100_000 where noisy.status == .running {
            noisy.receive([0x55])
            clock.advance(0.5)
            noisy.tick()
        }
        guard case .failed = noisy.status else { Issue.record("noise: \(noisy.status)"); return }
    }

    @Test func kermitDuplicateFloodEndsTheTransfer() {
        let clock = ManualTransferClock()
        let receiver = KermitReceiver(sink: MemoryTransferSink(), clock: clock)
        receiver.start()
        receiver.receive(KermitCodec.encode(KermitPacket(type: KType.send, seq: 0, data: KermitParameters.ours(TransferOptions()).encoded()), checkType: 1))
        let file = KermitCodec.encode(KermitPacket(type: KType.file, seq: 1, data: Array("f".utf8)), checkType: 3)
        receiver.receive(file)
        for _ in 0..<1000 where receiver.status == .running {
            receiver.receive(file)
            clock.advance(5)
            receiver.tick()
        }
        guard case .failed = receiver.status else { Issue.record("\(receiver.status)"); return }
    }

    @Test func sessionLogIsBounded() {
        let clock = ManualTransferClock()
        var options = TransferOptions()
        options.maxRetries = 1_000_000
        let session = FileTransferSession(receivingInto: MemoryTransferSink(), kind: .xmodemCRC, options: options, clock: clock)
        session.start()
        let one = xmodemPacket(number: 1, data: [1], length: 128, pad: 0x1A, crc: true)
        for _ in 0..<(FileTransferSession.maxLogEntries + 500) { session.feed(one) }
        #expect(session.outcome == nil, "still running, so the log really filled up")
        #expect(session.log.count <= FileTransferSession.maxLogEntries)
        #expect(session.log.count > 1000)
    }

    // Important 5: senders hashed the whole file before sending (blocking the caller).
    @Test func sendersHashAsTheyGoNotUpFront() {
        let clock = ManualTransferClock()
        let file = OutgoingFile(name: "h", data: TestData.random(3 << 20))
        let sender = ZModemSender(files: [file], clock: clock)
        sender.start()
        sender.receive(ZFrame.hexHeader(ZHeader(type: ZType.rinit, flags: 0x23)))
        _ = sender.takeOutput(max: 4096)
        #expect(file.hashedBytes < file.size, "no whole file hash before data flows")
        #expect(file.hashedBytes <= OutgoingFile.hashStep * 2)
    }

    // Important 6: the channel copied the terminal's telnet session, leaving the original stale.
    @Test func telnetHelpersWorkOnTheTerminalsOwnSession() {
        var terminalSession = TelnetSession(columns: 80, rows: 25)
        let ask = TelnetTransferChannel.requestBinary(&terminalSession)
        #expect(ask == [255, 251, 0, 255, 253, 0])
        let decoded = TelnetTransferChannel.decode([255, 253, 0, 255, 251, 0, 65], session: &terminalSession)
        #expect(decoded.data == [65])
        #expect(TelnetTransferChannel.isByteClean(terminalSession))
        #expect(TelnetTransferChannel.encode([255, 13], session: terminalSession) == [255, 255, 13])
    }

    // Important 7: short files were reported complete; a lone EOT made an empty XMODEM file.
    @Test func shortFilesAreFlaggedAndALoneEOTIsIgnored() {
        let clock = ManualTransferClock()
        let sink = MemoryTransferSink()
        let receiver = XModemReceiver(kind: .xmodemCRC, sink: sink, clock: clock)
        receiver.start()
        receiver.receive([0x04])
        #expect(receiver.status == .running)
        #expect(sink.files.isEmpty)

        // A YMODEM sender that announces 1000 bytes and sends 128.
        let ysink = MemoryTransferSink()
        let y = XModemReceiver(kind: .ymodem, sink: ysink, clock: clock)
        y.start()
        y.receive(xmodemPacket(number: 0, data: YModemHeader.encode(name: "s", size: 1000, modified: nil, mode: nil, filesLeft: 1, bytesLeft: 1000), length: 128, pad: 0, crc: true))
        y.receive(xmodemPacket(number: 1, data: Array(repeating: 7, count: 128), length: 128, pad: 0x1A, crc: true))
        y.receive([0x04])
        y.receive([0x04])
        let done = completedFiles(y.takeEvents())
        #expect(done.count == 1)
        #expect(done.first?.isShort == true)
        #expect(done.first?.announcedSize == 1000)
    }

    // Minor: ZMODEM positions are 32 bits; files of 4 GiB and more are refused, not wrapped.
    @Test func zmodemRefusesFilesThatOverflowPositions() {
        #expect(ZModemSender.maxFileSize == Int(UInt32.max))
    }

    // Minor: a Kermit F (or B) while a file is open leaked the half written file.
    @Test func kermitAbortsAnUnfinishedFileOnANewOne() {
        let clock = ManualTransferClock()
        let sink = MemoryTransferSink()
        let receiver = KermitReceiver(sink: sink, clock: clock)
        receiver.start()
        receiver.receive(KermitCodec.encode(KermitPacket(type: KType.send, seq: 0, data: KermitParameters.ours(TransferOptions()).encoded()), checkType: 1))
        receiver.receive(KermitCodec.encode(KermitPacket(type: KType.file, seq: 1, data: Array("a".utf8)), checkType: 3))
        receiver.receive(KermitCodec.encode(KermitPacket(type: KType.data, seq: 2, data: Array("xyz".utf8)), checkType: 3))
        receiver.receive(KermitCodec.encode(KermitPacket(type: KType.file, seq: 3, data: Array("b".utf8)), checkType: 3))
        #expect(sink.aborted == 1)
        receiver.receive(KermitCodec.encode(KermitPacket(type: KType.data, seq: 4, data: Array("q".utf8)), checkType: 3))
        receiver.receive(KermitCodec.encode(KermitPacket(type: KType.eot, seq: 5, data: []), checkType: 3))
        #expect(sink.aborted == 2)
    }
}
