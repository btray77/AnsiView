import Foundation
import Testing
@testable import AnsiCore

/// Artist and group pages (item 44). The 16colo.rs fixtures are original, in the shape of the live
/// API checked on 2026-10-30 (`/v1/artist/jed`, `/v1/group/legend?packs=true`, `/v1/group/?filter=acid`).
struct ArtistDirectoryTests {
    func record(author: String, group: String, date: String? = nil) -> IndexRecord {
        var r = LibraryScanner.record(data: Data("X".utf8), path: "/a.ans", entry: nil, size: 1, modified: .distantPast,
                                      now: .distantPast)
        r.author = author
        r.group = group
        r.date = date
        return r
    }

    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/16colors"))
        return try Data(contentsOf: url)
    }

    @Test func artistsMergeCaseAndSpacing() {
        let records = [record(author: "Lord Jazz", group: "ACiD"), record(author: "lord  jazz ", group: "ACiD"),
                       record(author: "Trip", group: "iCE")]
        let artists = ArtistDirectory.artists(records)
        #expect(artists.map(\.name) == ["Lord Jazz", "Trip"])
        #expect(artists[0].pieces == [0, 1])
        #expect(artists[0].key == "lord jazz")
        #expect(ArtistDirectory.key("  ") == nil)
    }

    @Test func mostCommonSpellingWins() {
        let records = [record(author: "TRIP", group: ""), record(author: "Trip", group: ""), record(author: "Trip", group: "")]
        #expect(ArtistDirectory.artists(records).first?.name == "Trip")
    }

    @Test func yearsAndRelatedGroups() {
        let records = [record(author: "Trip", group: "iCE", date: "19960101"), record(author: "Trip", group: "ACiD", date: "19940505"),
                       record(author: "Trip", group: "ice", date: "19960707"), record(author: "Nail", group: "iCE")]
        let trip = ArtistDirectory.artists(records).first { $0.key == "trip" }
        #expect(trip?.years == [1994, 1996])
        #expect(trip?.related == ["ACiD", "iCE"])
        let ice = ArtistDirectory.groups(records).first { $0.key == "ice" }
        #expect(ice?.pieces == [0, 2, 3])
        #expect(ice?.related == ["Nail", "Trip"])
    }

    @Test func blankNamesSkipped() {
        #expect(ArtistDirectory.artists([record(author: "", group: "")]).isEmpty)
        #expect(ArtistDirectory.groups([record(author: "x", group: "   ")]).isEmpty)
    }

    @Test func artistAndGroupURLs() {
        #expect(SixteenColors.artistURL("Lord Jazz")?.absoluteString == "https://api.16colo.rs/v1/artist/lord%20jazz")
        #expect(SixteenColors.artistURL("../x") == nil)
        #expect(SixteenColors.artistURL(" ") == nil)
        #expect(SixteenColors.groupSearchURL("ACiD Productions")?.absoluteString
            == "https://api.16colo.rs/v1/group/?filter=acid&pagesize=50")
        #expect(SixteenColors.groupPacksURL(tag: "acid")?.absoluteString == "https://api.16colo.rs/v1/group/acid?packs=true")
    }

    @Test func decodesArtistWorks() throws {
        let packs = try SixteenColors.decodeArtist(fixture("artist-sample"))
        #expect(packs.map(\.name) == ["demo-pack2", "demo-pack3", "demo-pack1"])
        #expect(packs[0].year == 1996)
        #expect(packs[0].group == "other crew")
        #expect(packs[2].files == ["ONE.ANS", "TWO.ANS"])
        #expect(packs[1].group == nil)
    }

    @Test func decodesGroupPacks() throws {
        let packs = try SixteenColors.decodeGroupPacks(fixture("group-sample"))
        #expect(packs.map(\.name) == ["demo03", "demo01", "demo02"])
        #expect(packs.map(\.year) == [1996, 1995, 1995])
    }

    @Test func findsTheGroupTag() throws {
        let matches = try SixteenColors.decodeGroupSearch(fixture("group-search-sample"))
        #expect(matches.map(\.tag) == ["demo", "demo crew", "nodemo"])
        #expect(matches[0].longName == "Demo Productions")
        #expect(SixteenColors.bestGroup(matches, for: "Demo Productions")?.tag == "demo")
        #expect(SixteenColors.bestGroup(matches, for: "DEMO CREW")?.tag == "demo crew")
        #expect(SixteenColors.bestGroup(matches, for: "Something Else") == nil)
    }

    @Test func emptyResultsDecodeEmpty() throws {
        #expect(try SixteenColors.decodeArtist(Data()).isEmpty)
        #expect(try SixteenColors.decodeArtist(Data(#"{"page":{},"results":[]}"#.utf8)).isEmpty)
        #expect(try SixteenColors.decodeGroupPacks(Data("[]".utf8)).isEmpty)
        #expect(throws: SixteenColors.DecodeError.self) { try SixteenColors.decodeArtist(Data("<html>".utf8)) }
    }
}
