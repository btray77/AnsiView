import Foundation
import Testing
@testable import AnsiCore

private let xyKinds: [TransferProtocolKind] = [.xmodem, .xmodemCRC, .xmodem1K, .ymodem, .ymodemG]

private func transfer(_ kind: TransferProtocolKind, _ files: [(String, [UInt8])], options: TransferOptions = TransferOptions(),
                      aToB: LineFaults? = nil, bToA: LineFaults? = nil) -> (XModemSender, XModemReceiver, MemoryTransferSink, [TransferEvent], [TransferEvent]) {
    let clock = ManualTransferClock()
    let sink = MemoryTransferSink()
    let sender = XModemSender(kind: kind, files: files.map { OutgoingFile(name: $0.0, data: $0.1) }, clock: clock, options: options)
    let receiver = XModemReceiver(kind: kind, sink: sink, clock: clock, options: options)
    var f1 = aToB, f2 = bToA
    runLink(sender, receiver, clock: clock, aToB: &f1, bToA: &f2)
    return (sender, receiver, sink, sender.takeEvents(), receiver.takeEvents())
}

@Suite struct XModemTransferTests {
    @Test(arguments: xyKinds)
    func everySizeArrivesIntact(kind: TransferProtocolKind) {
        for size in TestData.sizes {
            let data = TestData.random(size, seed: 7)
            let (sender, receiver, sink, _, events) = transfer(kind, [("f.bin", data)])
            #expect(sender.status == .completed, "\(kind) size \(size) sender \(sender.status)")
            #expect(receiver.status == .completed, "\(kind) size \(size) receiver \(receiver.status)")
            #expect(sink.files.count == 1)
            #expect(sink.files.first?.data == data, "\(kind) size \(size)")
            #expect(completedFiles(events).first?.sha256 == TransferHash.sha256Hex(data))
        }
    }

    @Test(arguments: xyKinds)
    func everyByteValueAndOneMebibyte(kind: TransferProtocolKind) {
        for data in [TestData.everyByte, TestData.random(1 << 20, seed: 3)] {
            let (sender, receiver, sink, sendEvents, _) = transfer(kind, [("big.bin", data)])
            #expect(sender.status == .completed && receiver.status == .completed, "\(kind) \(data.count)")
            #expect(sink.files.first.map { TransferHash.sha256Hex($0.data) } == TransferHash.sha256Hex(data), "\(kind) \(data.count)")
            #expect(completedFiles(sendEvents).first?.sha256 == TransferHash.sha256Hex(data))
        }
    }

    @Test func ymodemBatchCarriesNamesSizesAndDates() {
        let clock = ManualTransferClock()
        let sink = MemoryTransferSink()
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        let files = [OutgoingFile(name: "ONE.TXT", data: Array("hello".utf8), modified: date, mode: 0o100644),
                     OutgoingFile(name: "empty.dat", data: []),
                     OutgoingFile(name: "three.bin", data: TestData.random(3000))]
        let sender = XModemSender(kind: .ymodem, files: files, clock: clock)
        let receiver = XModemReceiver(kind: .ymodem, sink: sink, clock: clock)
        runLink(sender, receiver, clock: clock)
        #expect(sender.status == .completed)
        #expect(receiver.status == .completed)
        #expect(sink.files.map(\.name) == ["ONE.TXT", "empty.dat", "three.bin"])
        #expect(sink.files.map(\.data.count) == [5, 0, 3000])
        #expect(sink.offers.first?.size == 5)
        #expect(sink.offers.first?.modified == date)
        #expect(sink.offers.first?.mode == 0o100644)
        #expect(receiver.progress.filesCompleted == 3)
    }

    @Test func plainXmodemPaddingRules() {
        let data = Array(repeating: UInt8(0x41), count: 100) + [0x1A]
        let (_, _, stripped, _, _) = transfer(.xmodemCRC, [("p", data)])
        #expect(stripped.files.first?.data == Array(repeating: 0x41, count: 100), "trailing SUBs are dropped, the classic limit")
        var keep = TransferOptions()
        keep.xmodemPadding = .keep
        let (_, _, kept, _, _) = transfer(.xmodemCRC, [("p", data)], options: keep)
        #expect(kept.files.first?.data == data + Array(repeating: 0x1A, count: 27))
        let (_, _, ymodem, _, _) = transfer(.ymodem, [("p", data)])
        #expect(ymodem.files.first?.data == data, "YMODEM keeps a real trailing SUB thanks to the size")
    }

