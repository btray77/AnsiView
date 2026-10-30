import Foundation
import Testing
@testable import AnsiCore

private let zrqinit: [UInt8] = Array("**".utf8) + [0x18] + Array("B00000000000000\r\n".utf8) + [0x11]
private let zrinit: [UInt8] = Array("**".utf8) + [0x18] + Array("B0100000023be50\r\n".utf8) + [0x11]

private func started(_ actions: [TransferCoordinatorAction]) -> TransferRequest? {
    for case .startSession(let request) in actions { return request }
    return nil
}

private func shown(_ actions: [TransferCoordinatorAction]) -> [UInt8] {
    var out: [UInt8] = []
    for case .showOnScreen(let bytes) in actions { out += bytes }
    return out
}

/// The terminal's transfer state: detection, the ask bar, BINARY, flow control, panel text, logs.
@Suite struct TransferCoordinatorTests {
    @Test func idlePassesBytesToScreen() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        let actions = c.received(Array("Hello\r\n".utf8), at: 0, byteClean: false)
        #expect(actions == [.showOnScreen(Array("Hello\r\n".utf8))])
        #expect(!c.isTransferActive)
    }

    @Test func zrqinitShowsOfferAndHoldsBytes() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        let actions = c.received(Array("sz file\r\n".utf8) + zrqinit, at: 0, byteClean: true)
        #expect(shown(actions) == Array("sz file\r\n".utf8))
        guard case .offering(let offer) = c.state else { Issue.record("not offering: \(c.state)"); return }
        #expect(offer.detected == .zmodemReceive)
        #expect(offer.message == "The BBS wants to send files with ZMODEM.")
        #expect(offer.acceptTitle == "Receive")
        #expect(actions.contains(.showOffer(offer)))
        #expect(c.heldCount == zrqinit.count)
        // More bytes while asking are held, not drawn.
        #expect(c.received(zrqinit, at: 1, byteClean: true).isEmpty)
        #expect(c.heldCount == zrqinit.count * 2)
        #expect(!c.isTransferActive)
    }

    @Test func acceptStartsAfterBinary() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        _ = c.received(zrqinit, at: 0, byteClean: false)
        let accepted = c.accept(at: 1, byteClean: false)
        #expect(accepted == [.hideOffer, .requestBinary])
        #expect(c.isTransferActive)
        #expect(c.tick(at: 1.5, byteClean: false).isEmpty)
        _ = c.received([1, 2], at: 1.6, byteClean: false)
        let actions = c.tick(at: 1.7, byteClean: true)
        let request = started(actions)
        #expect(request?.kind == .zmodem)
        #expect(request?.direction == .receive)
        #expect(request?.initialBytes == zrqinit + [1, 2])
        #expect(request?.byteClean == true)
        #expect(request?.warning == nil)
        #expect(request?.options().resume == true)
        #expect(request?.options().zmodemEscapeTelnet == false)
        #expect(c.state == .running)
        #expect(c.received([9], at: 2, byteClean: true) == [.feedSession([9])])
    }

    @Test func binaryTimeoutStartsWithWarning() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        #expect(c.begin(kind: .zmodem, direction: .receive, at: 0, byteClean: false) == [.requestBinary])
        #expect(c.tick(at: 1.9, byteClean: false).isEmpty)
        let request = started(c.tick(at: 2.0, byteClean: false))
        #expect(request?.byteClean == false)
        #expect(request?.warning == TransferHelp.binaryWarning)
        #expect(request?.options().zmodemEscapeTelnet == true)

        var k = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        _ = k.begin(kind: .kermit, direction: .send, at: 0, byteClean: false)
        let kermit = started(k.tick(at: 3, byteClean: false))
        #expect(kermit?.warning == nil)
        #expect(kermit?.options().kermitForceEighthBitPrefix == true)

        var y = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        _ = y.begin(kind: .ymodem, direction: .send, at: 0, byteClean: false)
        #expect(started(y.tick(at: 3, byteClean: false))?.warning == TransferHelp.binaryWarning)
    }

    @Test func refusedBinaryWarnsAndEscapes() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        _ = c.begin(kind: .zmodem, direction: .send, at: 0, byteClean: false)
        let request = started(c.tick(at: 5, byteClean: false))
        #expect(request?.options().zmodemEscapeTelnet == true)
        #expect(request?.options().resume == false)
    }

    @Test func rawStartsAtOnce() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        let request = started(c.begin(kind: .xmodem1K, direction: .send, at: 0, byteClean: true))
        #expect(request?.kind == .xmodem1K)
        #expect(request?.direction == .send)
        #expect(request?.warning == nil)
        #expect(c.state == .running)
        // A telnet session that is already in BINARY both ways starts at once too.
        var t = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        #expect(started(t.begin(kind: .zmodem, direction: .receive, at: 0, byteClean: true)) != nil)
    }

    @Test func autoAcceptSkipsBar() {
        var c = TransferCoordinator(autoAcceptZmodem: true, usesTelnet: false)
        let actions = c.received(Array("go".utf8) + zrqinit, at: 0, byteClean: true)
        #expect(shown(actions) == Array("go".utf8))
        #expect(!actions.contains { if case .showOffer = $0 { return true }; return false })
        #expect(started(actions)?.initialBytes == zrqinit)
    }

    @Test func autoAcceptDoesNotApplyToUploadOffers() {
        var c = TransferCoordinator(autoAcceptZmodem: true, usesTelnet: false)
        let actions = c.received(zrinit, at: 0, byteClean: true)
        guard case .offering(let offer) = c.state else { Issue.record("not offering"); return }
        #expect(offer.detected == .zmodemSend)
        #expect(offer.acceptTitle == "Choose Files to Upload")
        #expect(offer.message == "The BBS is ready to receive files with ZMODEM.")
        #expect(started(actions) == nil)
    }

    @Test func ignoreShowsHeldAndQuiets60s() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = c.received(zrqinit, at: 0, byteClean: true)
        #expect(c.ignore(at: 1) == [.hideOffer, .showOnScreen(zrqinit)])
        #expect(c.state == .idle)
        // The BBS's sz retries: drawn, not asked again.
        #expect(c.received(zrqinit, at: 30, byteClean: true) == [.showOnScreen(zrqinit)])
        #expect(c.state == .idle)
        // After the quiet minute it asks again.
        _ = c.received(zrqinit, at: 62, byteClean: true)
        if case .offering = c.state {} else { Issue.record("expected an offer after 60 s") }
    }

    @Test func falsePositiveIsAskedNotStarted() {
        // A chat line that happens to contain the ZRQINIT start and a Kermit-looking packet.
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        let chat = Array("<Bob> look: **".utf8) + [0x18] + Array("B00 haha\r\n".utf8)
        let actions = c.received(chat, at: 0, byteClean: true)
        #expect(started(actions) == nil)
        if case .offering = c.state {} else { Issue.record("a match must be asked about") }
        #expect(!c.isTransferActive)
        // Ignoring loses nothing: every byte reaches the screen.
        #expect(shown(actions) + shown(c.ignore(at: 1)) == chat)
    }

    @Test func heldOverflowReleasesToScreen() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = c.received(zrqinit, at: 0, byteClean: true)
        let flood = [UInt8](repeating: 0x41, count: TransferCoordinator.maxHeld)
        let actions = c.received(flood, at: 1, byteClean: true)
        #expect(actions.first == .hideOffer)
        #expect(shown(actions) == zrqinit + flood)
        #expect(c.state == .idle)
    }

    @Test func zrinitOffersUpload() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = c.received(zrinit, at: 0, byteClean: true)
        #expect(c.accept(at: 1, byteClean: true) == [.hideOffer, .chooseUploadFiles(.zmodem)])
        #expect(c.state == .choosingFiles(.zmodem))
        #expect(c.received(zrinit, at: 2, byteClean: true).isEmpty)
        let request = started(c.filesChosen(true, at: 3, byteClean: true))
        #expect(request?.direction == .send)
        #expect(request?.kind == .zmodem)
        #expect(request?.initialBytes == zrinit + zrinit)

        var d = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = d.received(zrinit, at: 0, byteClean: true)
        _ = d.accept(at: 1, byteClean: true)
        #expect(d.filesChosen(false, at: 2, byteClean: true) == [.showOnScreen(zrinit)])
        #expect(d.state == .idle)
    }

    @Test func kermitOffers() {
        var c = TransferCoordinator(autoAcceptZmodem: true, usesTelnet: false)
        let packet: [UInt8] = [0x01, 0x2C, 0x20, 0x53] + Array("~* @-#Y3~^>J)0___R".utf8) + [0x0D]
        _ = c.received(packet, at: 0, byteClean: true)
        guard case .offering(let offer) = c.state else { Issue.record("not offering"); return }
        #expect(offer.message == "The BBS wants to send files with Kermit.")
        #expect(started(c.accept(at: 1, byteClean: true))?.kind == .kermit)
    }

    @Test func runningFeedsSessionOnly() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = c.begin(kind: .ymodem, direction: .receive, at: 0, byteClean: true)
        // Even a start pattern goes to the session while one runs.
        #expect(c.received(zrqinit, at: 1, byteClean: true) == [.feedSession(zrqinit)])
    }

    @Test func sessionFinishedResets() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = c.begin(kind: .zmodem, direction: .receive, at: 0, byteClean: true)
        // Half a start pattern arrives just before the end; it must not linger in the detector.
        _ = c.received(Array("**".utf8), at: 1, byteClean: true)
        c.sessionFinished(at: 2)
        #expect(c.state == .idle)
        #expect(!c.isTransferActive)
        #expect(c.received(Array("Welcome back\r\n".utf8), at: 3, byteClean: true) == [.showOnScreen(Array("Welcome back\r\n".utf8))])
    }

    @Test func restartRightAfterSessionIsOffered() {
        // The user cancels, then at once asks the BBS to send again: the new start must be asked about.
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = c.begin(kind: .zmodem, direction: .receive, at: 0, byteClean: true)
        c.sessionFinished(at: 2)
        _ = c.received(Array("Starting lsz\r\n".utf8) + zrqinit, at: 2.2, byteClean: true)
        if case .offering = c.state {} else { Issue.record("a new start right after a session was not offered: \(c.state)") }
    }

    @Test func cancelWhileNegotiatingIsClean() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        _ = c.received(zrqinit, at: 0, byteClean: false)
        _ = c.accept(at: 1, byteClean: false)
        let actions = c.cancelPending(at: 1.5)
        #expect(actions.contains(.sendToRemote(TransferCoordinator.cancelSequence)))
        #expect(c.state == .idle)
        #expect(!c.isTransferActive)
        #expect(c.tick(at: 10, byteClean: false).isEmpty)
        // Cancelling the bar is the same as Ignore.
        var o = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = o.received(zrqinit, at: 0, byteClean: true)
        #expect(o.cancelPending(at: 1) == [.hideOffer, .showOnScreen(zrqinit)])
    }

    @Test func menuDownloadDuringOfferUsesHeldBytes() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = c.received(zrqinit, at: 0, byteClean: true)
        let actions = c.begin(kind: .zmodem, direction: .receive, at: 1, byteClean: true)
        #expect(actions.first == .hideOffer)
        #expect(started(actions)?.initialBytes == zrqinit)
    }

    @Test func connectionLostFailsSession() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = c.begin(kind: .zmodem, direction: .receive, at: 0, byteClean: true)
        #expect(c.connectionClosed(at: 1) == [.failSession("the connection closed")])
        // Not running: nothing to fail.
        var idle = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        #expect(idle.connectionClosed(at: 1).isEmpty)
    }

    @Test func flowWindowLimitsInFlight() {
        var flow = TransferFlow(window: 1000, chunk: 300)
        #expect(flow.nextChunkSize() == 300)
        flow.sent(300); flow.sent(300); flow.sent(300)
        #expect(flow.nextChunkSize() == 100)
        flow.sent(100)
        #expect(flow.nextChunkSize() == 0)
        flow.completed(300)
        #expect(flow.inFlight == 700)
        #expect(flow.nextChunkSize() == 300)
        flow.completed(5000)
        #expect(flow.inFlight == 0)
    }
}

