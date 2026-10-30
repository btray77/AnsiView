import AnsiCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ansirender <input> <output.png> [scale]
// ansirender --frame <bytes> <input> <output.png>   (screen after that many bytes, as during playback)
// ansirender --still png|jpeg|webp <scale> <input> <output>
// ansirender --animate gif|webp|mp4 <baud> <scale> <input> <output>
// ansirender --stats <input>...
// ansirender --convert html|ansi|ansi256|text|utf8 [--inline] [--no-font] <input> [output]   (stdout when output is - or missing)
// ansirender --export <format> [options] <input> <output>
//   formats: png jpeg webp gif awebp mp4 html ansi ansi256 text utf8
//   options: --scale N --baud N --fps N --palette auto|vga|system --max-bytes N --max-size WxH
// ansirender --batch <format> [options] [--overwrite] <output-folder> <input>...
//   inputs are art files, folders or .zip art packs; exits 1 if any piece failed
// ansirender --roundtrip <input>...   (checks that ANSI conversion reads back as the same cells)
// ansirender --from-image <image> [--width N] [--mode half|full|shade] [--palette vga|truecolor]
//   [--dither none|fs|ordered] [--ice|--no-ice] [--no-aspect] [-o out.ans]   (stdout without -o, or -o -)
// ansirender --music [--mode off|pipe|bananacom|all] <input>...   (lists ANSI music sequences with byte offsets)
// ansirender --music-wav [--soft] [--mode M] <input> | --play "<PLAY string>" <out.wav>
// ansirender --music-midi [--mode M] <input> | --play "<PLAY string>" <out.mid>
// ansirender --version
let args = CommandLine.arguments
func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

if args.count == 2, args[1] == "--version" || args[1] == "-V" {
    // The tool's Info.plist is embedded in the binary (CREATE_INFOPLIST_SECTION_IN_BINARY).
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info["CFBundleVersion"] as? String ?? "unknown"
    print("ansirender \(version) (\(build))")
    exit(0)
}
guard args.count >= 3 else { fail("usage: ansirender <input> <output.png> [scale] | --stats <input>...", 2) }
precondition(CP437.unicode.count == 256, "CP437 table has \(CP437.unicode.count) entries")

if args[1] == "--stats" {
    for path in args.dropFirst(2) {
        let url = URL(fileURLWithPath: path)
        let source = ArtFile(data: try Data(contentsOf: url), fileExtension: url.pathExtension)
        var terminal = AnsiTerminal(source)
        terminal.runToEnd()
        let analysis = AnsiAnalysis(source)
        print(String(format: "%-14@ bytes=%6d writes=%6d overwrites=%5d clears=%2d blink=%@ animated=%@ format=%@ font=%@",
                     url.lastPathComponent, source.stream.count, terminal.writes, terminal.overwrites,
                     terminal.clearsAfterDrawing, analysis.finalScreen.hasBlink ? "Y" : "n",
                     analysis.isAnimated ? "Y" : "n", "\(source.format)", source.font.name))
    }
    exit(0)
}

func loadArt(_ path: String) -> ArtFile {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { fail("could not read \(path)", 1) }
    return ArtFile(data: data, fileExtension: url.pathExtension)
}

if args[1] == "--convert", args.count >= 4, let format = TextFormat(rawValue: args[2]) {
    var rest = Array(args.dropFirst(3))
    let inline = rest.contains("--inline"), noFont = rest.contains("--no-font")
    rest.removeAll { $0 == "--inline" || $0 == "--no-font" }
    guard let inputPath = rest.first else { fail("usage: ansirender --convert <format> [--inline] [--no-font] <input> [output]", 2) }
    let screen = AnsiAnalysis(loadArt(inputPath)).finalScreen
    let data = TextConvert.data(screen, format: format, htmlStyle: inline ? .inline : .classes, embedFont: !noFont)
    if rest.count < 2 || rest[1] == "-" {
        FileHandle.standardOutput.write(data)
    } else {
        do { try data.write(to: URL(fileURLWithPath: rest[1])) } catch { fail("could not write \(rest[1])", 1) }
        print("wrote \(rest[1]): \(data.count) bytes")
    }
    exit(0)
}

