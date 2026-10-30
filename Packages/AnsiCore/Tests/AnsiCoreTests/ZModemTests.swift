import Foundation
import Testing
@testable import AnsiCore

private func zTransfer(_ files: [OutgoingFile], sink: TransferSink, send: TransferOptions = TransferOptions(),
                       receive: TransferOptions = TransferOptions(), aToB: LineFaults? = nil, bToA: LineFaults? = nil)
    -> (ZModemSender, ZModemReceiver, [TransferEvent], [TransferEvent]) {
    let clock = ManualTransferClock()
    let sender = ZModemSender(files: files, clock: clock, options: send)
    let receiver = ZModemReceiver(sink: sink, clock: clock, options: receive)
    var f1 = aToB, f2 = bToA
    runLink(sender, receiver, clock: clock, aToB: &f1, bToA: &f2)
    return (sender, receiver, sender.takeEvents(), receiver.takeEvents())
}

private func optionVariants() -> [(String, TransferOptions, TransferOptions)] {
    var escctl = TransferOptions(); escctl.zmodemEscapeControl = true
    var crc16 = TransferOptions(); crc16.zmodemUseCRC32 = false
    var big = TransferOptions(); big.zmodemBlockSize = 8192
    var telnet = TransferOptions(); telnet.zmodemEscapeTelnet = true
    var window = TransferOptions(); window.zmodemReceiveWindow = 4096
    var rxEscctl = TransferOptions(); rxEscctl.zmodemEscapeControl = true
    return [("default", TransferOptions(), TransferOptions()), ("sender escctl", escctl, TransferOptions()),
            ("receiver escctl", TransferOptions(), rxEscctl), ("crc16", crc16, TransferOptions()), ("8k", big, TransferOptions()),
            ("telnet escapes", telnet, TransferOptions()), ("4k window", TransferOptions(), window)]
}

@Suite struct ZModemTransferTests {
    @Test func everySizeAndOptionArrivesIntact() {
        for (label, send, receive) in optionVariants() {
            for size in TestData.sizes {
                let data = TestData.random(size, seed: 17)
                let sink = MemoryTransferSink()
                let (sender, receiver, sendEvents, receiveEvents) = zTransfer([OutgoingFile(name: "z.bin", data: data)], sink: sink, send: send, receive: receive)
                #expect(sender.status == .completed, "\(label) \(size) sender \(sender.status)")
                #expect(receiver.status == .completed, "\(label) \(size) receiver \(receiver.status)")
                #expect(sink.files.first?.data == data, "\(label) \(size)")
                #expect(completedFiles(receiveEvents).first?.sha256 == TransferHash.sha256Hex(data))
                #expect(completedFiles(sendEvents).first?.sha256 == TransferHash.sha256Hex(data))
            }
        }
    }

    @Test func everyByteValueAndOneMebibyte() {
        for (label, send, receive) in optionVariants() {
            for data in [TestData.everyByte, TestData.random(1 << 20, seed: 23)] {
                let sink = MemoryTransferSink()
                let (sender, receiver, _, _) = zTransfer([OutgoingFile(name: "big", data: data)], sink: sink, send: send, receive: receive)
                #expect(sender.status == .completed && receiver.status == .completed, "\(label) \(data.count)")
                #expect(sink.files.first.map { TransferHash.sha256Hex($0.data) } == TransferHash.sha256Hex(data), "\(label) \(data.count)")
            }
        }
    }

    @Test func batchWithEmptyFileNamesAndDates() {
        let date = Date(timeIntervalSince1970: 1_234_567_890)
        let files = [OutgoingFile(name: "A.TXT", data: Array("hello".utf8), modified: date, mode: 0o100644),
                     OutgoingFile(name: "empty", data: []), OutgoingFile(name: "c.bin", data: TestData.random(70_000))]
        let sink = MemoryTransferSink()
        let (sender, receiver, _, _) = zTransfer(files, sink: sink)
        #expect(sender.status == .completed && receiver.status == .completed)
        #expect(sink.files.map(\.name) == ["A.TXT", "empty", "c.bin"])
        #expect(sink.files.map(\.data.count) == [5, 0, 70_000])
        #expect(sink.offers.first?.modified == date)
        #expect(sink.offers.first?.mode == 0o100644)
        #expect(sink.offers.map(\.size) == [5, 0, 70_000])
    }

