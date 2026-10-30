import Foundation
import Testing
@testable import AnsiCore

@Suite struct TelnetTransferTests {
    @Test func requestBinaryAsksForBothDirectionsOnce() {
        var session = TelnetSession(columns: 80, rows: 25)
        #expect(session.requestBinary() == [255, 251, 0, 255, 253, 0])
        // The server agrees: no further replies, both directions on.
        let answer = session.receive([255, 253, 0, 255, 251, 0])
        #expect(answer.reply.isEmpty)
        #expect(session.localEnabled(.binary) && session.remoteEnabled(.binary))
    }

    @Test func encodeDoublesIACAndDecodeStripsCommands() {
        var a = TelnetTransferChannel()
        var b = TelnetTransferChannel()
        var toB = a.start()
        var toA = b.start()
        // Deliver each side's negotiation and the answers until both are quiet.
        for _ in 0..<4 {
            let rb = b.decode(toB).reply
            let ra = a.decode(toA).reply
            toB = ra
            toA = rb
        }
        #expect(a.isByteClean && b.isByteClean)
        let payload: [UInt8] = [1, 255, 2, 13, 0, 13, 10, 255, 255]
        let wire = a.encode(payload)
        #expect(wire.filter { $0 == 255 }.count == 6, "every 255 doubled")
        // A server command in the middle of the data is removed.
        let decoded = b.decode(Array(wire.prefix(3)) + [255, 241] + Array(wire.dropFirst(3)))
        #expect(decoded.data == payload)
    }

    /// Two channels talking telnet to each other with BINARY negotiated, and a YMODEM transfer of
    /// every byte value through them. (The ZMODEM and Kermit versions are in their own suites.)
    @Test func ymodemOverTelnetKeepsEveryByte() {
        let result = runOverTelnet(kind: .ymodem, data: TestData.everyByte + TestData.random(5000))
        #expect(result.ok)
        #expect(result.bothBinary)
    }
}

/// Runs a transfer between two engines with a telnet channel on each side.
func runOverTelnet(kind: TransferProtocolKind, data: [UInt8], options: TransferOptions = TransferOptions()) -> (ok: Bool, bothBinary: Bool) {
    let clock = ManualTransferClock()
    let sink = MemoryTransferSink()
    let sender = TransferEngineFactory.sender(kind: kind, files: [OutgoingFile(name: "t.bin", data: data)], clock: clock, options: options)
    let receiver = TransferEngineFactory.receiver(kind: kind, sink: sink, clock: clock, options: options)
    var left = TelnetTransferChannel()
    var right = TelnetTransferChannel()
    var toRight = left.start()
    var toLeft = right.start()
    sender.start()
    receiver.start()
    var rounds = 0
    while !(sender.status.isFinished && receiver.status.isFinished), rounds < 400_000 {
        rounds += 1
        toRight += left.encode(sender.takeOutput(max: 4096))
        toLeft += right.encode(receiver.takeOutput(max: 4096))
        let r = right.decode(toRight)
        let l = left.decode(toLeft)
        toRight = l.reply
        toLeft = r.reply
        receiver.receive(r.data)
        sender.receive(l.data)
        clock.advance(r.data.isEmpty && l.data.isEmpty ? 0.25 : 0.0001)
        sender.tick()
        receiver.tick()
    }
    let ok = sender.status == .completed && receiver.status == .completed && sink.files.first?.data == data
    return (ok, left.isByteClean && right.isByteClean)
}
