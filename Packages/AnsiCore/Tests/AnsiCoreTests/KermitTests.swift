import Foundation
import Testing
@testable import AnsiCore

@Suite struct KermitCodecTests {
    func read(_ bytes: [UInt8], check: Int = 1) -> [KermitReader.Token] {
        let reader = KermitReader()
        reader.checkType = check
        var tokens: [KermitReader.Token] = []
        reader.feed(bytes) { tokens.append($0) }
        return tokens
    }

    @Test func decodesTheSPacketCKermitSends() {
        // Captured from `kermit -Y -q -B -i -s r1.bin` on a pty (C-Kermit 9.0.302).
        let wire = Array("\u{01}9 S~/ @-#Y3~^>J)0___N\"U1AH\r".utf8)
        let tokens = read(wire)
        guard case .packet(let packet) = tokens.first else { Issue.record("\(tokens)"); return }
        #expect(packet.type == UInt8(ascii: "S") && packet.seq == 0)
        let p = KermitParameters.parse(packet.data)
        #expect(p.maxLength == 94 && p.timeout == 15 && p.eol == 13 && p.qctl == UInt8(ascii: "#"))
        #expect(p.qbin == UInt8(ascii: "Y") && p.checkType == 3 && p.rept == UInt8(ascii: "~"))
        #expect(p.longPackets && p.slidingWindows && p.attributes)
        #expect(p.window == 30)
        #expect(p.maxLongLength == 3999)
        // And its receive side's opening NAK.
        guard case .packet(let nak) = read(Array("\u{01}# N3\r".utf8)).first else { Issue.record("no NAK"); return }
        #expect(nak.type == UInt8(ascii: "N") && nak.seq == 0 && nak.data.isEmpty)
    }

