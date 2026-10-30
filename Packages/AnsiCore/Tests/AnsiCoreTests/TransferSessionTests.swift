import Foundation
import Testing
@testable import AnsiCore

@Suite struct FileTransferSessionTests {
    /// Connects two sessions through their callbacks, advancing a manual clock.
    func pump(_ a: FileTransferSession, _ b: FileTransferSession, clock: ManualTransferClock, step: TimeInterval = 0.01, limit: Int = 200_000) {
        a.start()
        b.start()
        var rounds = 0
        while (a.outcome == nil || b.outcome == nil), rounds < limit {
            rounds += 1
            let x = a.takeOutput(max: 2048)
            let y = b.takeOutput(max: 2048)
            if !x.isEmpty { b.feed(x) }
            if !y.isEmpty { a.feed(y) }
            clock.advance(x.isEmpty && y.isEmpty ? 0.5 : step)
            a.tick()
            b.tick()
        }
    }

    @Test func reportsRateEtaOutcomeAndLog() {
        let clock = ManualTransferClock()
        let data = TestData.random(64 * 1024)
        let sink = MemoryTransferSink()
        let sender = FileTransferSession(sending: [OutgoingFile(name: "s.bin", data: data)], kind: .ymodem, clock: clock)
        let receiver = FileTransferSession(receivingInto: sink, kind: .ymodem, clock: clock)
        var progress: [FileTransferSession.Progress] = []
        var finished: [FileTransferSession.Outcome] = []
        receiver.onProgress = { progress.append($0) }
        receiver.onFinish = { finished.append($0) }
        pump(sender, receiver, clock: clock)
        #expect(finished.count == 1, "onFinish fires once")
        guard case .completed(let files) = receiver.outcome else { Issue.record("\(String(describing: receiver.outcome))"); return }
        #expect(files.map(\.sha256) == [TransferHash.sha256Hex(data)])
        guard case .completed = sender.outcome else { Issue.record("sender \(String(describing: sender.outcome))"); return }
        let middle = progress.first { $0.fileBytes > 16 * 1024 && $0.fileBytes < 48 * 1024 }
        #expect(middle != nil)
        if let middle {
            #expect(middle.bytesPerSecond > 0)
            #expect(middle.eta != nil)
            #expect(middle.fileSize == data.count)
        }
        #expect(receiver.log.contains { if case .fileCompleted = $0.event { return true } else { return false } })
        #expect(receiver.logLines().contains { $0.contains("sha256 \(TransferHash.sha256Hex(data))") })
    }

    @Test func pushModeDeliversOutputThroughTheCallback() {
        let clock = ManualTransferClock()
        let receiver = FileTransferSession(receivingInto: MemoryTransferSink(), kind: .xmodemCRC, clock: clock)
        var sent: [UInt8] = []
        receiver.onOutput = { sent += $0 }
        receiver.start()
        #expect(sent == [0x43])
    }

    @Test func cancelReportsAndCleansUp() {
        let clock = ManualTransferClock()
        let sink = MemoryTransferSink()
        let receiver = FileTransferSession(receivingInto: sink, kind: .zmodem, clock: clock)
        var out: [UInt8] = []
        receiver.onOutput = { out += $0 }
        receiver.start()
        receiver.cancel()
        guard case .cancelled = receiver.outcome else { Issue.record("\(String(describing: receiver.outcome))"); return }
        #expect(out.suffix(20) == ArraySlice(Array(repeating: UInt8(0x18), count: 10) + Array(repeating: UInt8(0x08), count: 10)))
    }

    @Test func everyKindHasAnEngineInBothDirections() {
        let clock = ManualTransferClock()
        for kind in TransferProtocolKind.allCases {
            let s = FileTransferSession(sending: [OutgoingFile(name: "a", data: [1])], kind: kind, clock: clock)
            let r = FileTransferSession(receivingInto: MemoryTransferSink(), kind: kind, clock: clock)
            #expect(s.direction == .send && r.direction == .receive)
        }
    }
}