if args[1] == "--from-image" {
    let usage = "usage: ansirender --from-image <image> [--width N] [--mode half|full|shade] [--palette vga|truecolor] "
        + "[--dither none|fs|ordered] [--ice|--no-ice] [--no-aspect] [-o out.ans]"
    var options = ImageToAnsi.Options()
    var input: String?
    var output: String?
    var rest = Array(args.dropFirst(2))
    func value(_ name: String) -> String {
        guard !rest.isEmpty else { fail("\(name) needs a value", 2) }
        return rest.removeFirst()
    }
    while !rest.isEmpty {
        let argument = rest.removeFirst()
        switch argument {
        case "--width":
            guard let n = Int(value(argument)), (1...EditCanvas.maxColumns).contains(n) else { fail("--width takes 1 to \(EditCanvas.maxColumns)", 2) }
            options.columns = n
        case "--mode":
            guard let mode = ImageToAnsi.Mode(rawValue: value(argument)) else { fail("--mode takes half, full or shade", 2) }
            options.mode = mode
        case "--palette":
            guard let palette = ImageToAnsi.PaletteChoice(rawValue: value(argument)) else { fail("--palette takes vga or truecolor", 2) }
            options.palette = palette
        case "--dither":
            guard let dither = ImageToAnsi.Dither(rawValue: value(argument)) else { fail("--dither takes none, fs or ordered", 2) }
            options.dither = dither
        case "--ice": options.iceColors = true
        case "--no-ice": options.iceColors = false
        case "--no-aspect": options.aspectCorrection = false
        case "-o", "--output": output = value(argument)
        default:
            if argument.hasPrefix("-") || input != nil { fail(usage, 2) }
            input = argument
        }
    }
    guard let input else { fail(usage, 2) }
    let url = URL(fileURLWithPath: input)
    guard let imageData = try? Data(contentsOf: url) else { fail("could not read \(input)", 1) }
    let canvas: EditCanvas
    do {
        canvas = try ImageToAnsi.convert(data: imageData, options: options, title: url.deletingPathExtension().lastPathComponent)
    } catch {
        fail("\(input): \(error.localizedDescription)", 1)
    }
    let data: Data
    do { data = try ArtWriter.data(canvas, format: .ansi) } catch { fail(error.localizedDescription, 1) }
    if output == nil || output == "-" {
        FileHandle.standardOutput.write(data)
    } else {
        do { try data.write(to: URL(fileURLWithPath: output!)) } catch { fail("could not write \(output!)", 1) }
        print("wrote \(output!): \(canvas.columns)x\(canvas.screen(trimmed: true).rows.count) cells, \(data.count) bytes")
    }
    exit(0)
}

/// Export options and the positional arguments left after them.
struct CommandOptions {
    var settings = ExportSettings()
    var overwrite = false
    var positional: [String] = []
}