    @Test(arguments: [1, 2, 3])
    func packetsRoundTripShortAndLong(check: Int) {
        for length in [0, 1, 50, 88, 89, 91, 92, 500, 4000, 9000] {
            let data = (0..<length).map { UInt8(33 + $0 % 90) }
            let packet = KermitPacket(type: UInt8(ascii: "D"), seq: length % 64, data: data)
            let wire = KermitCodec.encode(packet, checkType: check)
            #expect(wire.first == 0x01 && wire.last == 0x0D)
            #expect(read(wire, check: check) == [.packet(packet)], "length \(length) check \(check)")
            if 2 + length + check > 94 { #expect(wire[1] == 32, "long packet for \(length)") }
        }
    }

    @Test func damagedPacketsAreRejectedAndAMarkResyncs() {
        var wire = KermitCodec.encode(KermitPacket(type: UInt8(ascii: "D"), seq: 3, data: Array("hello".utf8)), checkType: 3)
        wire[6] ^= 1
        guard case .bad = read(wire, check: 3).first else { Issue.record("not rejected"); return }
        let good = KermitCodec.encode(KermitPacket(type: UInt8(ascii: "Y"), seq: 4, data: []), checkType: 3)
        let tokens = read(Array(wire.prefix(5)) + good, check: 3)
        #expect(tokens.last == .packet(KermitPacket(type: UInt8(ascii: "Y"), seq: 4, data: [])))
        var long = KermitCodec.encode(KermitPacket(type: UInt8(ascii: "D"), seq: 1, data: Array(repeating: 65, count: 300)), checkType: 1)
        long[6] ^= 1  // the header check
        guard case .bad = read(long).first else { Issue.record("bad header check accepted"); return }
    }

    /// C-Kermit sends most control characters raw ("cautious" prefixing). From its debug log:
    /// a long D packet starting `01 20 23 44 21 52 5d 23 5c 06 bd ...`.
    @Test func rawControlCharactersInsideAPacketAreData() {
        let data: [UInt8] = [0x23, 0x5C, 0x06, 0xBD, 0x46, 0x08, 0x07, 0x17, 0x0D, 0x0A, 0x1A, 0x41]
        let wire = KermitCodec.encode(KermitPacket(type: UInt8(ascii: "D"), seq: 3, data: data), checkType: 3)
        #expect(read(wire, check: 3) == [.packet(KermitPacket(type: UInt8(ascii: "D"), seq: 3, data: data))])
        #expect(KermitQuoting(rept: UInt8(ascii: "~")).decode(data) == [0x1C, 0x06, 0xBD, 0x46, 0x08, 0x07, 0x17, 0x0D, 0x0A, 0x1A, 0x41])
    }

    @Test func sPacketsAreAlwaysReadWithCheckType1() {
        let s = KermitCodec.encode(KermitPacket(type: UInt8(ascii: "S"), seq: 0, data: Array("~* @-#Y3~".utf8)), checkType: 1)
        #expect(read(s, check: 3).count == 1)
        if case .packet = read(s, check: 3)[0] {} else { Issue.record("S must use check type 1") }
    }

    @Test(arguments: [(nil, nil), (UInt8(ascii: "&"), nil), (nil, UInt8(ascii: "~")), (UInt8(ascii: "&"), UInt8(ascii: "~"))] as [(UInt8?, UInt8?)])
    func prefixingRoundTripsEveryByte(qbin: UInt8?, rept: UInt8?) {
        let quoting = KermitQuoting(qctl: UInt8(ascii: "#"), qbin: qbin, rept: rept)
        let data = TestData.everyByte + Array(repeating: 0x41, count: 200) + Array(repeating: 0x23, count: 5) + Array(repeating: 0xFF, count: 3)
        var encoded: [UInt8] = []
        var index = 0
        while index < data.count {
            let piece = quoting.encode(data, from: index, budget: 40)
            #expect(piece.consumed > 0 && piece.bytes.count <= 40)
            encoded += piece.bytes
            index += piece.consumed
        }
        #expect(quoting.decode(encoded) == data)
        #expect(encoded.allSatisfy { ($0 & 0x7F) >= 32 && ($0 & 0x7F) != 127 }, "no control characters on the line")
        if qbin != nil { #expect(encoded.allSatisfy { $0 < 128 }, "7 bit clean with 8th bit prefixing") }
        if rept != nil {
            let plain = KermitQuoting(qctl: UInt8(ascii: "#"), qbin: qbin, rept: nil).encode(data)
            #expect(encoded.count < plain.count - 150, "runs are compressed")
        }
    }

    @Test func negotiationRules() {
        var ours = KermitParameters.ours(TransferOptions())
        var theirs = KermitParameters.parse(Array("~/ @-#Y3~^>J)".utf8))
        var settings = KermitSettings.negotiate(sender: ours, receiver: theirs, options: TransferOptions())
        #expect(settings.checkType == 3)
        #expect(settings.quoting.qbin == nil, "both said Y: no 8th bit prefixing needed")
        #expect(settings.quoting.rept == UInt8(ascii: "~"))
        #expect(settings.sendLimit == 3999)
        #expect(settings.window == 1, "we offered 1")
        theirs.checkType = 1
        settings = KermitSettings.negotiate(sender: ours, receiver: theirs, options: TransferOptions())
        #expect(settings.checkType == 1, "a mismatch falls back to type 1")
        ours.qbin = UInt8(ascii: "&")
        theirs.qbin = UInt8(ascii: "Y")
        #expect(KermitSettings.negotiate(sender: ours, receiver: theirs, options: TransferOptions()).quoting.qbin == UInt8(ascii: "&"))
        theirs.qbin = UInt8(ascii: "N")
        #expect(KermitSettings.negotiate(sender: ours, receiver: theirs, options: TransferOptions()).quoting.qbin == nil)
        var windowed = TransferOptions()
        windowed.kermitWindow = 8
        ours = KermitParameters.ours(windowed)
        theirs = KermitParameters.parse(Array("~/ @-#Y3~^>J)".utf8))
        #expect(KermitSettings.negotiate(sender: ours, receiver: theirs, options: windowed).window == 8)
        theirs.longPackets = false
        #expect(KermitSettings.negotiate(sender: ours, receiver: theirs, options: windowed).sendLimit == 94)
    }

    @Test func attributesRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        let encoded = KermitAttributes.encode(size: 123_456, modified: date)
        let parsed = KermitAttributes.parse(encoded)
        #expect(parsed.size == 123_456)
        #expect(parsed.modified == date)
        #expect(KermitAttributes.parse(Array("!\"12".utf8)).size == 12 * 1024, "size in K when no exact size")
        // The A packet data C-Kermit 9.0.302 sent for r127.bin, raw, from its debug log
        // ("sattr sending[...]"): system U1, type B8, date, 1 K, length 127, mode 644, ...
        let ckermit = KermitAttributes.parse(Array(".\"U1\"\"B8#120261030 13:17:10!!11#127,#644-!3@ ".utf8))
        #expect(ckermit.size == 127 && ckermit.type == "B8")
        #expect(ckermit.modified == KermitAttributes.formatter("yyyyMMdd HH:mm:ss").date(from: "20261030 13:17:10"))
    }
}

private func kTransfer(_ files: [OutgoingFile], sink: TransferSink, send: TransferOptions = TransferOptions(), receive: TransferOptions = TransferOptions(),
                       aToB: LineFaults? = nil, bToA: LineFaults? = nil) -> (KermitSender, KermitReceiver, [TransferEvent], [TransferEvent]) {
    let clock = ManualTransferClock()
    let sender = KermitSender(files: files, clock: clock, options: send)
    let receiver = KermitReceiver(sink: sink, clock: clock, options: receive)
    var f1 = aToB, f2 = bToA
    runLink(sender, receiver, clock: clock, aToB: &f1, bToA: &f2)
    return (sender, receiver, sender.takeEvents(), receiver.takeEvents())
}

private func kermitVariants() -> [(String, TransferOptions, TransferOptions)] {
    func with(_ change: (inout TransferOptions) -> Void) -> TransferOptions {
        var options = TransferOptions()
        change(&options)
        return options
    }
    return [("default", TransferOptions(), TransferOptions()),
            ("check 1", with { $0.kermitCheckType = 1 }, with { $0.kermitCheckType = 1 }),
            ("check 2", with { $0.kermitCheckType = 2 }, with { $0.kermitCheckType = 2 }),
            ("check mismatch", with { $0.kermitCheckType = 3 }, with { $0.kermitCheckType = 2 }),
            ("short packets", with { $0.kermitMaxPacket = 94 }, TransferOptions()),
            ("8th bit", with { $0.kermitForceEighthBitPrefix = true }, TransferOptions()),
            ("no repeat", with { $0.kermitUseRepeat = false }, TransferOptions()),
            ("no attributes", with { $0.kermitUseAttributes = false }, TransferOptions()),
            ("window 8", with { $0.kermitWindow = 8 }, with { $0.kermitWindow = 8 }),
            ("window 31 short", with { $0.kermitWindow = 31; $0.kermitMaxPacket = 94 }, with { $0.kermitWindow = 31 })]
}

@Suite struct KermitTransferTests {
    @Test func everySizeAndVariantArrivesIntact() {
        for (label, send, receive) in kermitVariants() {
            for size in TestData.sizes {
                let data = TestData.random(size, seed: 61)
                let sink = MemoryTransferSink()
                let (sender, receiver, sendEvents, receiveEvents) = kTransfer([OutgoingFile(name: "k.bin", data: data)], sink: sink, send: send, receive: receive)
                #expect(sender.status == .completed, "\(label) \(size) sender \(sender.status)")
                #expect(receiver.status == .completed, "\(label) \(size) receiver \(receiver.status)")
                #expect(sink.files.first?.data == data, "\(label) \(size)")
                #expect(completedFiles(receiveEvents).first?.sha256 == TransferHash.sha256Hex(data))
                #expect(completedFiles(sendEvents).first?.sha256 == TransferHash.sha256Hex(data))
            }
        }
    }

