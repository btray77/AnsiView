import Foundation
import Testing
@testable import AnsiCore

@Suite struct GlossaryTests {
    @Test func everyTermHasExactlyOneEntry() {
        let terms = Glossary.entries.map(\.term)
        #expect(Set(terms) == Set(GlossaryTerm.allCases))
        #expect(terms.count == GlossaryTerm.allCases.count)
        #expect(Glossary.entries.count >= 60)
        for term in GlossaryTerm.allCases { #expect(Glossary.entry(term).term == term) }
    }

    @Test func relatedTermsAreOthersAndUnique() {
        for entry in Glossary.entries {
            #expect(!entry.related.isEmpty, "\(entry.term) has no related terms")
            #expect(!entry.related.contains(entry.term), "\(entry.term) relates to itself")
            #expect(Set(entry.related).count == entry.related.count, "\(entry.term) repeats a related term")
        }
    }

    /// The owner's list: each must be found by searching for it.
    @Test func requiredTermsArePresent() {
        let wanted = [
            "iCE colours", "blink", "SAUCE", "CP437", "baud", "emulated speed", "ANSI music", "BANSI", "TheDraw", "TDF",
            "FIGlet", "XBin", "ADF", "IDF", "PCB", "AVT", "RIP", "BIN", "ASC", "DIZ", "NFO", "16colo.rs", "art pack",
            "half blocks", "shading blocks", "line drawing", "letter spacing", "9 dot", "aspect ratio", "palette",
            "layers", "frames", "animation", "CR padding", "XMODEM", "YMODEM", "ZMODEM", "Kermit", "telnet", "SSH",
            "legacy SSH", "TLS", "host key", "fingerprint", "dialing directory", "terminal type", "ANSI-BBS", "VT100",
            "VT52", "Avatar", "PETSCII", "ATASCII", "Viewdata", "Mode 7", "Apple II", "Amiga", "RIPscrip", "IEMSI",
            "display codes", "pipe codes", "MCI codes", "BBS package", "sixel", "door game",
        ]
        for word in wanted {
            #expect(!Glossary.search(word).isEmpty, "no entry for \(word)")
        }
    }

    @Test func noEmDashesAnywhere() {
        let dash = "\u{2014}"
        for entry in Glossary.entries {
            for text in [entry.title, entry.hint, entry.explanation, entry.whereInApp ?? ""] + entry.aliases {
                #expect(!text.contains(dash), "\(entry.term): \(text)")
            }
        }
    }

    @Test func hintsAreOneShortLine() {
        for entry in Glossary.entries {
            #expect(!entry.hint.isEmpty && entry.hint.count <= 120, "\(entry.term) hint is \(entry.hint.count) characters")
            #expect(!entry.hint.contains("\n"), "\(entry.term)")
            let sentences = entry.hint.split(whereSeparator: { ".!?".contains($0) })
                .filter { $0.trimmingCharacters(in: .whitespaces).count > 2 }
            #expect(sentences.count <= 1, "\(entry.term) hint has \(sentences.count) sentences")
        }
    }

    @Test func explanationsAreLongerThanHints() {
        for entry in Glossary.entries {
            #expect(entry.explanation.count > entry.hint.count + 40, "\(entry.term)")
            #expect(!entry.title.isEmpty)
        }
    }

    @Test func searchIgnoresCaseAndSpelling() {
        #expect(Glossary.search("ICE colors").first?.term == .iceColours)
        #expect(Glossary.search("ice").first?.term == .iceColours)
        #expect(Glossary.search("  ice ").first?.term == .iceColours)
        #expect(Glossary.search("z-modem").first?.term == .zmodem)
        #expect(Glossary.search("colour palette").contains { $0.term == .palette })
        #expect(Glossary.search("color palette").contains { $0.term == .palette })
    }

    @Test func titleMatchesRankFirst() {
        #expect(Glossary.search("sauce").first?.term == .sauce)
        #expect(Glossary.search("telnet").first?.term == .telnet)
        // "blink" appears in the iCE explanation too, but the blink entry comes first.
        #expect(Glossary.search("blink").first?.term == .blink)
        #expect(Glossary.search("blink").contains { $0.term == .iceColours })
    }

    @Test func emptySearchListsEverythingAlphabetically() {
        let all = Glossary.search("")
        #expect(all.count == Glossary.entries.count)
        #expect(all.map(\.title) == Glossary.sorted.map(\.title))
        #expect(Glossary.search("   ").count == Glossary.entries.count)
    }

    @Test func searchWithNoMatchIsEmpty() {
        #expect(Glossary.search("qwertyuiopzzz").isEmpty)
    }

    @Test func sortedIsAlphabeticalIgnoringCase() {
        let titles = Glossary.sorted.map(\.title)
        #expect(titles == titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func termsRoundTripThroughTheirIDs() {
        for term in GlossaryTerm.allCases { #expect(GlossaryTerm(rawValue: term.rawValue) == term) }
        #expect(Glossary.entry(.iceColours).id == "iceColours")
    }
}