    @Test func refusedFileIsSkippedWithZSKIP() {
        let sink = MemoryTransferSink()
        sink.refuse = ["two.bin"]
        let files = [OutgoingFile(name: "one.bin", data: [1]), OutgoingFile(name: "two.bin", data: TestData.random(5000)),
                     OutgoingFile(name: "three.bin", data: [3])]
        let (sender, receiver, sendEvents, _) = zTransfer(files, sink: sink)
        #expect(sender.status == .completed && receiver.status == .completed)
        #expect(sink.files.map(\.name) == ["one.bin", "three.bin"])
        #expect(sendEvents.contains { if case .fileSkipped(let name, _) = $0 { return name == "two.bin" } else { return false } })
        #expect(sink.offers.map(\.name) == ["one.bin", "two.bin", "three.bin"], "each ZFILE sent once on a clean line")
        #expect(!sendEvents.contains { if case .recovered = $0 { return true } else { return false } }, "no retries on a clean line")
    }

    @Test func resumesFromThePartialTheReceiverHas() {
        let data = TestData.random(400_000, seed: 31)
        for senderAsks in [true, false] {
            let sink = MemoryTransferSink()
            sink.partials["r.bin"] = Array(data.prefix(300_000))
            var send = TransferOptions(); send.resume = senderAsks
            var receive = TransferOptions(); receive.resume = !senderAsks
            let (sender, receiver, sendEvents, receiveEvents) = zTransfer([OutgoingFile(name: "r.bin", data: data)], sink: sink, send: send, receive: receive)
            #expect(sender.status == .completed && receiver.status == .completed)
            #expect(sink.files.first?.data == data)
            #expect(completedFiles(receiveEvents).first?.resumedFrom == 300_000)
            #expect(receiver.progress.sessionBytes == 100_000, "only the missing bytes crossed the line")
            #expect(sendEvents.contains(.fileStarted(name: "r.bin", size: 400_000, offset: 0)))
            #expect(receiveEvents.contains(.fileStarted(name: "r.bin", size: 400_000, offset: 300_000)))
        }
    }

    @Test func recoversFromLineErrorsBothWays() {
        let data = TestData.random(200_000, seed: 41)
        var options = TransferOptions()
        options.maxRetries = 20
        for seed: UInt64 in [3, 8, 13, 21, 34] {
            let sink = MemoryTransferSink()
            let toReceiver = LineFaults(seed: seed, drop: 0.00005, duplicate: 0.00003, corrupt: 0.00005, noise: 0.00003, activeBytes: 250_000)
            let toSender = LineFaults(seed: seed + 100, drop: 0.01, duplicate: 0.01, corrupt: 0.01, noise: 0.01, activeBytes: 400)
            let (sender, receiver, _, receiveEvents) = zTransfer([OutgoingFile(name: "n.bin", data: data)], sink: sink, send: options,
                                                                 receive: options, aToB: toReceiver, bToA: toSender)
            #expect(sender.status == .completed, "seed \(seed) sender \(sender.status)")
            #expect(receiver.status == .completed, "seed \(seed) receiver \(receiver.status)")
            #expect(sink.files.first?.data == data, "seed \(seed)")
            #expect(receiveEvents.contains { if case .recovered = $0 { return true } else { return false } }, "seed \(seed)")
        }
    }

    @Test func honoursTheReceiverWindow() {
        let clock = ManualTransferClock()
        var receive = TransferOptions(); receive.zmodemReceiveWindow = 4096
        let sender = ZModemSender(files: [OutgoingFile(name: "w", data: TestData.random(50_000))], clock: clock)
        let receiver = ZModemReceiver(sink: MemoryTransferSink(), clock: clock, options: receive)
        let spy = ZReader()
        var unacked = 0, most = 0, waits = 0
        sender.start()
        receiver.start()
        for _ in 0..<100_000 where !(sender.status.isFinished && receiver.status.isFinished) {
            let x = sender.takeOutput(max: 1000)
            spy.feed(x) { token in
                if case .data(let d, let end) = token {
                    unacked += d.count
                    most = max(most, unacked)
                    if end == ZEnd.crcW { unacked = 0; waits += 1 }
                }
                if case .header(let h, _) = token, h.type == ZType.data { unacked = 0 }
            }
            receiver.receive(x)
            sender.receive(receiver.takeOutput())
            clock.advance(0.001)
        }
        #expect(sender.status == .completed && receiver.status == .completed)
        #expect(most <= 4096)
        #expect(waits >= 50_000 / 4096)
    }

    @Test func cancelBothWaysCleansUp() {
        for receiverCancels in [true, false] {
            let clock = ManualTransferClock()
            let sink = MemoryTransferSink()
            let sender = ZModemSender(files: [OutgoingFile(name: "c.bin", data: TestData.random(300_000))], clock: clock)
            let receiver = ZModemReceiver(sink: sink, clock: clock)
            sender.start()
            receiver.start()
            for _ in 0..<40 {
                receiver.receive(sender.takeOutput(max: 4096))
                sender.receive(receiver.takeOutput())
            }
            if receiverCancels { receiver.cancel() } else { sender.cancel() }
            receiver.receive(sender.takeOutput())
            sender.receive(receiver.takeOutput())
            let (canceller, other) = receiverCancels ? (receiver as TransferEngine, sender as TransferEngine) : (sender, receiver)
            #expect(canceller.status == .cancelled)
            guard case .failed(let reason) = other.status else { Issue.record("\(other.status)"); continue }
            #expect(reason.contains("cancelled by the"))
            #expect(sink.files.isEmpty)
            #expect(sink.aborted == 1)
        }
    }

