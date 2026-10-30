import AnsiCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Text art font commands for ansirender (fonts plan ruling 18).

private func fontFail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

private func loadFonts(_ path: String) -> [TextArtFont] {
    if path.hasPrefix("original:") {
        let library = FontLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ansirender-fonts"))
        let bundled = library.entries.filter { $0.source != .user }
        guard let index = Int(path.dropFirst(9)), bundled.indices.contains(index) else {
            fontFail("original:N takes 0 to \(bundled.count - 1): " + bundled.enumerated().map { "\($0) \($1.name)" }.joined(separator: ", "), 2)
        }
        return [bundled[index].font]
    }
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { fontFail("could not read \(path)", 1) }
    do {
        return try FontLoader.fonts(in: data, name: url.lastPathComponent)
    } catch {
        fontFail("\(url.lastPathComponent): \(error.localizedDescription)", 1)
    }
}

private func describe(_ font: TextArtFont) -> String {
    switch font {
    case .tdf(let tdf):
        return "\(tdf.type.label), spacing \(tdf.spacing), \(tdf.glyphs.count) glyphs"
    case .figlet(let fig):
        return "FIGlet, height \(fig.height), \(fig.glyphs.count) characters, layout \(fig.horizontalMode)"
    }
}

private func writePNG(_ region: CanvasRegion, to url: URL) {
    let screen = AnsiScreen(columns: max(1, region.width), rows: region.cells)
    guard let rendered = AnsiRenderer.render(screen, options: RenderOptions(for: screen, scale: 1)),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fontFail("render failed", 1) }
    CGImageDestinationAddImage(destination, rendered.image, nil)
    guard CGImageDestinationFinalize(destination) else { fontFail("could not write \(url.path)", 1) }
}

private func layout(_ name: String) -> FIGletLayout {
    switch name {
    case "default": return .fontDefault
    case "full": return .fullWidth
    case "fit": return .fitting
    case "smush": return .smushing
    case "universal": return .universal
    default: fontFail("layout takes default, full, fit, smush or universal", 2)
    }
}

func runFontCommand(_ arguments: [String]) -> Never {
    var rest = arguments
    let command = rest.removeFirst()
    switch command {
    case "--list-fonts":
        guard !rest.isEmpty else { fontFail("usage: ansirender --list-fonts <file>...", 2) }
        for path in rest {
            for (index, font) in loadFonts(path).enumerated() {
                print("\((path as NSString).lastPathComponent)\t\(index)\t\(font.name)\t\(describe(font))")
            }
        }
        exit(0)

    case "--export-original-fonts":
        guard let folder = rest.first else { fontFail("usage: ansirender --export-original-fonts <folder>", 2) }
        let base = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        do {
            try OriginalFonts.tdfData.write(to: base.appendingPathComponent("AnsiView.tdf"))
            try OriginalFonts.figletData.write(to: base.appendingPathComponent("AV Contour.flf"))
        } catch {
            fontFail(error.localizedDescription, 1)
        }
        print("wrote AnsiView.tdf (AV Outline, AV Block, AV Ember) and AV Contour.flf to \(base.path)")
        exit(0)

    case "--figlet-gallery":
        guard !rest.isEmpty else { fontFail("usage: ansirender --figlet-gallery \"TEXT\" [--font-dir <folder>]", 2) }
        let text = rest.removeFirst()
        var entries = FontLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ansirender-fonts"))
            .entries.filter { $0.source != .user }
        if rest.first == "--font-dir", rest.count >= 2 {
            let library = FontLibrary(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ansirender-gallery-\(ProcessInfo.processInfo.processIdentifier)"))
            library.importFonts(from: [URL(fileURLWithPath: rest[1])])
            entries += library.userEntries
            try? FileManager.default.removeItem(at: library.directory)
        }
        for entry in entries {
            let result = TextArt.render(text, font: entry.font, options: TextArtOptions())
            print("== \(entry.name) (\(entry.kindLabel))" + (result.missing.isEmpty ? "" : ", missing \(String(result.missing))"))
            print(TextArtOutput.plainText(result.region))
            print("")
        }
        exit(0)

    default: // --font
        guard let path = rest.first else { fontFail("usage: ansirender --font <file> --text \"HELLO\" [-o out]", 2) }
        rest.removeFirst()
        var index = 0
        var options = TextArtOptions()
        var text: String?
        var output: String?
        func value(_ flag: String) -> String {
            guard !rest.isEmpty else { fontFail("\(flag) needs a value", 2) }
            return rest.removeFirst()
        }
        func number(_ flag: String, _ range: ClosedRange<Int>) -> Int {
            guard let n = Int(value(flag)), range.contains(n) else { fontFail("\(flag) takes \(range.lowerBound) to \(range.upperBound)", 2) }
            return n
        }
        while !rest.isEmpty {
            let flag = rest.removeFirst()
            switch flag {
            case "--font-index": index = number(flag, 0...4095)
            case "--outline-style": options.outlineStyle = number(flag, 0...18)
            case "--spacing": options.spacing = number(flag, 0...40)
            case "--fg": options.foreground = number(flag, 0...15)
            case "--bg": options.background = number(flag, 0...15)
            case "--width": options.wrapWidth = number(flag, 1...1000)
            case "--layout": options.horizontalLayout = layout(value(flag))
            case "--vlayout": options.verticalLayout = layout(value(flag))
            case "--align":
                guard let alignment = TextArtAlignment(rawValue: value(flag)) else { fontFail("--align takes left, center or right", 2) }
                options.alignment = alignment
            case "--ice": options.iceColors = true
            case "--text": text = value(flag)
            case "-o": output = value(flag)
            default: fontFail("unknown option \(flag)", 2)
            }
        }
        guard let text else { fontFail("--text is required", 2) }
        let fonts = loadFonts(path)
        guard fonts.indices.contains(index) else { fontFail("the file has \(fonts.count) font(s); --font-index takes 0 to \(fonts.count - 1)", 2) }
        let result = TextArt.render(text, font: fonts[index], options: options)
        if !result.missing.isEmpty {
            FileHandle.standardError.write("missing in \(fonts[index].name): \(String(result.missing))\n".data(using: .utf8)!)
        }
        guard let output else {
            print(TextArtOutput.ansi(result.region))
            exit(0)
        }
        let url = URL(fileURLWithPath: output)
        switch url.pathExtension.lowercased() {
        case "png": writePNG(result.region, to: url)
        case "txt":
            try? (TextArtOutput.plainText(result.region) + "\n").write(to: url, atomically: true, encoding: .utf8)
        default:
            do {
                try TextArtOutput.ansFile(result.region, title: text, iceColors: options.iceColors).write(to: url)
            } catch {
                fontFail(error.localizedDescription, 1)
            }
        }
        print("\(fonts[index].name): \(result.region.width)x\(result.region.height) cells to \(url.lastPathComponent)")
        exit(0)
    }
}