@Suite struct TransferPanelModelTests {
    private func progress(name: String? = "big.zip", bytes: Int, size: Int?, done: Int = 0, session: Int, rate: Double, eta: Double?) -> FileTransferSession.Progress {
        FileTransferSession.Progress(fileName: name, fileBytes: bytes, fileSize: size, filesCompleted: done, sessionBytes: session,
                                     bytesPerSecond: rate, eta: eta, elapsed: 3)
    }

    @Test func panelStrings() {
        var m = TransferPanelModel(kind: .zmodem, direction: .send, fileCount: 3, totalBytes: 3_000_000, zmodemBlockSize: 1024)
        #expect(m.title == "Sending with ZMODEM")
        #expect(m.fileName == "Waiting for the BBS...")
        m.apply(progress(bytes: 524_288, size: 1_048_576, done: 1, session: 1_572_864, rate: 12_288, eta: 42))
        #expect(m.fileName == "big.zip")
        #expect(m.fileLine == "File 2 of 3")
        #expect(m.bytesLine == "524,288 of 1,048,576 bytes")
        #expect(m.totalLine == "1,572,864 of 3,000,000 bytes in all")
        #expect(m.fraction == 0.5)
        #expect(m.speedLine == "12.0 KB/s")
        #expect(m.etaLine == "0:42")
        #expect(m.blockLine == "1024 byte subpackets")
        #expect(m.errorsLine == "0")
        #expect(m.resumeLine == nil)
        m.apply(.recovered("bad CRC"))
        m.apply(.recovered("timeout"))
        #expect(m.errorsLine == "2")
        m.apply(.fileStarted(name: "big.zip", size: 1_048_576, offset: 304_128))
        #expect(m.resumeLine == "Resumed at 304,128 bytes")
        m.apply(.fileStarted(name: "next.zip", size: 10, offset: 0))
        #expect(m.resumeLine == nil)
    }

