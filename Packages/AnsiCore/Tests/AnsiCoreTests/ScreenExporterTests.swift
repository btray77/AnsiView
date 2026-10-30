import Foundation
import Testing
@testable import AnsiCore

private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

private func oneLine(_ text: String, fg: Int = 14) -> ArtProject {
    var c = EditCanvas(columns: 80, height: 1)
    for (x, code) in ScreenBuilder.codes(text).enumerated() { c.set(AnsiCell(code: code, fg: Palette.vga[fg]), x: x, y: 0) }
    return ArtProject(layers: [CanvasLayer(name: "Background", canvas: c)])
}

@Test func profileFileNamesFollowEachPackage() {
    #expect(ExportProfile(package: .synchronet).relativePath(slot: .mainMenu, columns: 80) == "text/menu/main.ans")
    #expect(ExportProfile(package: .synchronet).relativePath(slot: .mainMenu, columns: 132) == "text/menu/main.132col.ans")
    var native = ExportProfile(package: .synchronet)
    native.colourCodes = .native
    #expect(native.relativePath(slot: .goodbye, columns: 80) == "text/menu/logoff.msg")
    #expect(ExportProfile(package: .mystic).relativePath(slot: .matrix, columns: 80) == "themes/default/text/prelogon.ans")
    #expect(ExportProfile(package: .mystic).relativePath(slot: .welcome, columns: 132) == "themes/default/text/logon1.c132.ans")
    #expect(ExportProfile(package: .enigma).relativePath(slot: .mainMenu, columns: 80) == "art/themes/mytheme/MMENU.ANS")
    #expect(ExportProfile(package: .renegade).relativePath(slot: .matrix, columns: 80) == "MISC/PRELOGON.ANS")
    #expect(ExportProfile(package: .wwiv).relativePath(slot: .matrix, columns: 80) == "gfiles/welcome.ans")
    // Undocumented slots get a suggestion in the package's folder, 8.3 for DOS packages.
    #expect(ExportProfile(package: .pcboard).relativePath(slot: .bulletinList, columns: 80) == "BULLETIN.ANS")
    #expect(ExportProfile(package: .mystic).relativePath(slot: .doorMenu, columns: 80) == "themes/default/text/doors.ans")
    #expect(ExportProfile(package: .renegade).relativePath(slot: .custom, customName: "My Fancy Screen", columns: 80) == "MISC/MYFANCYS.ANS")
    #expect(ExportProfile(package: .mystic).isDocumented(.matrix))
    #expect(!ExportProfile(package: .pcboard).isDocumented(.welcome))
}

@Test func themeFolderReplacesThePackageDefault() {
    var profile = ExportProfile(package: .enigma)
    profile.themeName = "neon"
    #expect(profile.relativePath(slot: .matrix, columns: 80) == "art/themes/neon/MATRIX.ANS")
    var mystic = ExportProfile(package: .mystic)
    mystic.themeName = "retro"
    #expect(mystic.relativePath(slot: .goodbye, columns: 80) == "themes/retro/text/logoff.ans")
}

@Test func exportedANSIBytesWithAndWithoutSauce() {
    var profile = ExportProfile(package: .mystic)
    profile.sauce = false
    let plain = ScreenExporter.export(oneLine("Hi |UH"), profile: profile, slot: .welcome, date: fixedDate)
    #expect(Array(plain.data) == Array("\u{1B}[0m\u{1B}[1;33mHi |UH\r\n\u{1B}[0m".utf8))
    profile.sauce = true
    let withSauce = ScreenExporter.export(oneLine("Hi |UH"), profile: profile, slot: .welcome, date: fixedDate)
    #expect(withSauce.data.count == plain.data.count + 129)
    #expect(withSauce.data[plain.data.count] == 0x1A)
    #expect(Array(withSauce.data[(plain.data.count + 1)...].prefix(7)) == Array("SAUCE00".utf8))
}

@Test func exportedNativeBytesAndLineEndings() {
    var profile = ExportProfile(package: .mystic)
    profile.colourCodes = .native
    profile.sauce = false
    profile.lineEnding = .lf
    let out = ScreenExporter.export(oneLine("Hi |UH"), profile: profile, slot: .welcome, date: fixedDate)
    #expect(String(decoding: out.data, as: UTF8.self) == "|16|14Hi |UH\n")
    #expect(out.warnings.isEmpty)
}

