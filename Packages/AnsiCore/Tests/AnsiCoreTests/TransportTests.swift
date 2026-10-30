import Foundation
import Network
import Testing
@testable import AnsiCore

/// A transport the test drives by hand: records writes and resizes, delivers what the test says.
final class FakeTransport: BBSTransport, @unchecked Sendable {
    var events: ((TransportEvent) -> Void)?
    let written = Box<[UInt8]>([])
    let sizes = Box<[String]>([])
    let opened = Box(false)
    let closed = Box(false)
    /// Delivered from inside `open()` (on the client's queue), before the test can react.
    var eventOnOpen: TransportEvent?

    func open() {
        opened.value = true
        if let eventOnOpen { events?(eventOnOpen) }
    }
    func write(_ bytes: [UInt8]) { written.update { $0 += bytes } }
    func resize(columns: Int, rows: Int) { sizes.update { $0.append("\(columns)x\(rows)") } }
    func close() { closed.value = true }
}

private func decode(_ json: String) throws -> BBSEntry {
    try JSONDecoder().decode(BBSEntry.self, from: Data(json.utf8))
}

@Test func newModesDecodeAndDefaultPorts() throws {
    #expect(ConnectionMode.allCases == [.telnet, .raw, .ssh, .webSocket, .rlogin])
    #expect(ConnectionMode.allCases.map(\.label) == ["Telnet", "Raw TCP", "SSH", "WebSocket", "RLogin"])
    #expect(ConnectionMode.telnet.defaultPort() == 23)
    #expect(ConnectionMode.raw.defaultPort() == 23)
    #expect(ConnectionMode.ssh.defaultPort() == 22)
    #expect(ConnectionMode.webSocket.defaultPort() == 80)
    #expect(ConnectionMode.webSocket.defaultPort(secure: true) == 443)
    #expect(ConnectionMode.rlogin.defaultPort() == 513)
    for mode in ConnectionMode.allCases {
        let e = try decode(#"{"name":"A","host":"a.example.com","mode":"\#(mode.rawValue)"}"#)
        #expect(e.mode == mode)
    }
}

@Test func oldEntryDecodesWithTransportDefaults() throws {
    let e = try decode(#"{"name":"Old","host":"old.example.com","port":23,"mode":"telnet"}"#)
    #expect(e.sshKeyBookmark == nil && e.sshKeyName == nil && e.sshTrustNewHostKey == false)
    #expect(e.webSocketPath == "/" && e.webSocketSecure == false && e.webSocketSubprotocols == "")
    #expect(e.webSocketTelnet == false)
    #expect(e.rloginClientUser == "" && e.rloginServerUser == "")
}

@Test func unknownModeFallsBackToTelnet() throws {
    let e = try decode(#"{"name":"F","host":"f.example.com","mode":"carrierPigeon"}"#)
    #expect(e.mode == .telnet)
}

@Test func transportFieldsRoundTrip() throws {
    var e = BBSEntry(name: "W", host: "w.example.com", port: 8080)
    e.mode = .webSocket
    e.webSocketPath = "/ws"
    e.webSocketSecure = true
    e.webSocketSubprotocols = "telnet, binary"
    e.webSocketTelnet = true
    e.sshKeyBookmark = Data([1, 2, 3])
    e.sshKeyName = "id_ed25519"
    e.sshTrustNewHostKey = true
    e.rloginClientUser = "c"
    e.rloginServerUser = "s"
    let back = try JSONDecoder().decode(BBSEntry.self, from: JSONEncoder().encode(e))
    #expect(back == e)
}

@Test func exportDropsSSHKeyBookmark() throws {
    var e = BBSEntry(name: "S", host: "s.example.com", port: 22)
    e.mode = .ssh
    e.sshKeyBookmark = Data([9, 9, 9])
    e.sshKeyName = "id_ed25519"
    let directory = DialingDirectory(entries: [e])
    let imported = try DialingDirectory.importEntries(from: directory.exportData(ids: nil))
    #expect(imported.first?.sshKeyBookmark == nil)
    #expect(imported.first?.sshKeyName == nil)
}

@Test func telnetLayerChoice() {
    var e = BBSEntry(name: "T", host: "t.example.com")
    #expect(TransportSettings(entry: e).usesTelnet)
    e.mode = .raw
    #expect(!TransportSettings(entry: e).usesTelnet)
    e.mode = .ssh
    #expect(!TransportSettings(entry: e).usesTelnet)
    e.mode = .rlogin
    #expect(!TransportSettings(entry: e).usesTelnet)
    e.mode = .webSocket
    #expect(!TransportSettings(entry: e).usesTelnet)
    e.webSocketTelnet = true
    #expect(TransportSettings(entry: e).usesTelnet)
    e.webSocketSubprotocols = " telnet ,binary,, "
    #expect(TransportSettings(entry: e).webSocketSubprotocols == ["telnet", "binary"])
}

@Test func clientWithoutSSHTransportFails() async {
    let settings = TransportSettings(mode: .ssh)
    let client = BBSClient(host: "127.0.0.1", port: 22, settings: settings, columns: 80, rows: 25,
                           connectTimeout: testConnectTimeout, queue: DispatchQueue(label: "test.ssh"))
    let states = Box<[BBSClientState]>([])
    client.onState = { s in states.update { $0.append(s) } }
    client.connect()
    #expect(await eventually { states.value.last.map { if case .closed = $0 { return true } else { return false } } ?? false })
    #expect(states.value.last == .closed(.unsupported("SSH connections need the AnsiView app.")))
}

@Test func clientRunsTelnetOverInjectedTransport() async {
    var settings = TransportSettings(mode: .webSocket)
    settings.webSocketTelnet = true
    let fake = FakeTransport()
    let queue = DispatchQueue(label: "test.fake")
    let client = BBSClient(host: "h", port: 1, settings: settings, columns: 80, rows: 25, connectTimeout: testConnectTimeout, queue: queue, transport: fake)
    let data = Box<[UInt8]>([])
    let states = Box<[BBSClientState]>([])
    client.onData = { b in data.update { $0 += b } }
    client.onState = { s in states.update { $0.append(s) } }
    client.connect()
    #expect(await eventually { fake.opened.value })
    #expect(states.value == [.connecting])
    queue.sync { fake.events?(.opened) }
    #expect(await eventually { states.value.last == .connected })
    // Telnet start: offers sent over the transport.
    #expect(await eventually { fake.written.value.contains(255) })
    fake.written.value = []
    // IAC DO NAWS is answered over the transport, text passes, IAC IAC becomes 255.
    queue.sync { fake.events?(.bytes([255, 253, 31, 65, 255, 255, 66])) }
    #expect(await eventually { data.value == [65, 255, 66] })
    #expect(await eventually { fake.written.value.starts(with: [255, 251, 31]) || fake.written.value.contains(31) })
    fake.written.value = []
    client.send([255, 1])
    #expect(await eventually { fake.written.value == [255, 255, 1] })
    client.resize(columns: 132, rows: 50)
    #expect(await eventually { fake.sizes.value == ["132x50"] })
    queue.sync { fake.events?(.closed(.closedByRemote)) }
    #expect(await eventually { states.value.last == .closed(.closedByRemote) })
}

@Test func cleanTransportPassesBytesUnchanged() async {
    let fake = FakeTransport()
    let queue = DispatchQueue(label: "test.clean")
    let client = BBSClient(host: "h", port: 1, settings: TransportSettings(mode: .ssh), columns: 80, rows: 25,
                           connectTimeout: testConnectTimeout, queue: queue, transport: fake)
    let data = Box<[UInt8]>([])
    client.onData = { b in data.update { $0 += b } }
    client.connect()
    #expect(await eventually { fake.opened.value })
    queue.sync { fake.events?(.opened) }
    #expect(await eventually { client.state == .connected })
    #expect(client.isByteClean)
    let all = (0...255).map { UInt8($0) }
    queue.sync { fake.events?(.bytes(all)) }
    #expect(await eventually { data.value == all })
    client.send(all)
    #expect(await eventually { fake.written.value == all })
    client.disconnect()
    #expect(await eventually { fake.closed.value })
}

@Test func byteCleanFlag() async {
    let fake = FakeTransport()
    let queue = DispatchQueue(label: "test.flag")
    let client = BBSClient(host: "h", port: 1, settings: TransportSettings(mode: .telnet), columns: 80, rows: 25,
                           connectTimeout: testConnectTimeout, queue: queue, transport: fake)
    client.connect()
    #expect(await eventually { fake.opened.value })
    queue.sync { fake.events?(.opened) }
    #expect(await eventually { client.state == .connected })
    // Telnet without BINARY both ways is not byte clean.
    #expect(!client.isByteClean)
    // Server: WILL BINARY (we accept, remote on) and DO BINARY (we offered, local on).
    queue.sync { fake.events?(.bytes([255, 251, 0, 255, 253, 0])) }
    #expect(await eventually { client.isByteClean })
}

@Test func connectTimeoutPausesWhileTheUserDecides() async {
    let fake = FakeTransport()
    let queue = DispatchQueue(label: "test.pause")
    let client = BBSClient(host: "h", port: 1, settings: TransportSettings(mode: .ssh), columns: 80, rows: 25,
                           connectTimeout: 0.3, queue: queue, transport: fake)
    let states = Box<[BBSClientState]>([])
    client.onState = { s in states.update { $0.append(s) } }
    // A host key alert is up at once: the connect timeout must not fire while it waits for the user.
    fake.eventOnOpen = .waitingForUser(true)
    client.connect()
    #expect(await eventually { fake.opened.value })
    try? await Task.sleep(nanoseconds: 700_000_000)
    #expect(states.value == [.connecting])
    // Answered: the timeout runs again from now.
    queue.sync { fake.events?(.waitingForUser(false)) }
    #expect(await eventually { states.value.last == .closed(.timedOut("h")) })
}
