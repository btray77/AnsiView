import Foundation
import Testing
@testable import AnsiCore

/// 16colo.rs API models (item 31). Fixtures are real API responses captured on 2026-10-30,
/// trimmed to a few entries: metadata only, no art.
struct SixteenColorsTests {
    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/16colors"))
        return try Data(contentsOf: url)
    }

    @Test func urls() {
        #expect(SixteenColors.yearsURL().absoluteString == "https://api.16colo.rs/v1/year")
        #expect(SixteenColors.packsURL(year: 1996, page: 2).absoluteString
                == "https://api.16colo.rs/v1/year/1996?pagesize=500&page=2")
        #expect(SixteenColors.packURL(name: "0196ciph").absoluteString == "https://api.16colo.rs/v1/pack/0196ciph")
        #expect(SixteenColors.packURL(name: "a b#c?").absoluteString == "https://api.16colo.rs/v1/pack/a%20b%23c%3F")
        #expect(SixteenColors.rawFileURL(pack: "0196ciph", file: "!WOHH1WH.OWH")?.absoluteString
                == "https://16colo.rs/pack/0196ciph/raw/!WOHH1WH.OWH")
        #expect(SixteenColors.rawFileURL(pack: "p", file: "SUB DIR/A#1.ANS")?.absoluteString
                == "https://16colo.rs/pack/p/raw/SUB%20DIR/A%231.ANS")
    }

    @Test func rejectsTraversalNames() {
        #expect(SixteenColors.rawFileURL(pack: "p", file: "../../etc/passwd") == nil)
        #expect(SixteenColors.rawFileURL(pack: "..", file: "A.ANS") == nil)
        #expect(SixteenColors.rawFileURL(pack: "p", file: "") == nil)
        #expect(SixteenColors.cacheName(for: "../../secret.ans") == "secret.ans")
        #expect(SixteenColors.cacheName(for: "..") == nil)
        #expect(SixteenColors.cacheName(for: ".hidden.ans") == "hidden.ans")
        #expect(SixteenColors.cacheName(for: "a:b.ans") == "a_b.ans")
        #expect(SixteenColors.cacheName(for: "/") == nil)
    }

    @Test func downloadURLs() {
        #expect(SixteenColors.downloadURL("https://16colo.rs/archive/1996/0196ciph.zip")?.absoluteString
                == "https://16colo.rs/archive/1996/0196ciph.zip")
        #expect(SixteenColors.downloadURL("/archive/2001/001-progeny.zip")?.absoluteString
                == "https://16colo.rs/archive/2001/001-progeny.zip")
        #expect(SixteenColors.downloadURL("/archive/1996/!1madoom.zip")?.absoluteString
                == "https://16colo.rs/archive/1996/!1madoom.zip")
        // Only 16colo.rs over https.
        #expect(SixteenColors.downloadURL("https://example.com/x.zip") == nil)
        #expect(SixteenColors.downloadURL("http://16colo.rs/archive/x.zip") == nil)
        #expect(SixteenColors.downloadURL("") == nil)
    }

    @Test func decodesYears() throws {
        let years = try SixteenColors.decodeYears(fixture("years"))
        #expect(years.first == SixteenColors.Year(year: 1990, packs: 5, mags: 2))
        #expect(years.contains(SixteenColors.Year(year: 1996, packs: 844, mags: 215)))
        #expect(years.map(\.year) == years.map(\.year).sorted())
    }

    @Test func decodesPackPage() throws {
        let page = try SixteenColors.decodePackPage(fixture("year-1996"))
        #expect(page.page == 2)
        #expect(page.pages == 282)
        #expect(page.total == 844)
        #expect(page.packs.map(\.name) == ["03adment", "0796rats", "13-solo1"])
        #expect(page.packs[0].year == 1996)
        #expect(page.packs[0].groups == ["adment"])
        #expect(page.packs[0].archive == "03adment.zip")
        #expect(page.packs[0].download?.absoluteString == "https://16colo.rs/archive/1996/03adment.zip")
    }

    @Test func decodesPack() throws {
        let pack = try SixteenColors.decodePack(fixture("pack-0196ciph"), name: "0196ciph")
        #expect(pack.name == "0196ciph")
        #expect(pack.year == 1996)
        #expect(pack.archive == "0196ciph.zip")
        #expect(pack.download?.absoluteString == "https://16colo.rs/archive/1996/0196ciph.zip")
        #expect(pack.files.map(\.name) == ["!WOHH1WH.OWH", "0196-MEM.CIP", "AD_CIPH1.ANS", "FILE_ID.DIZ"])
        let member = try #require(pack.files.first { $0.name == "0196-MEM.CIP" })
        #expect(member.artists == ["adrenalin"])
        #expect(member.thumbnail?.absoluteString == "https://16colo.rs/pack/0196ciph/tn/0196-MEM.CIP.png")
    }

    @Test func decodesMissingOptionalFields() throws {
        let data = Data(#"{"results":[{"year":1999,"files":{"A.ANS":{},"B.ANS":{"file":{}}}}]}"#.utf8)
        let pack = try SixteenColors.decodePack(data, name: "x")
        #expect(pack.files.map(\.name) == ["A.ANS", "B.ANS"])
        #expect(pack.download == nil)
        #expect(pack.files[0].artists.isEmpty)
        let page = try SixteenColors.decodePackPage(Data(#"{"results":[{"name":"p"}]}"#.utf8))
        #expect(page.packs.map(\.name) == ["p"])
        #expect(page.pages == 1)
    }

    @Test func rejectsGarbage() {
        #expect(throws: SixteenColors.DecodeError.self) { try SixteenColors.decodeYears(Data("<html>".utf8)) }
        #expect(throws: SixteenColors.DecodeError.self) { try SixteenColors.decodePackPage(Data("[]".utf8)) }
        #expect(throws: SixteenColors.DecodeError.self) { try SixteenColors.decodePack(Data(#"{"results":[]}"#.utf8), name: "x") }
        #expect(SixteenColors.DecodeError.unreadable.localizedDescription == "16colo.rs sent something AnsiView could not read.")
    }

    @Test func cacheNameAddsAnsExtension() {
        #expect(SixteenColors.cacheName(for: "0196-MEM.CIP") == "0196-MEM.CIP.ans")
        #expect(SixteenColors.cacheName(for: "AD_CIPH1.ANS") == "AD_CIPH1.ANS")
        #expect(SixteenColors.cacheName(for: "FILE_ID.DIZ") == "FILE_ID.DIZ")
        #expect(SixteenColors.cacheName(for: "LOGO.XB") == "LOGO.XB")
        #expect(SixteenColors.cacheName(for: "README") == "README.ans")
        #expect(SixteenColors.cacheName(for: "SUB/A.ANS") == "A.ANS")
    }

    @Test func notViewable() {
        for name in ["SETUP.EXE", "X.COM", "PIC.PNG", "a.gif", "SONG.MOD", "inner.zip", "x.JPG"] {
            #expect(!SixteenColors.isViewable(name), "\(name)")
        }
        for name in ["A.ANS", "0196-MEM.CIP", "FILE_ID.DIZ", "README", "X.TXT", "Y.XB"] {
            #expect(SixteenColors.isViewable(name), "\(name)")
        }
    }

    @Test func requestSpacing() {
        var spacing = RequestSpacing(interval: 1)
        #expect(spacing.delay(now: 100) == 0)
        #expect(spacing.delay(now: 100.25) == 0.75)
        // The next one waits for the one just scheduled at 101.
        #expect(spacing.delay(now: 100.5) == 1.5)
        #expect(spacing.delay(now: 200) == 0)
    }

    @Test func userAgent() {
        #expect(SixteenColors.userAgent(version: "2.0.0", build: "45")
                == "AnsiView/2.0.0 (build 45; macOS; +https://github.com/btray77/AnsiView)")
    }
}
