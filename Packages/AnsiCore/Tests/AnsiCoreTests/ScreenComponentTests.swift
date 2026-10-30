import Foundation
import Testing
@testable import AnsiCore

private func text(_ region: CanvasRegion) -> String {
    TextConvert.utf8Text(AnsiScreen(columns: region.width, rows: region.cells))
}

@Test func everyComponentBuildsWithinTheWidth() {
    for component in ScreenComponents.all {
        for width in [40, 78, 130] {
            let region = component.make(ComponentOptions(width: width))
            #expect(region.width > 0 && region.height > 0, "\(component.id)")
            #expect(region.width <= width, "\(component.id) at \(width) is \(region.width) wide")
        }
    }
    #expect(Set(ScreenComponents.all.map(\.id)).count == ScreenComponents.all.count)
    #expect(Set(ScreenComponents.all.map(\.group)) == Set(ComponentGroup.allCases))
}

@Test func frameComponentsUseTheBoxToolStyles() {
    let double = ScreenComponents.component("frame-double")!.make(ComponentOptions(width: 20))
    #expect(double.cells[0][0].code == 0xC9 && double.cells[0][19].code == 0xBB)
    let mixed = ScreenComponents.component("frame-single-double")!.make(ComponentOptions(width: 20))
    #expect(mixed.cells[0][0].code == 0xD6)
    let half = ScreenComponents.component("frame-half")!.make(ComponentOptions(width: 20))
    #expect(half.cells[0][5].code == 0xDF)
}

@Test func statusComponentUsesThePackagesCodes() {
    let mystic = ScreenComponents.component("status-user")!.make(ComponentOptions(width: 78, package: .mystic))
    #expect(text(mystic).contains("|UH") && text(mystic).contains("|TL"))
    let pcb = ScreenComponents.component("status-user")!.make(ComponentOptions(width: 78, package: .pcboard))
    #expect(text(pcb).contains("@USER@") && text(pcb).contains("@TIMELEFT@"))
}

@Test func legendAndLogoComponents() {
    let legend = ScreenComponents.component("legend-hotkeys")!.make(ComponentOptions(width: 78))
    #expect(text(legend).contains("[A] Area"))
    var options = ComponentOptions(width: 78)
    options.text = "HI"
    options.font = .tdf(OriginalFonts.tdfFonts[1])
    let logo = ScreenComponents.component("logo")!.make(options)
    #expect(logo.height == TextArt.render("HI", font: .tdf(OriginalFonts.tdfFonts[1]), options: TextArtOptions()).region.height)
}
