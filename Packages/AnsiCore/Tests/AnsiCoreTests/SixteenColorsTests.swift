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
        #expect(SixteenColors.cacheName(for: "a/../b.ans") == "a/b.ans")
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
        #expect(SixteenColors.cacheName(for: "SUB/A.ANS") == "SUB/A.ANS")
    }

    /// Same file name in two folders of a pack: two cache files (review finding).
    @Test func subfoldersDoNotCollide() {
        #expect(SixteenColors.cacheName(for: "DIR1/LOGO.ANS") == "DIR1/LOGO.ANS")
        #expect(SixteenColors.cacheName(for: "DIR2/LOGO.ANS") == "DIR2/LOGO.ANS")
        #expect(SixteenColors.cacheName(for: "DIR1/.x/LOGO.CIP") == "DIR1/x/LOGO.CIP.ans")
    }

    @Test func packCacheName() {
        #expect(SixteenColors.packCacheName("0196ciph") == "0196ciph.zip")
        #expect(SixteenColors.packCacheName("!1madoom") == "!1madoom.zip")
        #expect(SixteenColors.packCacheName("../x") == "x.zip")
        #expect(SixteenColors.packCacheName("..") == nil)
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
        spacing.started(at: 100)
        #expect(spacing.delay(now: 100.25) == 0.75)
        // A waiter that gives up (cancelled) books nothing: the next one still waits only 0.5 s.
        #expect(spacing.delay(now: 100.5) == 0.5)
        spacing.started(at: 101)
        #expect(spacing.delay(now: 101.5) == 0.5)
        #expect(spacing.delay(now: 200) == 0)
    }

    @Test func userAgent() {
        #expect(SixteenColors.userAgent(version: "2.0.0", build: "45")
                == "AnsiView/2.0.0 (build 45; macOS; +https://github.com/btray77/AnsiView)")
    }

    // MARK: Previews (items 35 to 37)

    @Test func imageURLs() {
        #expect(SixteenColors.thumbnailURL(pack: "0196ciph", file: "0196-MEM.CIP")?.absoluteString
                == "https://16colo.rs/pack/0196ciph/tn/0196-MEM.CIP.png")
        #expect(SixteenColors.fullImageURL(pack: "0196ciph", file: "0196-MEM.CIP")?.absoluteString
                == "https://16colo.rs/pack/0196ciph/x1/0196-MEM.CIP.png")
        #expect(SixteenColors.thumbnailURL(pack: "p", file: "SUB DIR/A#1.ANS")?.absoluteString
                == "https://16colo.rs/pack/p/tn/SUB%20DIR/A%231.ANS.png")
        #expect(SixteenColors.thumbnailURL(pack: "p", file: "../x") == nil)
        #expect(SixteenColors.fullImageURL(pack: "..", file: "x") == nil)
    }

    @Test func decodesImagesAndCover() throws {
        let pack = try SixteenColors.decodePack(fixture("pack-0196ciph"), name: "0196ciph")
        let member = try #require(pack.files.first { $0.name == "0196-MEM.CIP" })
        #expect(member.fullImage?.absoluteString == "https://16colo.rs/pack/0196ciph/x1/0196-MEM.CIP.png")
        #expect(pack.fileID == "FILE_ID.DIZ")
        #expect(pack.cover?.name == "FILE_ID.DIZ")

        let json = #"{"results":[{"year":1999,"files":{"B.ANS":{"file":{"tn":{"uri":"/pack/q/tn/B.ANS.png"}}},"A.EXE":{"file":{}}}}]}"#
        let other = try SixteenColors.decodePack(Data(json.utf8), name: "q")
        #expect(other.fileID == nil)
        #expect(other.cover?.name == "B.ANS")
        #expect(other.files.first { $0.name == "A.EXE" }?.fullImage == nil)
    }

    @Test func imageCacheNameRejectsTraversal() throws {
        func name(_ text: String) -> String? { SixteenColors.imageCacheName(for: URL(string: text)!) }
        #expect(name("https://16colo.rs/pack/0196ciph/tn/0196-MEM.CIP.png") == "images/0196ciph/tn/0196-MEM.CIP.png")
        #expect(name("https://16colo.rs/pack/p/x1/SUB%20DIR/A%231.ANS.png") == "images/p/x1/SUB DIR/A#1.ANS.png")
        #expect(name("https://16colo.rs/pack/../x1/../../a.png") == nil)
        #expect(name("https://16colo.rs/pack/p/raw/a.png") == nil)
        #expect(name("https://example.com/pack/p/tn/a.png") == nil)
        #expect(name("https://16colo.rs/pack/p/tn/") == nil)
        for key in [name("https://16colo.rs/pack/p/tn/a/../../../b.png"), name("https://16colo.rs/pack/p/tn/.x.png")] {
            if let key { #expect(!key.split(separator: "/").contains("..")) }
        }
    }

    @Test func apiCacheNames() {
        #expect(SixteenColors.apiCacheName(for: SixteenColors.packsURL(year: 1996, page: 1))
                == "api/year/1996_pagesize=500&page=1.json")
        #expect(SixteenColors.apiCacheName(for: SixteenColors.yearsURL()) == "api/year.json")
        #expect(SixteenColors.apiCacheName(for: SixteenColors.packURL(name: "a b#c?")) == "api/pack/a b#c?.json")
        #expect(SixteenColors.apiCacheName(for: SixteenColors.packURL(name: "..")).contains("..") == false)
        #expect(SixteenColors.fileCacheName(pack: "0196ciph", file: "0196-MEM.CIP") == "files/0196ciph/0196-MEM.CIP.ans")
        #expect(SixteenColors.fileCacheName(pack: "..", file: "x") == nil)
    }

    @Test func pngSignature() {
        #expect(SixteenColors.isPNG(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])))
        #expect(!SixteenColors.isPNG(Data("<!DOCTYPE html>".utf8)))
        #expect(!SixteenColors.isPNG(Data()))
    }
}
