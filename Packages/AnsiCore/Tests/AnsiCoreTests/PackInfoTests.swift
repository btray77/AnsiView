import Testing
@testable import AnsiCore

struct PackInfoTests {
    @Test func dizFirstThenNfos() {
        let names = ["ZED.NFO", "art/one.ans", "file_id.diz", "acid.nfo", "two.ans"]
        #expect(PackInfo.infoFiles(names) == [2, 3, 0])
    }

    @Test func shallowestDizWins() {
        let names = ["sub/deeper/FILE_ID.DIZ", "sub/FILE_ID.DIZ", "x.ans"]
        #expect(PackInfo.infoFiles(names) == [1])
    }

    @Test func noInfoFiles() {
        #expect(PackInfo.infoFiles(["a.ans", "b.diz", "nfo.ans"]).isEmpty)
        #expect(PackInfo.infoFiles([]).isEmpty)
    }

    @Test func visibleFirstThenRest() {
        var order = WorkOrder(count: 6)
        order.prioritize([3, 4])
        var taken: [Int] = []
        while let next = order.next() { taken.append(next) }
        #expect(taken == [3, 4, 0, 1, 2, 5])
    }

    @Test func reprioritizeMidway() {
        var order = WorkOrder(count: 10)
        #expect(order.next() == 0)
        #expect(order.next() == 1)
        order.prioritize([8, 1, 9])
        #expect(order.next() == 8)
        #expect(order.next() == 9)
        #expect(order.next() == 2)
    }

    @Test func finishedNeverRepeats() {
        var order = WorkOrder(count: 3)
        order.finish(1)
        order.prioritize([1, 2, 7, -1])
        #expect(order.next() == 2)
        #expect(order.next() == 0)
        #expect(order.next() == nil)
        #expect(order.remaining == 0)
    }
}
