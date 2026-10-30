import Foundation
import Testing
@testable import AnsiCore

private let fonts = ["IBM VGA", "IBM EGA"]
private let speeds = [2400, 0]

private func form(_ e: BBSEntry, passphrase: String = "") -> TextForm {
    EntryForm.make(entry: e, password: "", passphrase: passphrase, fonts: fonts, speeds: speeds)
}

private let sshIDs = ["chooseKey", "clearKey", "keyPassphrase", "trustNewHostKey", "forgetHostKey"]
private let wsIDs = ["wsSecure", "wsPath", "wsSubprotocols", "wsTelnet"]
private let rloginIDs = ["rloginClient", "rloginServer"]

@Test func protocolFieldsShownPerMode() {
    var e = BBSEntry(name: "A", host: "a.example.com")
    let ids: (BBSEntry) -> Set<String> = { Set(form($0).fields.map(\.id)) }
    for mode in [ConnectionMode.telnet, .raw] {
        e.mode = mode
        #expect(ids(e).isDisjoint(with: sshIDs + wsIDs + rloginIDs))
    }
    e.mode = .ssh
    #expect(ids(e).isSuperset(of: sshIDs) && ids(e).isDisjoint(with: wsIDs + rloginIDs))
    e.mode = .webSocket
    #expect(ids(e).isSuperset(of: wsIDs) && ids(e).isDisjoint(with: sshIDs + rloginIDs))
    e.mode = .rlogin
    #expect(ids(e).isSuperset(of: rloginIDs) && ids(e).isDisjoint(with: sshIDs + wsIDs))
    #expect(form(e).field("mode")?.kind == .choice(["Telnet", "Raw TCP", "SSH", "WebSocket", "RLogin"]))
}

@Test func everyTransportFieldHasHint() {
    for mode in ConnectionMode.allCases {
        var e = BBSEntry(name: "A", host: "a.example.com")
        e.mode = mode
        for field in form(e).fields {
            #expect(field.hint.count > 20, "\(field.id)")
            #expect(!field.hint.contains("\u{2014}"), "\(field.id)")
        }
    }
}

@Test func protocolChangeMovesDefaultPort() {
    let e = BBSEntry(name: "A", host: "a.example.com")
    var f = form(e)
    f.select(id: "mode")
    _ = f.handle(.right)  // Raw TCP: same default port
    _ = f.handle(.right)  // SSH
    let ssh = EntryForm.changingProtocol(f, draft: e)
    #expect(ssh.mode == .ssh && ssh.port == 22)
    var g = form(ssh)
    g.select(id: "mode")
    _ = g.handle(.right)  // WebSocket
    let ws = EntryForm.changingProtocol(g, draft: ssh)
    #expect(ws.mode == .webSocket && ws.port == 80)
    var h = form(ws)
    h.select(id: "wsSecure")
    _ = h.handle(.right)
    let wss = EntryForm.changingProtocol(h, draft: ws)
    #expect(wss.webSocketSecure && wss.port == 443)
    var i = form(wss)
    i.select(id: "mode")
    _ = i.handle(.right)  // RLogin
    #expect(EntryForm.changingProtocol(i, draft: wss).port == 513)
}

@Test func protocolChangeKeepsCustomPort() {
    let e = BBSEntry(name: "A", host: "a.example.com", port: 2323)
    var f = form(e)
    f.select(id: "mode")
    _ = f.handle(.right)
    _ = f.handle(.right)
    let ssh = EntryForm.changingProtocol(f, draft: e)
    #expect(ssh.mode == .ssh && ssh.port == 2323)
}

@Test func applyReadsTransportFields() {
    var e = BBSEntry(name: "W", host: "w.example.com", port: 1123)
    e.mode = .webSocket
    var f = form(e)
    f.select(id: "wsPath")
    for _ in 0..<1 { _ = f.handle(.backspace) }
    for c in "/ws" { _ = f.handle(.character(c)) }
    f.select(id: "wsSubprotocols")
    for c in "telnet" { _ = f.handle(.character(c)) }
    f.select(id: "wsTelnet")
    _ = f.handle(.right)
    let w = EntryForm.apply(f, to: e).entry
    #expect(w.webSocketPath == "/ws" && w.webSocketSubprotocols == "telnet" && w.webSocketTelnet)

    var r = BBSEntry(name: "R", host: "r.example.com", port: 513)
    r.mode = .rlogin
    var g = form(r)
    g.select(id: "rloginClient")
    for c in "cu" { _ = g.handle(.character(c)) }
    g.select(id: "rloginServer")
    for c in "su" { _ = g.handle(.character(c)) }
    let rr = EntryForm.apply(g, to: r).entry
    #expect(rr.rloginClientUser == "cu" && rr.rloginServerUser == "su")

    var s = BBSEntry(name: "S", host: "s.example.com", port: 22)
    s.mode = .ssh
    s.sshKeyName = "id_ed25519"
    var h = form(s, passphrase: "old")
    #expect(h.field("chooseKey")?.text == "id_ed25519")
    #expect(h.field("keyPassphrase")?.kind == .secret(maxLength: 200))
    h.select(id: "keyPassphrase")
    _ = h.handle(.character("x"))
    h.select(id: "trustNewHostKey")
    _ = h.handle(.right)
    #expect(EntryForm.apply(h, to: s).entry.sshTrustNewHostKey)
    #expect(EntryForm.passphrase(h) == "oldx")
    // Forget key file clears the bookmark and name.
    s.sshKeyBookmark = Data([1])
    let cleared = EntryForm.perform("clearKey", on: s)
    #expect(cleared.sshKeyBookmark == nil && cleared.sshKeyName == nil)
}

@Test func passphraseKeyIsSeparateFromPassword() {
    var e = BBSEntry(name: "S", host: "s.example.com", port: 22)
    #expect(e.sshPassphraseKey == nil)
    e.username = "guest"
    #expect(e.sshPassphraseKey == CredentialKey(host: "s.example.com", port: 22, account: "ssh-key-passphrase:guest"))
    #expect(e.sshPassphraseKey != e.credentialKey)
}

@Test func syncTermImportsSSHAndRLogin() {
    let text = """
    [Secure Board]
    Address=ssh.example.com
    ConnectionType=SSH
    Username=guest
    Password=pw
    [No Auth Board]
    Address=noauth.example.com
    Port=2022
    ConnectionType=SSHNA
    [Login Board]
    Address=rlogin.example.com
    ConnectionType=RLogin
    [Reversed]
    Address=rev.example.com
    ConnectionType=RLoginReversed
    [Tls]
    Address=tls.example.com
    ConnectionType=TelnetS
    """
    let result = SyncTermImport.parse(text)
    #expect(result.entries.map(\.entry.mode) == [.ssh, .ssh, .rlogin])
    #expect(result.entries.map(\.entry.port) == [22, 2022, 513])
    #expect(result.entries[0].password == "pw")
    #expect(result.entries[1].password == nil)
    #expect(result.skipped == ["Reversed (RLoginReversed)", "Tls (TelnetS)"])
}
