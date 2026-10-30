import Foundation
import Network
import Testing
@testable import AnsiCore

@Test func rloginHandshakeBytes() {
    let bytes = RLogin.handshake(clientUser: "alice", serverUser: "bob", terminal: "ansi/38400")
    #expect(bytes == [0] + Array("alice".utf8) + [0] + Array("bob".utf8) + [0] + Array("ansi/38400".utf8) + [0])
}

@Test func rloginSpeedAndTermDefaults() {
    var s = TransportSettings(mode: .rlogin)
    s.terminalType = "ANSI-BBS"
    s.username = "guest"
    #expect(RLogin.terminalField(s) == "ansi-bbs/38400")
    s.baud = 2400
    #expect(RLogin.terminalField(s) == "ansi-bbs/2400")
    s.terminalType = " "
    #expect(RLogin.terminalField(s) == "ansi/2400")
    #expect(RLogin.users(s) == (client: "guest", server: "guest"))
    s.rloginClientUser = "secretword"
    s.rloginServerUser = "Sysop"
    #expect(RLogin.users(s) == (client: "secretword", server: "Sysop"))
}

@Test func rloginAcceptedThenData() {
    var answer = RLoginAnswer()
    #expect(answer.feed([]) == .waiting)
    #expect(answer.feed([0, 65, 66]) == .accepted(rest: [65, 66]))
}

@Test func rloginRefusalMessage() {
    var answer = RLoginAnswer()
    #expect(answer.feed([1] + Array("Permission ".utf8)) == .waiting)
    #expect(answer.feed(Array("denied.\r\nmore".utf8)) == .refused("Permission denied."))
    var closed = RLoginAnswer()
    _ = closed.feed([1] + Array("No ".utf8))
    #expect(closed.ended() == "No")
}

@Test func rloginSplitAnswer() {
    // The NUL alone in one packet, data in the next.
    var answer = RLoginAnswer()
    #expect(answer.feed([0]) == .accepted(rest: []))
}

@Test func rloginRefusalIsBounded() {
    var answer = RLoginAnswer()
    let result = answer.feed([1] + Array(repeating: UInt8(65), count: 5000))
    guard case .refused(let text) = result else {
        Issue.record("expected refusal once the message is too long, got \(result)")
        return
    }
    #expect(text.count <= RLoginAnswer.maxMessage)
}

@Test func rloginLoopbackHandshake() async throws {
    // The server records what arrives; the test answers by hand.
    let server = try LoopbackServer { _ in }
    defer { server.stop() }
    let port = await server.port()
    var settings = TransportSettings(mode: .rlogin)
    settings.username = "guest"
    settings.terminalType = "ANSI"
    let queue = DispatchQueue(label: "test.rlogin")
    let client = BBSClient(host: "127.0.0.1", port: port, settings: settings, columns: 80, rows: 25, connectTimeout: testConnectTimeout, queue: queue)
    let data = Box<[UInt8]>([])
    client.onData = { b in data.update { $0 += b } }
    client.connect()
    let expected = RLogin.handshake(clientUser: "guest", serverUser: "guest", terminal: "ansi/38400")
    #expect(await eventually { server.received.value == expected })
    // Not connected until the server's NUL.
    #expect(client.state == .connecting)
    let conn = try #require(server.connection.value)
    conn.send(content: Data([0] + Array("login: ".utf8)), completion: .contentProcessed { _ in })
    #expect(await eventually { client.state == .connected })
    #expect(await eventually { data.value == Array("login: ".utf8) })
    client.send([255, 13, 0])
    #expect(await eventually { server.received.value == expected + [255, 13, 0] })
    client.disconnect()
}

@Test func rloginRefusedEndsConnection() async throws {
    let server = try LoopbackServer { _ in }
    defer { server.stop() }
    let port = await server.port()
    let client = BBSClient(host: "127.0.0.1", port: port, settings: TransportSettings(mode: .rlogin), columns: 80,
                           rows: 25, connectTimeout: testConnectTimeout, queue: DispatchQueue(label: "test.rlogin2"))
    let states = Box<[BBSClientState]>([])
    client.onState = { s in states.update { $0.append(s) } }
    client.connect()
    #expect(await eventually { !server.received.value.isEmpty })
    let conn = try #require(server.connection.value)
    conn.send(content: Data([1] + Array("Login incorrect.\n".utf8)), completion: .contentProcessed { _ in })
    #expect(await eventually { states.value.last == .closed(.rloginRefused("Login incorrect.")) })
    #expect(!states.value.contains(.connected))
}