@Test func exportedUTF8() {
    var profile = ExportProfile(package: .enigma)
    profile.encoding = .utf8
    profile.sauce = false
    let out = ScreenExporter.export(oneLine("\u{2588}%BN"), profile: profile, slot: .matrix, date: fixedDate)
    #expect(out.relativePath == "art/themes/mytheme/MATRIX.UTF8ANS")
    #expect(String(decoding: out.data, as: UTF8.self).contains("\u{2588}%BN"))
    var mystic = ExportProfile(package: .mystic)
    mystic.encoding = .utf8
    let undocumented = ScreenExporter.export(oneLine("x"), profile: mystic, slot: .matrix, date: fixedDate)
    #expect(undocumented.warnings.contains { $0.kind == .encodingUndocumented })
}

@Test func animatedScreensExportAsANSIAndSayWhy() {
    var profile = ExportProfile(package: .mystic)
    profile.colourCodes = .native
    let project = ScreenTemplates.template("loading")!.make(TemplateOptions(package: .mystic))
    let out = ScreenExporter.export(project, profile: profile, slot: .loading, date: fixedDate)
    #expect(out.warnings.contains { $0.kind == .animatedAsANSI })
    #expect(out.data.contains(0x1B))
}

@Test func foreignCodesBecomeWarnings() {
    let out = ScreenExporter.export(oneLine("Hi @ALIAS@"), profile: ExportProfile(package: .mystic), slot: .welcome, date: fixedDate)
    #expect(out.warnings.contains { $0.kind == .unsupportedCode && $0.message.contains("@ALIAS@") })
}

@Test func exportProfileRoundTripsAsJSON() throws {
    var profile = ExportProfile(package: .wwiv)
    profile.name = "My WWIV"
    profile.folderBookmark = Data([1, 2])
    profile.folderPath = "/Volumes/bbs/wwiv"
    let decoded = try JSONDecoder().decode(ExportProfile.self, from: JSONEncoder().encode(profile))
    #expect(decoded == profile)
}

// MARK: Templates

@Test func everyTemplateFitsTheCallerScreenAtEveryWidth() {
    for template in ScreenTemplates.all {
        for width in template.widths {
            for package in BBSPackage.allCases {
                let options = TemplateOptions(columns: width, bbsName: "Night Shift", package: package)
                let project = template.make(options)
                let canvas = project.frames[0].composite
                #expect(canvas.columns == width, "\(template.id) \(width)")
                #expect(canvas.height <= options.rows, "\(template.id) \(width) is \(canvas.height) rows")
                var profile = ExportProfile(package: package)
                profile.sauce = false
                let out = ScreenExporter.export(project, profile: profile, slot: template.slot, date: fixedDate)
                let size = width == 132 ? CallerTerminalSize(columns: 132, rows: 37) : CallerTerminalSize(columns: 80, rows: 24)
                let sent = BBSDisplay.render(Array(out.data), package: package, samples: SampleValues())
                let layout = CallerPreviewAnalysis.layoutWarnings(sent, size: size)
                #expect(layout.isEmpty, "\(template.id) \(width) \(package): \(layout.map(\.message))")
                #expect(!out.warnings.contains { $0.kind == .unsupportedCode }, "\(template.id) \(package)")
            }
        }
    }
}

@Test func templatesUseThePackagesCodes() {
    let mystic = ScreenTemplates.template("main-menu")!.make(TemplateOptions(package: .mystic))
    let text = TextConvert.utf8Text(mystic.frames[0].composite.screen(trimmed: true))
    #expect(text.contains("|UH") && text.contains("|TL") && text.contains("|ND"))
    let sync = ScreenTemplates.template("welcome")!.make(TemplateOptions(package: .synchronet))
    #expect(TextConvert.utf8Text(sync.frames[0].composite.screen(trimmed: true)).contains("@ALIAS@"))
    // Wildcat has no documented value codes: the sample text stands in.
    var options = TemplateOptions(package: .wildcat)
    options.samples[.userHandle] = "Somebody"
    let wildcat = ScreenTemplates.template("welcome")!.make(options)
    #expect(TextConvert.utf8Text(wildcat.frames[0].composite.screen(trimmed: true)).contains("Somebody"))
}

@Test func loadingTemplateIsAnimated() {
    let template = ScreenTemplates.template("loading")!
    #expect(template.animated)
    let project = template.make(TemplateOptions())
    #expect(project.frames.count == 9)
    #expect(project.frames.last!.delay == 1.0)
    let last = project.frames.last!.composite
    #expect((0..<80).contains { last[$0, 4].code == 0xDB })
}

@Test func templateIdsAreUniqueAndCoverTheBrief() {
    let ids = ScreenTemplates.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    let slots = Set(ScreenTemplates.all.map(\.slot))
    for slot in [ScreenSlot.mainMenu, .matrix, .welcome, .goodbye, .bulletinList, .messageHeader, .fileHeader, .doorMenu, .ad, .loading] {
        #expect(slots.contains(slot))
    }
}
