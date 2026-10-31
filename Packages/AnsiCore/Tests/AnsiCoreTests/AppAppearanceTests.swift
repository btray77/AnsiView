import Foundation
import Testing
@testable import AnsiCore

/// Final gaps ruling 9: the four appearances and the Retro colour tokens' contrast.
@Suite struct AppAppearanceTests {
    @Test func wcagContrastMatchesKnownValues() {
        let black = RGB(r: 0, g: 0, b: 0), white = RGB(r: 255, g: 255, b: 255)
        #expect(abs(Contrast.ratio(black, white) - 21) < 0.01)
        #expect(abs(Contrast.ratio(white, white) - 1) < 0.0001)
        // #777777 on white is the classic 4.48:1 just below AA.
        #expect(abs(Contrast.ratio(RGB(r: 0x77, g: 0x77, b: 0x77), white) - 4.48) < 0.01)
        #expect(Contrast.ratio(white, black) == Contrast.ratio(black, white))
    }

    @Test func everyRetroTextPairPassesAA() {
        for pair in RetroTheme.textPairs {
            let ratio = Contrast.ratio(pair.text, pair.background)
            print(String(format: "retro contrast %@ on %@: %.2f", pair.textName, pair.backgroundName, ratio))
            #expect(ratio >= 4.5, "\(pair.textName) on \(pair.backgroundName): \(ratio)")
        }
        #expect(RetroTheme.textPairs.count >= 8)
    }

    @Test func appearancesAndStorage() {
        #expect(AppAppearance.allCases.map(\.label) == ["System", "Light", "Dark", "Retro"])
        let defaults = UserDefaults(suiteName: "appearance.\(UUID().uuidString)")!
        #expect(AppAppearance.current(in: defaults) == .system)
        AppAppearance.set(.retro, in: defaults)
        #expect(AppAppearance.current(in: defaults) == .retro)
        defaults.set("bogus", forKey: AppAppearance.defaultsKey)
        #expect(AppAppearance.current(in: defaults) == .system)
        #expect(AppAppearance.retro.isDarkBased && AppAppearance.dark.isDarkBased && !AppAppearance.light.isDarkBased)
    }

    @Test func theBundledVGAFontFileIsAvailableForLabels() {
        let url = BitmapFont.fontFileURL("IBM VGA")
        #expect(url.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(BitmapFont.fontFileURL("No such font") == nil)
    }
}
