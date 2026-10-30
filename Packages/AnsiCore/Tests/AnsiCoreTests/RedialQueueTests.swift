import Foundation
import Testing
@testable import AnsiCore

private let a = UUID(), b = UUID(), c = UUID()

@Test func singleEntryRetriesPassesTimes() {
    var q = RedialQueue(ids: [a], passes: 3, delay: 10)
    #expect(q.start() == .dial(a))
    #expect(q.pass == 1 && q.position == 0)
    #expect(q.failed(.refused) == .wait(10, next: a))
    #expect(q.delayElapsed() == .dial(a))
    #expect(q.pass == 2)
    #expect(q.failed(.busy) == .wait(10, next: a))
    #expect(q.delayElapsed() == .dial(a))
    #expect(q.pass == 3)
    #expect(q.failed(.timedOut) == .exhausted)
    #expect(q.state == .exhausted)
    #expect(q.lastOutcome == .timedOut)
}

@Test func failureMovesToNextAndWraps() {
    var q = RedialQueue(ids: [a, b, c], passes: 2, delay: 5)
    #expect(q.start() == .dial(a))
    #expect(q.failed(.busy) == .wait(5, next: b))
    #expect(q.delayElapsed() == .dial(b))
    #expect(q.pass == 1 && q.position == 1)
    #expect(q.failed(.refused) == .wait(5, next: c))
    #expect(q.delayElapsed() == .dial(c))
    #expect(q.failed(.notFound) == .wait(5, next: a))
    #expect(q.delayElapsed() == .dial(a))
    #expect(q.pass == 2 && q.position == 0)
    _ = q.failed(.busy); _ = q.delayElapsed()
    _ = q.failed(.busy); _ = q.delayElapsed()
    #expect(q.failed(.busy) == .exhausted)
}

@Test func connectEndsQueue() {
    var q = RedialQueue(ids: [a, b], passes: 3, delay: 5)
    _ = q.start()
    _ = q.failed(.busy)
    _ = q.delayElapsed()
    q.connected()
    #expect(q.state == .connected(b))
    // Late events after the end are ignored.
    #expect(q.failed(.refused) == RedialQueue.Step.none)
    #expect(q.delayElapsed() == RedialQueue.Step.none)
}

@Test func busyAfterConnectResumes() {
    var q = RedialQueue(ids: [a, b], passes: 1, delay: 5)
    _ = q.start()
    q.connected()
    // The BBS answered, then said all nodes are busy: the queue goes on.
    #expect(q.busyAfterConnect() == .wait(5, next: b))
    #expect(q.delayElapsed() == .dial(b))
    #expect(q.busyAfterConnect() == RedialQueue.Step.none)
    q.connected()
    #expect(q.busyAfterConnect() == .exhausted)
}

@Test func stopAnywhere() {
    var q = RedialQueue(ids: [a, b], passes: 3, delay: 5)
    q.stop()
    #expect(q.state == .stopped)
    #expect(q.start() == RedialQueue.Step.none)
    var r = RedialQueue(ids: [a, b], passes: 3, delay: 5)
    _ = r.start(); _ = r.failed(.busy)
    r.stop()
    #expect(r.state == .stopped)
    #expect(r.delayElapsed() == RedialQueue.Step.none)
}

@Test func dialNowSkipsWait() {
    var q = RedialQueue(ids: [a, b], passes: 3, delay: 600)
    _ = q.start()
    _ = q.failed(.busy)
    #expect(q.state == .waiting(next: b))
    #expect(q.delayElapsed() == .dial(b))
}

@Test func skipMovesOnWithoutWaiting() {
    var q = RedialQueue(ids: [a, b], passes: 1, delay: 30)
    _ = q.start()
    #expect(q.skip() == .dial(b))
    #expect(q.skip() == .exhausted)
}

@Test func emptyQueueAndClamps() {
    var q = RedialQueue(ids: [], passes: 3, delay: 5)
    #expect(q.start() == .exhausted)
    let r = RedialQueue(ids: [a], passes: 0, delay: -4)
    #expect(r.passes == 1 && r.delay == 0)
    let s = RedialQueue(ids: [a], passes: 500, delay: 9999)
    #expect(s.passes == RedialQueue.passRange.upperBound && s.delay == RedialQueue.delayRange.upperBound)
}

@Test func outcomeFromConnectionError() {
    #expect(DialOutcome(.refused("h", 23)) == .refused)
    #expect(DialOutcome(.hostNotFound("h")) == .notFound)
    #expect(DialOutcome(.timedOut("h")) == .timedOut)
    #expect(DialOutcome(.closedByRemote) == .failed("The BBS closed the connection."))
    #expect(DialOutcome.busy.label == "Busy")
}
