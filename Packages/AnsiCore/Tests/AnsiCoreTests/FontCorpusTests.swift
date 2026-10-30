import Foundation
import Testing
@testable import AnsiCore

/// Runs over a folder of real font files when ANSIVIEW_FONT_CORPUS names one (the fonts are
/// third party and never committed). Without it the test does nothing.
struct FontCorpusTests {
    @Test func corpusParsesRoundTripsAndRenders() throws {
        guard let folder = ProcessInfo.processInfo.environment["ANSIVIEW_FONT_CORPUS"] else { return }
        let urls = (FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { FontLoader.extensions.contains($0.pathExtension.lowercased()) }
        var files = 0, failedFiles: [String] = [], fonts = 0, roundTripped = 0, warnings = 0
        var byType: [String: Int] = [:]
        let start = Date()
        for url in urls {
            files += 1
            let data = try Data(contentsOf: url)
            if TDFFile.isTDF(data) {
                guard let result = try? TDFFile.parse(data) else { failedFiles.append(url.lastPathComponent); continue }
                warnings += result.warnings.count
                for font in result.fonts {
                    fonts += 1
                    byType[font.type.label, default: 0] += 1
                    if let again = try? TDFFile.parse(TDFFile.write([font])).fonts, again == [font] { roundTripped += 1 }
                    _ = TextArt.render("The Quick Brown Fox 123!", font: .tdf(font), options: TextArtOptions())
                }
            } else if let font = try? FIGletFont.parse(data, name: url.lastPathComponent) {
                fonts += 1
                roundTripped += 1
                byType["FIGlet", default: 0] += 1
                _ = TextArt.render("The Quick Brown Fox 123!", font: .figlet(font), options: TextArtOptions())
            } else {
                failedFiles.append(url.lastPathComponent)
            }
        }
        print("CORPUS files=\(files) failed=\(failedFiles.count) \(failedFiles.prefix(10)) fonts=\(fonts) roundtrip=\(roundTripped) warnings=\(warnings) types=\(byType.sorted { $0.key < $1.key }) seconds=\(String(format: "%.2f", Date().timeIntervalSince(start)))")
        #expect(roundTripped == fonts)
    }
}