    @Test func interruptedDownloadResumesOnDisk() throws {
        let dir = makeTransferTempDir()
        let data = TestData.random(600_000, seed: 51)
        var keep = DownloadsDirectorySink.Options()
        keep.keepPartialForResume = true
        // First attempt: the receiver gives up part way.
        do {
            let clock = ManualTransferClock()
            let sender = ZModemSender(files: [OutgoingFile(name: "big.zip", data: data)], clock: clock)
            let receiver = ZModemReceiver(sink: DownloadsDirectorySink(directory: dir, options: keep), clock: clock)
            sender.start()
            receiver.start()
            while receiver.progress.fileBytes < 250_000 {
                receiver.receive(sender.takeOutput(max: 4096))
                sender.receive(receiver.takeOutput())
            }
            receiver.cancel()
            sender.receive(receiver.takeOutput())
        }
        let part = try Data(contentsOf: dir.appendingPathComponent("big.zip.part"))
        #expect(part.count >= 250_000 && part.count < data.count)
        #expect([UInt8](part) == Array(data.prefix(part.count)))
        // Second attempt with resume: only the rest is sent.
        let sink = DownloadsDirectorySink(directory: dir, options: keep)
        var resume = TransferOptions(); resume.resume = true
        let (sender, receiver, _, events) = zTransfer([OutgoingFile(name: "big.zip", data: data)], sink: sink, send: resume)
        #expect(sender.status == .completed && receiver.status == .completed)
        #expect(completedFiles(events).first?.resumedFrom == part.count)
        #expect(completedFiles(events).first?.sha256 == TransferHash.sha256Hex(data))
        #expect(directoryNames(dir) == ["big.zip"])
    }

    @Test func overTelnetKeepsEveryByte() {
        #expect(runOverTelnet(kind: .zmodem, data: TestData.everyByte + TestData.random(20_000)) == (true, true))
    }
}

@Suite struct ZModemProtocolTests {
    @Test func receiverAnswersZRQINITAndRefusesCommands() {
        let clock = ManualTransferClock()
        let receiver = ZModemReceiver(sink: MemoryTransferSink(), clock: clock)
        receiver.start()
        let first = receiver.takeOutput()
        #expect(first.starts(with: Array("**\u{18}B01".utf8)))
        receiver.receive(ZFrame.hexHeader(ZHeader(type: ZType.rqinit)))
        #expect(receiver.takeOutput().starts(with: Array("**\u{18}B01".utf8)))
        var escaper = ZEscaper()
        receiver.receive(ZFrame.binaryHeader(ZHeader(type: ZType.command), crc32: true, escaper: escaper)
                         + ZFrame.subpacket(Array("rm -rf ~\0".utf8), end: ZEnd.crcW, crc32: true, escaper: &escaper))
        let reply = receiver.takeOutput()
        #expect(reply.starts(with: Array("**\u{18}B0f01000000".utf8)), "ZCOMPL with status 1: refused, never run")
        #expect(receiver.status == .running)
        #expect(receiver.takeEvents().contains { if case .log(let text) = $0 { return text.contains("refused") } else { return false } })
    }

    @Test func senderGivesUpWithoutAReceiver() {
        let clock = ManualTransferClock()
        let sender = ZModemSender(files: [OutgoingFile(name: "x", data: [1])], clock: clock)
        sender.start()
        #expect(sender.takeOutput().starts(with: Array("rz\r**\u{18}B00".utf8)))
        for _ in 0..<12 {
            clock.advance(11)
            sender.tick()
        }
        guard case .failed = sender.status else { Issue.record("\(sender.status)"); return }
    }

    @Test func fileInfoParsing() {
        let info = ZFileInfo.parse(Array("dir/a.zip".utf8) + [0] + Array("1234 13207007200 100644 0 2 5000".utf8) + [0])
        #expect(info?.name == "dir/a.zip")
        #expect(info?.size == 1234)
        #expect(info?.modified == Date(timeIntervalSince1970: 0o13207007200))
        #expect(info?.mode == 0o100644)
        #expect(ZFileInfo.parse(Array("n".utf8) + [0, 0])?.size == nil)
        #expect(ZFileInfo.parse([0]) == nil)
    }
}
