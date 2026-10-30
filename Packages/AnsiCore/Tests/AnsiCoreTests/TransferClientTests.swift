import Foundation
import Network
import Testing
@testable import AnsiCore

/// A transport whose writes complete only when the test says so (backpressure).
final class SlowTransport: BBSTransport, @unchecked Sendable {
    var events: ((TransportEvent) -> Void)?
    let written = Box<[[UInt8]]>([])
    let pending = Box<[() -> Void]>([])
    let opened = Box(false)
    func open() { opened.value = true }
    func write(_ bytes: [UInt8]) { written.update { $0.append(bytes) } }
    func write(_ bytes: [UInt8], completion: @escaping () -> Void) {
        written.update { $0.append(bytes) }
        pending.update { $0.append(completion) }
    }
    func resize(columns: Int, rows: Int) {}
    func close() {}
}

private func connectedClient(_ settings: TransportSettings, _ transport: BBSTransport & AnyObject, queue: DispatchQueue,
                             opened: Box<Bool>) async -> BBSClient {
    let client = BBSClient(host: "h", port: 1, settings: settings, columns: 80, rows: 25, connectTimeout: testConnectTimeout, queue: queue, transport: transport)
    let up = Box(false)
    client.onState = { s in if s == .connected { up.value = true } }
    client.connect()
    _ = await eventually { opened.value }
    queue.sync { transport.events?(.opened) }
    _ = await eventually { up.value }
    return client
}

@Test func sendTransferEncodesTelnetAndCompletes() async {
    let slow = SlowTransport()
    let queue = DispatchQueue(label: "test.slow")
    let client = await connectedClient(TransportSettings(mode: .telnet), slow, queue: queue, opened: slow.opened)
    queue.sync { slow.written.value = [] }
    let done = Box(0)
    client.sendTransfer([1, 255, 2]) { done.update { $0 += 1 } }
    #expect(await eventually { slow.written.value == [[1, 255, 255, 2]] })
    // Not complete until the transport says the bytes went out.
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(done.value == 0)
    queue.sync { slow.pending.value.first?() }
    #expect(await eventually { done.value == 1 })
}

@Test func requestBinarySendsWillDo() async {
    let slow = SlowTransport()
    let queue = DispatchQueue(label: "test.binary")
    let client = await connectedClient(TransportSettings(mode: .telnet), slow, queue: queue, opened: slow.opened)
    queue.sync { slow.written.value = [] }
    client.requestBinary()
    client.requestBinary()
    #expect(await eventually { slow.written.value.flatMap { $0 } == [255, 251, 0, 255, 253, 0] })
    #expect(!client.isByteClean)
    queue.sync { slow.events?(.bytes([255, 253, 0, 255, 251, 0])) }
    #expect(await eventually { client.isByteClean })
}

@Test func rawSendTransferPassesBytes() async {
    let slow = SlowTransport()
    let queue = DispatchQueue(label: "test.rawxfer")
    let client = await connectedClient(TransportSettings(mode: .raw), slow, queue: queue, opened: slow.opened)
    let done = Box(false)
    client.requestBinary()
    client.sendTransfer([255, 13, 0]) { done.value = true }
    #expect(await eventually { slow.written.value == [[255, 13, 0]] })
    queue.sync { slow.pending.value.first?() }
    #expect(await eventually { done.value })
}

@Test func defaultWriteCompletionIsCalled() async {
    // A transport without its own completion (FakeTransport) still completes.
    let fake = FakeTransport()
    let queue = DispatchQueue(label: "test.defaultcompletion")
    let client = await connectedClient(TransportSettings(mode: .ssh), fake, queue: queue, opened: fake.opened)
    let done = Box(false)
    client.sendTransfer([7]) { done.value = true }
    #expect(await eventually { done.value && fake.written.value == [7] })
}

@Test func sendTransferWhenClosedStillCompletes() async {
    let slow = SlowTransport()
    let queue = DispatchQueue(label: "test.closedxfer")
    let client = BBSClient(host: "h", port: 1, settings: TransportSettings(mode: .raw), columns: 80, rows: 25, connectTimeout: testConnectTimeout, queue: queue,
                           transport: slow)
    let done = Box(false)
    client.sendTransfer([1]) { done.value = true }
    #expect(await eventually { done.value })
    #expect(slow.written.value.isEmpty)
}

@Test func tcpWriteCompletes() async throws {
    let server = try LoopbackServer { _ in }
    let port = await server.port()
    let queue = DispatchQueue(label: "test.tcpxfer")
    let tcp = TCPTransport(host: "127.0.0.1", port: port, connectTimeout: 5, queue: queue)
    let opened = Box(false)
    tcp.events = { e in if e == .opened { opened.value = true } }
    queue.sync { tcp.open() }
    #expect(await eventually { opened.value })
    let done = Box(false)
    let payload = [UInt8](repeating: 0x5A, count: 100_000)
    queue.sync { tcp.write(payload) { done.value = true } }
    #expect(await eventually { done.value })
    #expect(await eventually { server.received.value.count == payload.count })
    queue.sync { tcp.close() }
    server.stop()
}