    @Test func everyByteValueAndOneMebibyte() {
        for (label, send, receive) in kermitVariants() {
            for data in [TestData.everyByte, TestData.random(1 << 20, seed: 67)] {
                let sink = MemoryTransferSink()
                let (sender, receiver, _, _) = kTransfer([OutgoingFile(name: "big", data: data)], sink: sink, send: send, receive: receive)
                #expect(sender.status == .completed && receiver.status == .completed, "\(label) \(data.count)")
                #expect(sink.files.first.map { TransferHash.sha256Hex($0.data) } == TransferHash.sha256Hex(data), "\(label) \(data.count)")
            }
        }
    }

    /// Found against C-Kermit: the receiver must agree to the sender's block check.
    @Test func receiverAgreesToTheSendersBlockCheck() {
        var send = TransferOptions(); send.kermitCheckType = 2
        var receive = TransferOptions(); receive.kermitCheckType = 3
        let (sender, receiver, sendEvents, receiveEvents) = kTransfer([OutgoingFile(name: "c", data: TestData.random(3000))],
                                                                      sink: MemoryTransferSink(), send: send, receive: receive)
        #expect(sender.status == .completed && receiver.status == .completed)
        for events in [sendEvents, receiveEvents] {
            #expect(events.contains { if case .negotiated(let text) = $0 { return text.hasPrefix("block check 2") } else { return false } })
        }
    }

