import Testing
@testable import AnsiCore

private let IAC: UInt8 = 255, DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252, WILL: UInt8 = 251
private let SB: UInt8 = 250, SE: UInt8 = 240

private func session(started: Bool = true) -> TelnetSession {
    var s = TelnetSession(columns: 80, rows: 25)
    if started { _ = s.start() }
    return s
}

@Test func startOffers() {
    var s = TelnetSession(columns: 80, rows: 25)
    #expect(s.start() == [IAC, DO, 3, IAC, WILL, 24, IAC, WILL, 31])
}

@Test func acceptsEchoSGABinaryFromServer() {
    var s = session(started: false)
    #expect(s.receive([IAC, WILL, 1]).reply == [IAC, DO, 1])
    #expect(s.receive([IAC, WILL, 3]).reply == [IAC, DO, 3])
    #expect(s.receive([IAC, WILL, 0]).reply == [IAC, DO, 0])
    #expect(s.remoteEnabled(.echo))
    #expect(s.remoteEnabled(.suppressGoAhead))
    #expect(s.remoteEnabled(.binary))
}

@Test func acceptsOurSideOptions() {
    var s = session(started: false)
    #expect(s.receive([IAC, DO, 0]).reply == [IAC, WILL, 0])
    #expect(s.receive([IAC, DO, 3]).reply == [IAC, WILL, 3])
    #expect(s.localEnabled(.binary))
    #expect(s.localEnabled(.suppressGoAhead))
}

@Test func refusesEverythingElse() {
    var s = session(started: false)
    #expect(s.receive([IAC, WILL, 5]).reply == [IAC, DONT, 5])
    #expect(s.receive([IAC, DO, 1]).reply == [IAC, WONT, 1])
    #expect(s.receive([IAC, DO, 39]).reply == [IAC, WONT, 39])
    #expect(s.receive([IAC, WILL, 24]).reply == [IAC, DONT, 24])
    #expect(!s.localEnabled(.echo))
}

@Test func answersToOurRequestsGetNoReply() {
    var s = session()
    #expect(s.receive([IAC, WILL, 3, IAC, DO, 24]).reply.isEmpty)
    #expect(s.remoteEnabled(.suppressGoAhead))
    #expect(s.localEnabled(.terminalType))
}

@Test func refusalOfOurRequestGetsNoReply() {
    var s = session()
    #expect(s.receive([IAC, DONT, 31, IAC, WONT, 3]).reply.isEmpty)
    #expect(!s.localEnabled(.naws))
    #expect(!s.remoteEnabled(.suppressGoAhead))
}

@Test func nawsSentWhenEnabled() {
    var s = session()
    #expect(s.receive([IAC, DO, 31]).reply == [IAC, SB, 31, 0, 80, 0, 25, IAC, SE])
    #expect(s.resize(columns: 255, rows: 50) == [IAC, SB, 31, 0, 255, 255, 0, 50, IAC, SE])
}

@Test func nawsUnaskedIsAcceptedAndSent() {
    var s = session(started: false)
    #expect(s.receive([IAC, DO, 31]).reply == [IAC, WILL, 31, IAC, SB, 31, 0, 80, 0, 25, IAC, SE])
}

@Test func nawsNotSentWhileDisabled() {
    var s = session()
    #expect(s.resize(columns: 132, rows: 50).isEmpty)
}

@Test func terminalTypeCycles() {
    var s = session()
    _ = s.receive([IAC, DO, 24])
    let send: [UInt8] = [IAC, SB, 24, 1, IAC, SE]
    func isReply(_ name: String) -> [UInt8] { [IAC, SB, 24, 0] + Array(name.utf8) + [IAC, SE] }
    #expect(s.receive(send).reply == isReply("ANSI"))
    #expect(s.receive(send).reply == isReply("ANSI-BBS"))
    #expect(s.receive(send).reply == isReply("VT100"))
    #expect(s.receive(send).reply == isReply("VT100"))
}

@Test func terminalTypeSendWhileDisabledIgnored() {
    var s = session(started: false)
    #expect(s.receive([IAC, SB, 24, 1, IAC, SE]).reply.isEmpty)
}

@Test func iacIacIsData() {
    var s = session()
    #expect(s.receive([65, IAC, IAC, 66]).data == [65, 255, 66])
}

@Test func crNulStripped() {
    var s = session()
    #expect(s.receive([13, 0, 10]).data == [13, 10])
    _ = s.receive([IAC, WILL, 0])
    #expect(s.receive([13, 0, 10]).data == [13, 0, 10])
}

@Test func encodeEscapesAndCrNul() {
    var s = session()
    #expect(s.encode([255, 13, 65, 13, 10]) == [255, 255, 13, 0, 65, 13, 10])
    #expect(s.encode([13]) == [13, 0])
    _ = s.receive([IAC, DO, 0])
    #expect(s.encode([255, 13, 65, 13, 10]) == [255, 255, 13, 65, 13, 10])
}

@Test func noReplyLoops() {
    var s = session(started: false)
    #expect(s.receive([IAC, WILL, 1]).reply == [IAC, DO, 1])
    #expect(s.receive([IAC, WILL, 1]).reply.isEmpty)
    #expect(s.receive([IAC, DO, 0, IAC, DONT, 0, IAC, DO, 0]).reply
        == [IAC, WILL, 0, IAC, WONT, 0, IAC, WILL, 0])
    #expect(s.receive([IAC, WONT, 5]).reply.isEmpty)
    #expect(s.receive([IAC, WONT, 1]).reply == [IAC, DONT, 1])
    #expect(s.receive([IAC, WONT, 1]).reply.isEmpty)
    #expect(!s.remoteEnabled(.echo))
}

@Test func otherCommandsDropped() {
    var s = session()
    #expect(s.receive([65, IAC, 241, 66, IAC, 249, 67]).data == [65, 66, 67])
}

@Test func splitAtEveryByteMatches() {
    let fixture: [UInt8] = [72, IAC, IAC, IAC, WILL, 1, 105, IAC, DO, 24, IAC, SB, 24, 1, IAC, SE,
                            13, 0, 33, IAC, DO, 31, IAC, SB, 99, 7, IAC, IAC, IAC, SE, 10, IAC, 241, 90]
    var whole = session()
    let expected = whole.receive(fixture)
    for split in 0...fixture.count {
        var s = session()
        let a = s.receive(Array(fixture[..<split]))
        let b = s.receive(Array(fixture[split...]))
        #expect(a.data + b.data == expected.data, "split \(split)")
        #expect(a.reply + b.reply == expected.reply, "split \(split)")
    }
    // Byte at a time too.
    var s = session()
    var data: [UInt8] = [], reply: [UInt8] = []
    for byte in fixture {
        let r = s.receive([byte])
        data += r.data
        reply += r.reply
    }
    #expect(data == expected.data)
    #expect(reply == expected.reply)
    #expect(expected.data == [72, 255, 105, 13, 33, 10, 90])
}

@Test func subnegotiationIsBounded() {
    var s = session()
    let r = s.receive([IAC, SB, 24] + [UInt8](repeating: 65, count: 10_000) + [IAC, SE, 66])
    #expect(r.data == [66])
    #expect(r.reply.isEmpty)
}