func parseOptions(_ arguments: ArraySlice<String>, kind: ExportKind) -> CommandOptions {
    var options = CommandOptions()
    options.settings.kind = kind
    options.settings.baud = PlaybackSpeed.defaultBaud
    var rest = Array(arguments)
    func value(_ name: String) -> String {
        guard !rest.isEmpty else { fail("\(name) needs a value", 2) }
        return rest.removeFirst()
    }
    while let argument = rest.first {
        if !argument.hasPrefix("--") {
            options.positional.append(rest.removeFirst())
            continue
        }
        rest.removeFirst()
        switch argument {
        case "--scale":
            guard let n = Int(value(argument)), (1...8).contains(n) else { fail("--scale takes 1 to 8", 2) }
            options.settings.scale = n
        case "--baud":
            guard let n = Int(value(argument)), n >= 0 else { fail("--baud takes a number (0 draws instantly)", 2) }
            options.settings.baud = n
        case "--fps":
            guard let n = Double(value(argument)), (1...60).contains(n) else { fail("--fps takes 1 to 60", 2) }
            options.settings.fps = n
        case "--palette":
            switch value(argument) {
            case "auto": options.settings.palette = .automatic
            case "vga": options.settings.palette = .vga16
            case "system": options.settings.palette = .system
            default: fail("--palette takes auto, vga or system", 2)
            }
        case "--max-bytes":
            guard let n = Int(value(argument)), n > 0 else { fail("--max-bytes takes a positive number", 2) }
            options.settings.limit = .maxBytes(n)
        case "--max-size":
            let parts = value(argument).lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("--max-size takes WxH, for example 800x600", 2) }
            options.settings.limit = .maxPixels(width: parts[0], height: parts[1])
        case "--overwrite":
            options.overwrite = true
        default:
            fail("unknown option \(argument)", 2)
        }
    }
    return options
}

func exportKind(_ name: String) -> ExportKind {
    guard let kind = ExportKind.commandNames.first(where: { $0.0 == name })?.1 else {
        fail("unknown format \(name); use one of \(ExportKind.commandNames.map(\.0).joined(separator: " "))", 2)
    }
    return kind
}

if args[1] == "--export", args.count >= 3 {
    let options = parseOptions(args.dropFirst(3), kind: exportKind(args[2]))
    guard options.positional.count == 2 else { fail("usage: ansirender --export <format> [options] <input> <output>", 2) }
    let start = Date()
    do {
        let outcome = try AnsiExporter.export(loadArt(options.positional[0]), settings: options.settings,
                                              to: URL(fileURLWithPath: options.positional[1]))
        var line = "wrote \(options.positional[1]): \(outcome.bytes) bytes"
        if let attempt = outcome.attempt {
            line += String(format: ", scale %g", attempt.scale)
            if attempt.fps > 0 { line += String(format: ", %g fps", attempt.fps) }
        }
        if outcome.overLimit { line += ", OVER THE LIMIT (smallest result kept)" }
        print(line + String(format: ", %.1f s", Date().timeIntervalSince(start)))
    } catch {
        fail("\(options.positional[0]): \(error.localizedDescription)", 1)
    }
    exit(0)
}

if args[1] == "--batch", args.count >= 3 {
    let options = parseOptions(args.dropFirst(3), kind: exportKind(args[2]))
    guard options.positional.count >= 2 else {
        fail("usage: ansirender --batch <format> [options] [--overwrite] <output-folder> <input>...", 2)
    }
    let folder = URL(fileURLWithPath: options.positional[0])
    var items: [BatchItem] = []
    var collections: [ArtCollection] = []
    for path in options.positional.dropFirst() {
        let url = URL(fileURLWithPath: path)
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isFolder || url.pathExtension.lowercased() == "zip" {
            do {
                let collection = try ArtCollection.open(url, scoped: false)
                collections.append(collection)
                items += collection.batchItems()
                if collection.skipped > 0 {
                    FileHandle.standardError.write("\(path): \(collection.skipped) entries skipped (unsupported ZIP compression)\n".data(using: .utf8)!)
                }
            } catch {
                fail("\(path): \(error.localizedDescription)", 1)
            }
        } else {
            items.append(BatchItem(name: url.lastPathComponent, load: { try Data(contentsOf: url) }))
        }
    }
    let start = Date()
    let results = BatchExporter.run(items, settings: options.settings, to: folder, overwrite: options.overwrite,
                                    progress: { _, _, _ in }, isCancelled: { false })
    for result in results {
        if let output = result.output {
            print("\(result.name) -> \(output.lastPathComponent) (\(result.bytes) bytes\(result.overLimit ? ", over the limit" : ""))")
        } else {
            FileHandle.standardError.write("\(result.name): \(result.error ?? "failed")\n".data(using: .utf8)!)
        }
    }
    let summary = BatchExporter.summary(results, total: items.count)
    print(summary.title + String(format: " in %.1f s", Date().timeIntervalSince(start)))
    exit(results.contains { $0.error != nil } ? 1 : 0)
}