    @Test func batchWithAttributesAndRefusalBySize() {
        let date = Date(timeIntervalSince1970: 1_100_000_000)
        let sink = MemoryTransferSink(maxFileSize: 10_000)
        let files = [OutgoingFile(name: "a.txt", data: Array("abc".utf8), modified: date), OutgoingFile(name: "huge.bin", data: TestData.random(20_000)),
                     OutgoingFile(name: "empty", data: []), OutgoingFile(name: "c.bin", data: TestData.random(9000))]
        let (sender, receiver, sendEvents, _) = kTransfer(files, sink: sink)
        #expect(sender.status == .completed && receiver.status == .completed)
        #expect(sink.files.map(\.name) == ["a.txt", "empty", "c.bin"])
        #expect(sink.offers.first?.size == 3)
        #expect(sink.offers.first?.modified == date)
        #expect(sendEvents.contains { if case .fileSkipped(let name, _) = $0 { return name == "huge.bin" } else { return false } })
    }

    @Test(arguments: [1, 8])
    func recoversFromLineErrorsBothWays(window: Int) {
        let data = TestData.random(150_000, seed: 71)
        var options = TransferOptions()
        options.kermitWindow = window
        options.maxRetries = 20
        for seed: UInt64 in [2, 9, 16, 23] {
            let sink = MemoryTransferSink()
            // 0.00015 faults per byte: about 45% of 4000 byte long packets are damaged.
            let toReceiver = LineFaults(seed: seed, drop: 0.00005, duplicate: 0.00002, corrupt: 0.00005, noise: 0.00003, activeBytes: 200_000)
            let toSender = LineFaults(seed: seed + 50, drop: 0.002, duplicate: 0.001, corrupt: 0.002, noise: 0.001, activeBytes: 5000)
            let (sender, receiver, _, receiveEvents) = kTransfer([OutgoingFile(name: "n.bin", data: data)], sink: sink, send: options, receive: options,
                                                                 aToB: toReceiver, bToA: toSender)
            #expect(sender.status == .completed, "window \(window) seed \(seed) sender \(sender.status)")
            #expect(receiver.status == .completed, "window \(window) seed \(seed) receiver \(receiver.status)")
            #expect(sink.files.first?.data == data, "window \(window) seed \(seed)")
            #expect(receiveEvents.contains { if case .recovered = $0 { return true } else { return false } })
        }
    }

    @Test func sevenBitLineNeedsEighthBitPrefixing() {
        func run(_ force: Bool) -> Bool {
            let clock = ManualTransferClock()
            var options = TransferOptions()
            options.kermitForceEighthBitPrefix = force
            let sink = MemoryTransferSink()
            let sender = KermitSender(files: [OutgoingFile(name: "7", data: TestData.everyByte)], clock: clock, options: options)
            let receiver = KermitReceiver(sink: sink, clock: clock, options: options)
            sender.start()
            receiver.start()
            for _ in 0..<20_000 where !(sender.status.isFinished && receiver.status.isFinished) {
                receiver.receive(sender.takeOutput().map { $0 & 0x7F })
                sender.receive(receiver.takeOutput().map { $0 & 0x7F })
                clock.advance(0.5)
                sender.tick()
                receiver.tick()
            }
            return sink.files.first?.data == TestData.everyByte
        }
        #expect(run(true), "with 8th bit prefixing every byte survives a 7 bit line")
        #expect(!run(false), "without it the high bits are lost")
    }

    @Test func cancelBothWaysSendsAnErrorPacket() {
        for receiverCancels in [true, false] {
            let clock = ManualTransferClock()
            let sink = MemoryTransferSink()
            let sender = KermitSender(files: [OutgoingFile(name: "c.bin", data: TestData.random(200_000))], clock: clock)
            let receiver = KermitReceiver(sink: sink, clock: clock)
            sender.start()
            receiver.start()
            for _ in 0..<30 {
                receiver.receive(sender.takeOutput())
                sender.receive(receiver.takeOutput())
            }
            if receiverCancels { receiver.cancel() } else { sender.cancel() }
            receiver.receive(sender.takeOutput())
            sender.receive(receiver.takeOutput())
            let (canceller, other) = receiverCancels ? (receiver as TransferEngine, sender as TransferEngine) : (sender, receiver)
            #expect(canceller.status == .cancelled)
            guard case .failed(let reason) = other.status else { Issue.record("\(other.status)"); continue }
            #expect(reason.contains("cancelled"))
            #expect(sink.files.isEmpty && sink.aborted == 1)
        }
    }

    @Test func overTelnetKeepsEveryByte() {
        #expect(runOverTelnet(kind: .kermit, data: TestData.everyByte + TestData.random(20_000)) == (true, true))
    }
}
