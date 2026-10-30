import Foundation
import Testing
@testable import AnsiCore

// Fixes from the transports review (Important 2 and 3).

@Test func excessiveBcryptRoundsAreRefusedBeforeWork() throws {
    let url = try #require(Bundle.module.url(forResource: "ed25519_rounds", withExtension: nil, subdirectory: "Fixtures/sshkeys"))
    let data = try Data(contentsOf: url)
    let start = Date()
    #expect(throws: SSHKeyFileError.tooManyRounds(5000)) {
        try SSHKeyFile.parse(data, passphrase: "fixture-passphrase")
    }
    #expect(Date().timeIntervalSince(start) < 0.5)
    #expect(SSHKeyFileError.tooManyRounds(5000).message.contains("5000"))
}

@Test func rloginCanSendThePasswordAsClientUser() {
    var e = BBSEntry(name: "R", host: "r.example.com", port: 513)
    e.mode = .rlogin
    e.username = "guest"
    e.rloginClientIsPassword = true
    var s = TransportSettings(entry: e)
    s.password = "pw"
    #expect(RLogin.users(s) == (client: "pw", server: "guest"))
    s.password = nil
    #expect(RLogin.users(s) == (client: "", server: "guest"))
    // The setting round trips, an old entry defaults to off, and the form edits it.
    let back = try? JSONDecoder().decode(BBSEntry.self, from: JSONEncoder().encode(e))
    #expect(back?.rloginClientIsPassword == true)
    var f = EntryForm.make(entry: e, password: "", fonts: ["IBM VGA"], speeds: [0])
    #expect(f.field("rloginClientIsPassword") != nil)
    #expect(f.field("rloginClient")?.hint.lowercased().contains("password") == false)
    f.select(id: "rloginClientIsPassword")
    _ = f.handle(.right)
    #expect(EntryForm.apply(f, to: e).entry.rloginClientIsPassword == false)
}

@Test func resizeWhileConnectingReachesTheTransport() async {
    let fake = FakeTransport()
    let client = BBSClient(host: "h", port: 1, settings: TransportSettings(mode: .ssh), columns: 80, rows: 25,
                           queue: DispatchQueue(label: "test.resize"), transport: fake)
    client.connect()
    #expect(await eventually { fake.opened.value })
    client.resize(columns: 132, rows: 50)
    #expect(await eventually { fake.sizes.value == ["132x50"] })
}

@Test func syncTermRLoginWithPasswordSendsItAsClientUser() {
    let r = SyncTermImport.parse("[R]\nAddress=r.example.com\nConnectionType=RLogin\nUsername=u\nPassword=p\n[S]\nAddress=s.example.com\nConnectionType=RLogin\n")
    #expect(r.entries[0].entry.rloginClientIsPassword)
    #expect(!r.entries[1].entry.rloginClientIsPassword)
    #expect(!String(decoding: DialingDirectory(entries: r.entries.map(\.entry)).encoded(), as: UTF8.self).contains("\"p\""))
}
