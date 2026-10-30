import Foundation
import Testing
@testable import AnsiCore

@Test func webSocketURLBuilding() {
    #expect(WebSocketEndpoint.url(host: "bbs.example.com", port: 80, path: "/", secure: false)?.absoluteString
            == "ws://bbs.example.com/")
    #expect(WebSocketEndpoint.url(host: "bbs.example.com", port: 443, path: "/ws", secure: true)?.absoluteString
            == "wss://bbs.example.com/ws")
    #expect(WebSocketEndpoint.url(host: "bbs.example.com", port: 1123, path: "ws", secure: false)?.absoluteString
            == "ws://bbs.example.com:1123/ws")
    #expect(WebSocketEndpoint.url(host: "::1", port: 8080, path: "/", secure: false)?.absoluteString
            == "ws://[::1]:8080/")
    #expect(WebSocketEndpoint.url(host: "bbs.example.com", port: 80, path: "", secure: false)?.absoluteString
            == "ws://bbs.example.com/")
    #expect(WebSocketEndpoint.url(host: "bbs.example.com", port: 80, path: "/a?node=2", secure: false)?.absoluteString
            == "ws://bbs.example.com/a?node=2")
    #expect(WebSocketEndpoint.url(host: "bad host", port: 80, path: "/", secure: false) == nil)
}

@Test func webSocketSubprotocolParsing() {
    #expect(TransportSettings.subprotocols("") == [])
    #expect(TransportSettings.subprotocols("telnet") == ["telnet"])
    #expect(TransportSettings.subprotocols(" binary , telnet,") == ["binary", "telnet"])
}

@Test func webSocketTextFramesBecomeUTF8() {
    #expect(WebSocketTransport.bytes(of: .data(Data([0, 255, 27]))) == [0, 255, 27])
    #expect(WebSocketTransport.bytes(of: .string("Hé")) == [72, 0xC3, 0xA9])
}

@Test func webSocketErrorMapping() {
    let host = "bbs.example.com"
    func map(_ code: URLError.Code, status: Int? = nil, connected: Bool = false) -> BBSConnectionError {
        let response = status.map {
            HTTPURLResponse(url: URL(string: "ws://bbs.example.com/")!, statusCode: $0, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
        return WebSocketTransport.map(URLError(code), response: response, host: host, port: 80, connected: connected)
    }
    #expect(map(.cannotFindHost) == .hostNotFound(host))
    #expect(map(.dnsLookupFailed) == .hostNotFound(host))
    #expect(map(.cannotConnectToHost) == .refused(host, 80))
    #expect(map(.timedOut) == .timedOut(host))
    #expect(map(.notConnectedToInternet) == .unreachable(host))
    #expect(map(.badServerResponse, status: 404) == .upgradeRefused(host, 404))
    #expect(map(.badServerResponse) == .upgradeRefused(host, nil))
    #expect(map(.networkConnectionLost, connected: true) == .closedByRemote)
    if case .tls(let h, let detail) = map(.serverCertificateUntrusted) {
        #expect(h == host)
        #expect(detail.contains("certificate"))
    } else {
        Issue.record("certificate errors are TLS errors")
    }
    if case .tls = map(.secureConnectionFailed) {} else { Issue.record("secureConnectionFailed is a TLS error") }
    if case .tls = map(.serverCertificateHasBadDate) {} else { Issue.record("bad date is a TLS error") }
    // Plain words, no codes.
    #expect(BBSConnectionError.upgradeRefused(host, 404).message.contains("HTTP status 404"))
}
