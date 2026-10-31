import Foundation
import Testing
@testable import AnsiCore

private func record(_ path: String, hash: String) -> IndexRecord {
    IndexRecord(path: path, entry: nil, size: 1, modified: Date(timeIntervalSince1970: 0), byteHash: hash, cellHash: nil,
                title: "", author: "", group: "", comments: "", date: nil, format: "ANSI", columns: 80, rows: 25,
                text: "", added: Date(timeIntervalSince1970: 0))
}

@Suite struct ArtOfTheDayTests {
    let records = (0..<10).map { record("/art/piece\($0).ans", hash: String(repeating: "\($0)", count: 64)) }

    @Test func dayKeyIsLocalCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let date = ISO8601DateFormatter().date(from: "2026-10-31T03:00:00Z")!  // 22:00 on the 30th in Chicago
        #expect(ArtOfTheDay.dayKey(date, calendar: calendar) == "2026-10-30")
    }

    @Test func sameDaySamePick() {
        let a = ArtOfTheDay.pick(records, notes: [:], day: "2026-10-30")
        let b = ArtOfTheDay.pick(records.reversed(), notes: [:], day: "2026-10-30")
        #expect(a != nil && a == b)
    }

    @Test func picksVaryOverAMonth() {
        let picks = (1...30).compactMap { ArtOfTheDay.pick(records, notes: [:], day: String(format: "2026-11-%02d", $0))?.path }
        #expect(picks.count == 30)
        #expect(Set(picks).count >= 5)
    }

    @Test func favouritesAndHighRatingsFirst() {
        var favourite = PieceNotes()
        favourite.favourite = true
        var fourStars = PieceNotes()
        fourStars.rating = 4
        var twoStars = PieceNotes()
        twoStars.rating = 2
        let notes = [records[3].identity: favourite, records[7].identity: fourStars, records[1].identity: twoStars]
        let picks = Set((1...30).compactMap { ArtOfTheDay.pick(records, notes: notes, day: "2026-12-\($0)")?.path })
        #expect(picks == [records[3].path, records[7].path])
    }

    @Test func emptyGivesNil() {
        #expect(ArtOfTheDay.pick([], notes: [:], day: "2026-10-30") == nil)
        #expect(ArtOfTheDay.choose(from: [String](), day: "2026-10-30", salt: "x") == nil)
    }

    @Test func chooseIsStableAndSalted() {
        let names = (0..<50).map { "pack\($0)" }
        let first = ArtOfTheDay.choose(from: names, day: "2026-10-30", salt: "pack")
        #expect(first == ArtOfTheDay.choose(from: names, day: "2026-10-30", salt: "pack"))
        let salts = Set(["a", "b", "c", "d", "e", "f"].compactMap { ArtOfTheDay.choose(from: names, day: "2026-10-30", salt: $0) })
        #expect(salts.count > 1)
    }

    @Test func fnvKnownValue() {
        // FNV-1a 64 bit of "a" (published test vector).
        #expect(ArtOfTheDay.fnv1a("a") == 0xaf63dc4c8601ec8c)
    }
}