    @Test func receiveAndBlockLines() {
        var r = TransferPanelModel(kind: .ymodem, direction: .receive, fileCount: nil, totalBytes: nil)
        #expect(r.title == "Receiving with YMODEM")
        r.apply(progress(bytes: 100, size: nil, session: 100, rate: 500, eta: nil))
        #expect(r.fileLine == "File 1")
        #expect(r.bytesLine == "100 bytes")
        #expect(r.totalLine == "100 bytes in all")
        #expect(r.fraction == nil)
        #expect(r.speedLine == "500 B/s")
        #expect(r.etaLine == "unknown")
        #expect(r.blockLine == "1024 bytes")
        #expect(TransferPanelModel(kind: .xmodem, direction: .send, fileCount: 1, totalBytes: 1).blockLine == "128 bytes")
        #expect(TransferPanelModel(kind: .xmodem1K, direction: .send, fileCount: 1, totalBytes: 1).blockLine == "1024 bytes (128 near the end)")
        #expect(TransferPanelModel(kind: .zmodem, direction: .receive, fileCount: nil, totalBytes: nil).blockLine == "the sender's choice (up to 8192)")
        var k = TransferPanelModel(kind: .kermit, direction: .receive, fileCount: nil, totalBytes: nil)
        #expect(k.blockLine == "negotiating")
        k.apply(.negotiated("packets 4000, window 1, check 3"))
        #expect(k.blockLine == "packets 4000, window 1, check 3")
        var fast = TransferPanelModel(kind: .zmodem, direction: .receive, fileCount: nil, totalBytes: nil)
        fast.apply(progress(bytes: 1, size: 7300, session: 1, rate: 3.5 * 1_048_576, eta: 3725))
        #expect(fast.speedLine == "3.5 MB/s")
        #expect(fast.etaLine == "1:02:05")
        fast.warning = TransferHelp.binaryWarning
        #expect(fast.warning == TransferHelp.binaryWarning)
    }

