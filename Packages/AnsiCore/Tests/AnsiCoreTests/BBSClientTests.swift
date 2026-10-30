import Foundation
import Network
import Testing
@testable import AnsiCore

/// Thread safe storage for values written on network queues and read by the test.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

/// Polls until `condition` holds or `timeout` seconds pass.
func eventually(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// A loopback TCP server for tests: runs `script` on each accepted connection and records what it receives.
final class LoopbackServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "test.server")
    let received = Box<[UInt8]>([])
    let connection = Box<NWConnection?>(nil)

    init(script: @escaping (NWConnection) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [received, connection, queue] conn in
            connection.value = conn
            conn.stateUpdateHandler = { state in
                if case .ready = state { script(conn) }
            }
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let data { received.update { $0 += Array(data) } }
                    if !complete, error == nil { receive() }
                }
            }
            receive()
            conn.start(queue: queue)
        }
        listener.start(queue: queue)
    }

    func port() async -> Int {
        _ = await eventually { (listener.port?.rawValue ?? 0) != 0 }
        return Int(listener.port?.rawValue ?? 0)
    }

    func stop() {
        connection.value?.cancel()
        listener.cancel()
    }
}

private func makeClient(port: Int, mode: ConnectionMode = .telnet, host: String = "127.0.0.1",
                        timeout: TimeInterval = 15) -> (BBSClient, Box<[BBSClientState]>, Box<[UInt8]>) {
    let client = BBSClient(host: host, port: port, mode: mode, columns: 80, rows: 25,
                           connectTimeout: timeout, queue: DispatchQueue(label: "test.client"))
    let states = Box<[BBSClientState]>([])
    let data = Box<[UInt8]>([])
    client.onState = { state in states.update { $0.append(state) } }
    client.onData = { bytes in data.update { $0 += bytes } }
    return (client, states, data)
}

private func send(_ conn: NWConnection, _ bytes: [UInt8]) {
    conn.send(content: Data(bytes), completion: .contentProcessed { _ in })
}

@Test func pacerReleasesAtBaud() {
    var pacer = LinePacer(baud: 2400)
    pacer.push([UInt8](repeating: 65, count: 1000))
    #expect(pacer.release(elapsed: 1).count == 240)
    #expect(pacer.pending == 760)
    #expect(pacer.release(elapsed: 10).count == 760)
    #expect(pacer.pending == 0)
    var fast = LinePacer(baud: 0)
    fast.push([1, 2, 3])
    #expect(fast.release(elapsed: 0) == [1, 2, 3])
}

@Test func pacerCarriesFractions() {
    var pacer = LinePacer(baud: 300)
    pacer.push([UInt8](repeating: 65, count: 100))
    var total = 0
    for _ in 0..<10 { total += pacer.release(elapsed: 0.01).count }
    #expect(total == 3)
}

@Test func pacerDoesNotSaveUpIdleTime() {
    var pacer = LinePacer(baud: 300)
    #expect(pacer.release(elapsed: 100).isEmpty)
    pacer.push([UInt8](repeating: 65, count: 100))
    #expect(pacer.release(elapsed: 0.1).count == 3)
}

@Test func errorMapping() {
    let h = "bbs.example.com"
    #expect(BBSConnectionError.from(.dns(-65554), host: h, port: 23, connected: false) == .hostNotFound(h))
    #expect(BBSConnectionError.from(.posix(.ECONNREFUSED), host: h, port: 23, connected: false) == .refused(h, 23))
    #expect(BBSConnectionError.from(.posix(.ETIMEDOUT), host: h, port: 23, connected: false) == .timedOut(h))
    #expect(BBSConnectionError.from(.posix(.ECONNRESET), host: h, port: 23, connected: true) == .closedByRemote)
    #expect(BBSConnectionError.from(.posix(.ENETUNREACH), host: h, port: 23, connected: false) == .unreachable(h))
    let all: [BBSConnectionError] = [.hostNotFound(h), .refused(h, 23), .timedOut(h), .closedByRemote,
                                     .unreachable(h), .other("x")]
    for error in all {
        #expect(!error.message.isEmpty)
        #expect(!error.message.contains("\u{2014}"))
    }
    #expect(BBSConnectionError.refused(h, 2323).message.contains("2323"))
    #expect(BBSConnectionError.hostNotFound(h).message.contains(h))
}