    @Test(arguments: [TransferProtocolKind.xmodemCRC, .xmodem1K, .ymodem, .xmodem])
    func recoversFromLineErrorsBothWays(kind: TransferProtocolKind) {
        let data = TestData.random(40_000, seed: 11)
        var options = TransferOptions()
        options.maxRetries = 30
        for seed: UInt64 in [5, 21, 77, 1234] {
            // 0.0006 faults per byte: about half of all 1K blocks and 7% of 128 byte blocks are damaged.
            // The 8 bit checksum misses a shifted block 1 time in 256 (see checksumMissesShiftedBlocks),
            // so plain XMODEM gets only the faults a sum always catches: bit flips and drops.
            let shifts = kind == .xmodem ? 0.0 : 0.0001
            let toReceiver = LineFaults(seed: seed, drop: 0.0002, duplicate: shifts, corrupt: 0.0002, noise: shifts, activeBytes: 60_000)
            let toSender = LineFaults(seed: seed + 1, drop: 0.01, duplicate: 0.005, corrupt: 0.01, noise: 0.01, activeBytes: 200)
            let (sender, receiver, sink, _, events) = transfer(kind, [("noisy.bin", data)], options: options, aToB: toReceiver, bToA: toSender)
            #expect(sender.status == .completed, "\(kind) seed \(seed) \(sender.status)")
            #expect(receiver.status == .completed, "\(kind) seed \(seed) \(receiver.status)")
            #expect(sink.files.first?.data == data, "\(kind) seed \(seed)")
            #expect(events.contains { if case .recovered = $0 { return true } else { return false } }, "errors were seen and recovered")
        }
    }

    /// The reason XMODEM-CRC exists: a duplicated byte shifts the block so its last data byte is
    /// read as the checksum. The sum accepts some of those blocks; CRC-16 accepts none here.
    @Test func checksumMissesShiftedBlocks() {
        var rng = SeededRandom(99)
        var sumMisses = 0, crcMisses = 0
        for _ in 0..<4000 {
            let data = rng.bytes(129)
            let shifted = Array(data[0..<128])
            if TransferChecks.sum8(shifted[0..<127]) == shifted[127] { sumMisses += 1 }
            let crc = CRC16XMODEM.checksum(shifted[0..<126])
            if UInt8(crc >> 8) == shifted[126], UInt8(crc & 0xFF) == shifted[127] { crcMisses += 1 }
        }
        #expect(sumMisses > 0, "about 4000/256 = 16 expected")
        #expect(crcMisses == 0)
    }

    @Test func ymodemGStopsCleanlyOnAnError() {
        let data = TestData.random(20_000)
        let faults = LineFaults(seed: 9, corrupt: 0.001)
        let (sender, receiver, sink, _, _) = transfer(.ymodemG, [("g.bin", data)], aToB: faults)
        guard case .failed = receiver.status else { Issue.record("receiver \(receiver.status)"); return }
        guard case .failed = sender.status else { Issue.record("sender \(sender.status)"); return }
        #expect(sink.files.isEmpty)
        #expect(sink.aborted == 1)
    }
}

@Suite struct XModemProtocolTests {
    func block(_ number: UInt8, _ data: [UInt8], crc: Bool = true) -> [UInt8] {
        let padded = data + Array(repeating: 0x1A, count: max(0, 128 - data.count))
        var packet: [UInt8] = [0x01, number, ~number] + padded
        if crc {
            let value = CRC16XMODEM.checksum(padded)
            packet += [UInt8(value >> 8), UInt8(value & 0xFF)]
        } else {
            packet.append(TransferChecks.sum8(padded))
        }
        return packet
    }

    @Test func crcReceiverFallsBackToChecksum() {
        let clock = ManualTransferClock()
        let sink = MemoryTransferSink()
        var options = TransferOptions()
        options.startTries = 10
        let receiver = XModemReceiver(kind: .xmodemCRC, sink: sink, clock: clock, options: options)
        receiver.start()
        var sent: [UInt8] = receiver.takeOutput()
        for _ in 0..<4 {
            clock.advance(3.1)
            receiver.tick()
            sent += receiver.takeOutput()
        }
        #expect(Array(sent.prefix(3)) == [0x43, 0x43, 0x43])
        #expect(sent.last == 0x15, "NAK after the C tries")
        receiver.receive(block(1, Array("hi".utf8), crc: false))
        #expect(receiver.takeOutput() == [0x06])
        receiver.receive([0x04])
        #expect(receiver.takeOutput() == [0x06])
        #expect(receiver.status == .completed)
        #expect(sink.files.first?.data == Array("hi".utf8))
    }