if args[1] == "--roundtrip" {
    var failures = 0
    for path in args.dropFirst(2) {
        let screen = AnsiAnalysis(loadArt(path)).finalScreen
        for mode in [ANSIColorMode.trueColor, .xterm256] {
            let text = TextConvert.modernANSI(screen, colors: mode)
            let back = AnsiAnalysis(ArtFile(data: Data(text.utf8), fileExtension: "ans")).finalScreen
            func cells(_ s: AnsiScreen) -> [[AnsiCell]] {
                var rows = s.rows.map { $0.map { c -> AnsiCell in var c = c; if c.code == 0 { c.code = 0x20 }; return c } }
                while let last = rows.last, last.allSatisfy({ $0 == AnsiCell() }) { rows.removeLast() }
                return rows
            }
            let same = cells(back) == cells(screen)
            if !same { failures += 1 }
            print("\((path as NSString).lastPathComponent) \(mode == .trueColor ? "24bit" : "256") \(same ? "same" : "DIFFERENT") \(text.utf8.count) bytes")
        }
    }
    exit(failures == 0 ? 0 : 1)
}

// MARK: ANSI music

func musicMode(_ name: String) -> MusicMode {
    switch name.lowercased() {
    case "off": return .off
    case "pipe": return .pipe
    case "bananacom": return .bananaCom
    case "all": return .all
    default: fail("unknown music mode \(name); use off, pipe, bananacom or all", 2)
    }
}

if args[1] == "--music" || args[1] == "--music-wav" || args[1] == "--music-midi" {
    var rest = Array(args.dropFirst(2))
    var mode = MusicMode.all
    var waveform = Waveform.square
    var playString: String?
    var positional: [String] = []
    while !rest.isEmpty {
        let arg = rest.removeFirst()
        switch arg {
        case "--mode": mode = musicMode(rest.isEmpty ? "" : rest.removeFirst())
        case "--soft": waveform = .soft
        case "--play": playString = rest.isEmpty ? "" : rest.removeFirst()
        default: positional.append(arg)
        }
    }
    func seconds(_ value: Double) -> String { String(format: "%.3f", value) }

    if args[1] == "--music" {
        guard !positional.isEmpty else { fail("usage: ansirender --music [--mode M] <input>...", 2) }
        for path in positional {
            let source = loadArt(path)
            let scan = AnsiMusic.scan(source.stream, mode: mode)
            let total = scan.playable.reduce(0) { $0 + $1.duration }
            print("\((path as NSString).lastPathComponent): \(scan.sequences.count) sequences, \(seconds(total)) s")
            for sequence in scan.sequences {
                let preview = sequence.body.count > 60 ? String(sequence.body.prefix(60)) + "..." : sequence.body
                print("  @\(sequence.offset) len=\(sequence.length) ESC[\(sequence.introducer.rawValue) "
                    + "\(sequence.isTerminated ? (sequence.blocksDisplay ? "fg" : "bg") : "-") \(sequence.isTerminated ? "terminated" : "unterminated") "
                    + "notes=\(sequence.notes.count) duration=\(seconds(sequence.duration)) s  \"\(preview)\"")
            }
        }
        exit(0)
    }

    let notes: [TimedNote]
    let output: String
    if let playString {
        guard positional.count == 1 else { fail("usage: ansirender \(args[1]) --play \"<PLAY string>\" <output>", 2) }
        notes = PlayString.schedule(PlayString.parse(playString).items)
        output = positional[0]
    } else {
        guard positional.count == 2 else { fail("usage: ansirender \(args[1]) [--soft] [--mode M] <input> <output>", 2) }
        notes = AnsiMusic.timeline(AnsiMusic.scan(loadArt(positional[0]).stream, mode: mode).playable)
        output = positional[1]
    }
    guard !notes.isEmpty else { fail("no ANSI music found", 1) }
    let data: Data
    var summary: String
    if args[1] == "--music-wav" {
        let samples = MusicSynth(waveform: waveform).render(notes)
        data = WAVFile.data(samples)
        summary = "\(samples.count) samples at 44100 Hz, \(seconds(Double(samples.count) / 44100)) s"
    } else {
        data = MIDIFile.data(notes)
        summary = "\(notes.filter { $0.semitone != nil }.count) notes, \(seconds(notes.last?.end ?? 0)) s"
    }
    do { try data.write(to: URL(fileURLWithPath: output)) } catch { fail("could not write \(output)", 1) }
    summary = "wrote \(output): \(data.count) bytes, " + summary
    print(summary)
    exit(0)
}