    @Test func summaryListsFilesAndHashes() {
        let url = URL(fileURLWithPath: "/Users/x/Downloads/a.bin")
        let a = TransferredFile(name: "a.bin", remoteName: "A.BIN", bytes: 1_048_576, sha256: String(repeating: "ab", count: 32), url: url)
        let b = TransferredFile(name: "b.bin", remoteName: "b.bin", bytes: 10, sha256: String(repeating: "cd", count: 32), url: nil,
                                resumedFrom: 4, announcedSize: 20)
        let s = TransferSummary(outcome: .completed([a, b]), kind: .zmodem, direction: .receive, elapsed: 2, bytes: 1_048_586)
        #expect(s.headline == "Received 2 files, 1,048,586 bytes in 0:02 (512.0 KB/s) with ZMODEM")
        #expect(s.succeeded)
        #expect(s.files == [a, b])
        #expect(s.lines[0] == "a.bin: 1,048,576 bytes, SHA-256 " + String(repeating: "ab", count: 32))
        #expect(s.lines[1].contains("resumed from 4"))
        #expect(s.lines[1].contains("SHORT"))
        #expect(s.folder?.path == "/Users/x/Downloads")
        let failed = TransferSummary(outcome: .failed("10 retries"), kind: .xmodem, direction: .send, elapsed: 1, bytes: 0)
        #expect(failed.headline == "Transfer failed: 10 retries")
        #expect(!failed.succeeded)
        let cancelled = TransferSummary(outcome: .cancelled("cancelled by user"), kind: .kermit, direction: .send, elapsed: 1, bytes: 0)
        #expect(cancelled.headline == "Transfer cancelled: cancelled by user")
        let one = TransferSummary(outcome: .completed([a]), kind: .zmodem, direction: .send, elapsed: 0, bytes: 1_048_576)
        #expect(one.headline.hasPrefix("Sent 1 file, 1,048,576 bytes in 0:00"))
        #expect(one.folder == nil)
    }

    @Test func logStoreAppendsAndTrims() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xferlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TransferLogStore(directory: dir, maxBytes: 1000)
        let id = UUID()
        #expect(store.read(entryID: id) == "")
        try store.append(entryID: id, text: "first\n")
        try store.append(entryID: id, text: "second\n")
        #expect(store.read(entryID: id) == "first\nsecond\n")
        #expect(store.url(for: id).lastPathComponent == "\(id.uuidString).log")
        for i in 0..<100 { try store.append(entryID: id, text: "line \(i) of the log\n") }
        let text = store.read(entryID: id)
        #expect(text.utf8.count <= 1000)
        #expect(text.hasSuffix("line 99 of the log\n"))
        #expect(text.hasPrefix("line "))
        let date = Date(timeIntervalSince1970: 0)
        let header = TransferLogStore.header(entryName: "Test BBS", kind: .zmodem, direction: .receive, date: date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(header == "=== 1970-01-01 00:00:00 Test BBS: ZMODEM receive")
    }
}
