import Foundation
import Testing
@testable import AnsiCore

/// Per entry file transfer settings, their editor fields and the protocol hints.
@Suite struct TransferEntryTests {
    @Test func entryTransferFieldsDefaultAndDecode() throws {
        let entry = BBSEntry(name: "A", host: "a.example.com")
        #expect(entry.transferProtocol == .zmodem)
        #expect(entry.downloadFolderBookmark == nil)
        #expect(entry.downloadFolderName == nil)
        #expect(entry.zmodemAutoAccept == false)
        let old = Data(#"{"name":"Old","host":"old.example.com"}"#.utf8)
        let decoded = try JSONDecoder().decode(BBSEntry.self, from: old)
        #expect(decoded.transferProtocol == .zmodem)
        #expect(decoded.zmodemAutoAccept == false)
        var changed = entry
        changed.transferProtocol = .kermit
        changed.downloadFolderBookmark = Data([1, 2, 3])
        changed.downloadFolderName = "~/Downloads"
        changed.zmodemAutoAccept = true
        let back = try JSONDecoder().decode(BBSEntry.self, from: JSONEncoder().encode(changed))
        #expect(back == changed)
        let bad = Data(#"{"name":"Bad","host":"b.example.com","transferProtocol":"hydra"}"#.utf8)
        #expect(try JSONDecoder().decode(BBSEntry.self, from: bad).transferProtocol == .zmodem)
    }

    @Test func formHasTransferSection() throws {
        var entry = BBSEntry(name: "A", host: "a.example.com")
        entry.transferProtocol = .ymodem
        var form = EntryForm.make(entry: entry, password: "", fonts: ["IBM VGA"], speeds: [0])
        let proto = try #require(form.field("transferProtocol"))
        #expect(proto.section == "File transfers")
        #expect(proto.index == TransferProtocolKind.allCases.firstIndex(of: .ymodem))
        if case .choice(let options) = proto.kind {
            #expect(options == ["XMODEM", "XMODEM-CRC", "XMODEM-1K", "YMODEM", "YMODEM-G", "ZMODEM", "Kermit"])
        } else {
            Issue.record("transferProtocol is not a choice")
        }
        let folder = try #require(form.field("chooseDownloadFolder"))
        #expect(folder.section == "File transfers")
        if case .action = folder.kind {} else { Issue.record("chooseDownloadFolder is not an action") }
        #expect(folder.text == "Choose..." || folder.hint.contains("Downloads"))
        #expect(form.field("clearDownloadFolder") != nil)
        let auto = try #require(form.field("zmodemAutoAccept"))
        if case .toggle = auto.kind {} else { Issue.record("zmodemAutoAccept is not a toggle") }
        for id in ["transferProtocol", "chooseDownloadFolder", "clearDownloadFolder", "zmodemAutoAccept"] {
            let hint = try #require(form.field(id)).hint
            #expect(!hint.isEmpty)
            #expect(RetroCanvas.wrap(hint, width: 74).count <= 2, "\(id) hint is longer than two lines")
            #expect(!hint.contains("\u{2014}"))
        }
        let pi = try #require(form.fields.firstIndex { $0.id == "transferProtocol" })
        form.fields[pi].index = 6
        let ai = try #require(form.fields.firstIndex { $0.id == "zmodemAutoAccept" })
        form.fields[ai].isOn = true
        let applied = EntryForm.apply(form, to: entry).entry
        #expect(applied.transferProtocol == .kermit)
        #expect(applied.zmodemAutoAccept)

        var withFolder = entry
        withFolder.downloadFolderBookmark = Data([9])
        withFolder.downloadFolderName = "~/Downloads/BBS"
        let shown = EntryForm.make(entry: withFolder, password: "", fonts: ["IBM VGA"], speeds: [0])
        #expect(shown.field("chooseDownloadFolder")?.text == "~/Downloads/BBS")
        let cleared = EntryForm.perform("clearDownloadFolder", on: withFolder)
        #expect(cleared.downloadFolderBookmark == nil)
        #expect(cleared.downloadFolderName == nil)
    }

    @Test func everyProtocolHasPlainHint() {
        for kind in TransferProtocolKind.allCases {
            let hint = TransferHelp.hint(kind)
            #expect(!hint.isEmpty)
            #expect(!hint.contains("\u{2014}"))
            let sentences = hint.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect((1...2).contains(sentences.count), "\(kind) hint has \(sentences.count) sentences")
        }
        #expect(TransferHelp.hint(.zmodem).contains("BBS offers it"))
        for text in [TransferHelp.chooser, TransferHelp.autoStart, TransferHelp.binaryWarning(for: .xmodem), TransferHelp.binaryWarning(for: .zmodem), TransferHelp.resume] {
            #expect(!text.isEmpty)
            #expect(!text.contains("\u{2014}"))
        }
    }
}