if args[1] == "--still", args.count >= 6, let scale = Int(args[3]) {
    let format: StillFormat = ["png": .png, "jpeg": .jpeg, "webp": .webp][args[2]] ?? .png
    let input = URL(fileURLWithPath: args[4])
    let source = ArtFile(data: try Data(contentsOf: input), fileExtension: input.pathExtension)
    try AnsiExporter.exportStill(AnsiAnalysis(source).finalScreen, format: format, scale: scale,
                                 to: URL(fileURLWithPath: args[5]))
    print("wrote \(args[5])")
    exit(0)
}

if args[1] == "--animate", args.count >= 7, let baud = Int(args[3]), let scale = Int(args[4]) {
    let format: AnimationFormat = ["gif": .gif, "webp": .webp, "mp4": .mp4][args[2]] ?? .gif
    let input = URL(fileURLWithPath: args[5])
    let source = ArtFile(data: try Data(contentsOf: input), fileExtension: input.pathExtension)
    let start = Date()
    let frames = AnsiFrameSequence.make(source, baud: baud)
    let seconds = frames.reduce(0) { $0 + $1.duration }
    try AnsiExporter.exportAnimation(frames, format: format, scale: scale,
                                     to: URL(fileURLWithPath: args[6]), progress: { _ in })
    print(String(format: "wrote %@: %d frames, %.1f s of playback, encoded in %.1f s",
                 args[6], frames.count, seconds, Date().timeIntervalSince(start)))
    exit(0)
}

if args[1] == "--frame", args.count >= 5, let byteCount = Int(args[2]) {
    let input = URL(fileURLWithPath: args[3])
    let source = ArtFile(data: try Data(contentsOf: input), fileExtension: input.pathExtension)
    let analysis = AnsiAnalysis(source)
    var terminal = AnsiTerminal(source)
    terminal.advance(byteCount: byteCount)
    let frame = terminal.screen(minimumRows: analysis.canvasRows)
    guard let rendered = AnsiRenderer.render(frame, options: RenderOptions(for: frame)),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[4]) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("render failed", 1) }
    CGImageDestinationAddImage(dest, rendered.image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("could not write \(args[4])", 1) }
    print("\(input.lastPathComponent) at byte \(terminal.position) of \(source.stream.count)")
    exit(0)
}

let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let scale = args.count > 3 ? Int(args[3]) : nil

let screen = AnsiParser.parse(try Data(contentsOf: input), fileExtension: input.pathExtension)
guard let rendered = AnsiRenderer.render(screen, options: RenderOptions(for: screen, scale: scale)),
      let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("render failed", 1) }
CGImageDestinationAddImage(dest, rendered.image, nil)
guard CGImageDestinationFinalize(dest) else { fail("could not write \(output.path)", 1) }
print("\(input.lastPathComponent): \(rendered.columns)x\(rendered.rows) cells, \(rendered.image.width)x\(rendered.image.height) px")