    @Test func duplicateBlockIsAckedAndDropped() {
        let clock = ManualTransferClock()
        let sink = MemoryTransferSink()
        let receiver = XModemReceiver(kind: .xmodemCRC, sink: sink, clock: clock)
        receiver.start()
        _ = receiver.takeOutput()
        let one = block(1, Array(repeating: 0x31, count: 128))
        receiver.receive(one)
        receiver.receive(one)
        receiver.receive(block(2, Array("end".utf8)))
        #expect(receiver.takeOutput() == [0x06, 0x06, 0x06])
        receiver.receive([0x04])
        #expect(sink.files.first?.data == Array(repeating: 0x31, count: 128) + Array("end".utf8))
    }

    @Test func outOfSequenceBlockCancels() {
        let clock = ManualTransferClock()
        let sink = MemoryTransferSink()
        let receiver = XModemReceiver(kind: .xmodemCRC, sink: sink, clock: clock)
        receiver.start()
        _ = receiver.takeOutput()
        receiver.receive(block(1, [1]))
        receiver.receive(block(5, [1]))
        guard case .failed = receiver.status else { Issue.record("\(receiver.status)"); return }
        #expect(receiver.takeOutput().suffix(20).prefix(10) == ArraySlice(Array(repeating: UInt8(0x18), count: 10)))
        #expect(sink.aborted == 1)
    }

    @Test func canCanFromTheSenderCancels() {
        let clock = ManualTransferClock()
        let sink = MemoryTransferSink()
        let receiver = XModemReceiver(kind: .xmodem1K, sink: sink, clock: clock)
        receiver.start()
        receiver.receive(block(1, [1, 2, 3]))
        receiver.receive([0x18, 0x18])
        guard case .failed(let reason) = receiver.status else { Issue.record("\(receiver.status)"); return }
        #expect(reason.contains("cancelled by the sender"))
        #expect(sink.aborted == 1)
    }

    @Test func receiverCancelStopsTheSender() {
        let clock = ManualTransferClock()
        let sink = MemoryTransferSink()
        let sender = XModemSender(kind: .ymodem, files: [OutgoingFile(name: "c", data: TestData.random(50_000))], clock: clock)
        let receiver = XModemReceiver(kind: .ymodem, sink: sink, clock: clock)
        sender.start()
        receiver.start()
        for _ in 0..<20 {
            receiver.receive(sender.takeOutput())
            sender.receive(receiver.takeOutput())
        }
        receiver.cancel()
        sender.receive(receiver.takeOutput())
        #expect(receiver.status == .cancelled)
        guard case .failed(let reason) = sender.status else { Issue.record("\(sender.status)"); return }
        #expect(reason.contains("cancelled by the receiver"))
        #expect(sink.files.isEmpty)
        #expect(sink.aborted == 1)
    }

    @Test func senderGivesUpWithoutAReceiver() {
        let clock = ManualTransferClock()
        let sender = XModemSender(kind: .xmodemCRC, files: [OutgoingFile(name: "x", data: [1])], clock: clock)
        sender.start()
        clock.advance(61)
        sender.tick()
        guard case .failed = sender.status else { Issue.record("\(sender.status)"); return }
    }

    @Test func ymodemHeaderParsing() {
        let header = Array("dir/FILE.ZIP".utf8) + [0] + Array("12345 13207007200 100644 0 3 99999".utf8) + [0]
        let info = YModemHeader.parse(header + Array(repeating: 0, count: 128 - header.count))
        #expect(info?.name == "dir/FILE.ZIP")
        #expect(info?.size == 12345)
        #expect(info?.modified == Date(timeIntervalSince1970: 0o13207007200))
        #expect(info?.mode == 0o100644)
        #expect(YModemHeader.parse(Array(repeating: 0, count: 128))?.name == "")
        let onlyName = YModemHeader.parse(Array("x".utf8) + Array(repeating: 0, count: 127))
        #expect(onlyName?.size == nil)
        let encoded = YModemHeader.encode(name: "a b.txt", size: 10, modified: Date(timeIntervalSince1970: 8), mode: 0o644, filesLeft: 1, bytesLeft: 10)
        #expect(encoded.count == 128)
        #expect(YModemHeader.parse(encoded)?.size == 10)
        #expect(YModemHeader.encode(name: String(repeating: "n", count: 200), size: 1, modified: nil, mode: nil, filesLeft: 1, bytesLeft: 1).count == 1024)
    }
}
