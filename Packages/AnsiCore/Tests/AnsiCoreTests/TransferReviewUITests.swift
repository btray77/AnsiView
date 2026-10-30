import Foundation
import Testing
@testable import AnsiCore

private let zrqinit: [UInt8] = Array("**".utf8) + [0x18] + Array("B00000000000000\r\n".utf8) + [0x11]

/// Fixes from the final review of the transfers UI branch.
@Suite struct TransferReviewUITests {
    /// Review 3: leaving the BINARY wait must always tell the app to resume the terminal.
    @Test func leavingNegotiationAlwaysEndsPending() {
        var menu = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        _ = menu.begin(kind: .zmodem, direction: .receive, at: 0, byteClean: false)
        #expect(menu.cancelPending(at: 1) == [.endPending])
        #expect(menu.state == .idle)

        var detected = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        _ = detected.received(zrqinit, at: 0, byteClean: false)
        _ = detected.accept(at: 0.5, byteClean: false)
        #expect(detected.cancelPending(at: 1) == [.sendToRemote(TransferCoordinator.cancelSequence), .endPending])

        var closed = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: true)
        _ = closed.begin(kind: .ymodem, direction: .send, at: 0, byteClean: false)
        #expect(closed.connectionClosed(at: 1) == [.endPending])
    }

    /// Review 8: text held for the ask bar is drawn when the line closes.
    @Test func heldBytesAreDrawnOnDisconnect() {
        var c = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        _ = c.received(zrqinit, at: 0, byteClean: true)
        _ = c.received(Array("NO CARRIER".utf8), at: 1, byteClean: true)
        #expect(c.connectionClosed(at: 2) == [.hideOffer, .showOnScreen(zrqinit + Array("NO CARRIER".utf8))])
    }

    /// Review 13: only a start the BBS made gets the cancel sequence when we cannot start.
    @Test func requestKnowsWhoStarted() {
        var menu = TransferCoordinator(autoAcceptZmodem: false, usesTelnet: false)
        let mine = menu.begin(kind: .xmodem, direction: .send, at: 0, byteClean: true)
        guard case .startSession(let a)? = mine.last else { Issue.record("no start"); return }
        #expect(a.fromBBS == false)
        var auto = TransferCoordinator(autoAcceptZmodem: true, usesTelnet: false)
        let theirs = auto.received(zrqinit, at: 0, byteClean: true)
        guard case .startSession(let b)? = theirs.last else { Issue.record("no auto start"); return }
        #expect(b.fromBBS == true)
    }

    /// Review 4: the terminal writes back only the transfer setting it changed.
    @Test func entryMergeTouchesOnlyChangedFields() {
        var stored = BBSEntry(name: "A", host: "a")
        stored.downloadFolderBookmark = Data([1])
        stored.downloadFolderName = "~/New"
        stored.zmodemAutoAccept = true
        var stale = stored
        stale.downloadFolderBookmark = nil
        stale.downloadFolderName = nil
        stale.transferProtocol = .kermit
        let merged = stored.merging(transferSettings: [.protocolChoice], from: stale)
        #expect(merged.transferProtocol == .kermit)
        #expect(merged.downloadFolderBookmark == Data([1]))
        #expect(merged.downloadFolderName == "~/New")
        let folder = stored.merging(transferSettings: [.downloadFolder], from: stale)
        #expect(folder.downloadFolderBookmark == nil)
        #expect(folder.transferProtocol == .zmodem)
    }

    /// Review 6: a failed or cancelled batch still lists the files that were saved.
    @Test func failedSummaryListsSavedFiles() {
        let url = URL(fileURLWithPath: "/tmp/dl/one.bin")
        let one = TransferredFile(name: "one.bin", remoteName: "one.bin", bytes: 5, sha256: "aa", url: url)
        let s = TransferSummary(outcome: .failed("line dropped"), kind: .zmodem, direction: .receive, elapsed: 1, bytes: 5,
                                savedBeforeEnd: [one])
        #expect(s.headline == "Transfer failed: line dropped")
        #expect(s.files == [one])
        #expect(s.lines.first?.hasPrefix("one.bin: 5 bytes") == true)
        #expect(s.folder?.path == "/tmp/dl")
        #expect(!s.succeeded)
    }

    /// Review 14: exports carry no download folder (bookmarks only work on this Mac).
    @Test func exportDropsDownloadFolder() throws {
        var e = BBSEntry(name: "A", host: "a")
        e.downloadFolderBookmark = Data([1, 2])
        e.downloadFolderName = "/Users/me/Downloads"
        e.transferProtocol = .kermit
        var d = DialingDirectory()
        d.entries = [e]
        let text = String(decoding: d.exportData(ids: nil), as: UTF8.self)
        #expect(!text.contains("downloadFolder"))
        #expect(text.contains("kermit"))
    }
}