@Test func telnetSessionAgainstLocalServer() async throws {
    let script: [UInt8] = [255, 253, 24, 255, 251, 1, 255, 251, 3, 255, 253, 31, 255, 250, 24, 1, 255, 240]
        + Array("Hello".utf8) + [255, 255]
    let server = try LoopbackServer { conn in send(conn, script) }
    defer { server.stop() }
    let (client, states, data) = makeClient(port: await server.port())
    client.connect()
    #expect(await eventually { data.value.count == 6 })
    #expect(data.value == Array("Hello".utf8) + [255])
    let expected: [UInt8] = [255, 253, 3, 255, 251, 24, 255, 251, 31]
        + [255, 253, 1]
        + [255, 250, 31, 0, 80, 0, 25, 255, 240]
        + [255, 250, 24, 0] + Array("ANSI".utf8) + [255, 240]
    #expect(await eventually { server.received.value.count >= expected.count })
    #expect(server.received.value == expected)
    client.send([13])
    #expect(await eventually { server.received.value.count == expected.count + 2 })
    #expect(Array(server.received.value.suffix(2)) == [13, 0])
    #expect(states.value.contains(.connected))
    client.resize(columns: 132, rows: 50)
    #expect(await eventually { server.received.value.count == expected.count + 2 + 9 })
    #expect(Array(server.received.value.suffix(9)) == [255, 250, 31, 0, 132, 0, 50, 255, 240])
    client.disconnect()
}

@Test func rawModeSendsNoNegotiation() async throws {
    let server = try LoopbackServer { conn in send(conn, [65, 255, 66, 13, 0]) }
    defer { server.stop() }
    let (client, _, data) = makeClient(port: await server.port(), mode: .raw)
    client.connect()
    #expect(await eventually { data.value.count == 5 })
    #expect(data.value == [65, 255, 66, 13, 0])
    client.send([255, 13])
    #expect(await eventually { server.received.value.count == 2 })
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(server.received.value == [255, 13])
    client.disconnect()
}

@Test func refusedConnectionIsReported() async throws {
    let server = try LoopbackServer { _ in }
    let port = await server.port()
    server.stop()
    try? await Task.sleep(nanoseconds: 100_000_000)
    let (client, states, _) = makeClient(port: port)
    client.connect()
    #expect(await eventually { states.value.last == .closed(.refused("127.0.0.1", port)) })
}

@Test func remoteCloseIsReported() async throws {
    let server = try LoopbackServer { conn in
        send(conn, Array("Bye".utf8))
        conn.queue?.asyncAfter(deadline: .now() + 0.2) { conn.cancel() }
    }
    defer { server.stop() }
    let (client, states, data) = makeClient(port: await server.port())
    client.connect()
    #expect(await eventually { states.value.last == .closed(.closedByRemote) })
    #expect(data.value == Array("Bye".utf8))
}

@Test func unknownHostIsReported() async {
    let (client, states, _) = makeClient(port: 23, host: "no-such-host.invalid")
    client.connect()
    #expect(await eventually(16) { states.value.last == .closed(.hostNotFound("no-such-host.invalid")) })
}

@Test func connectTimeoutIsReported() async throws {
    // A listener that never accepts would still complete the handshake, so time out a client
    // whose timeout is shorter than the connection takes to report anything: a black hole address.
    let (client, states, _) = makeClient(port: 23, host: "10.255.255.1", timeout: 0.5)
    client.connect()
    #expect(await eventually(5) {
        guard case .closed(let error)? = states.value.last else { return false }
        return error == .timedOut("10.255.255.1") || error == .unreachable("10.255.255.1")
    })
}

@Test func invalidPortIsReported() async {
    let (client, states, _) = makeClient(port: 70000)
    client.connect()
    #expect(await eventually { states.value.last == .closed(.other("70000 is not a valid port number (1 to 65535).")) })
}

@Test func disconnectIsNotAnError() async throws {
    let server = try LoopbackServer { _ in }
    defer { server.stop() }
    let (client, states, _) = makeClient(port: await server.port())
    client.connect()
    #expect(await eventually { states.value.contains(.connected) })
    client.disconnect()
    #expect(await eventually { states.value.last == .closed(nil) })
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(states.value.last == .closed(nil))
}
