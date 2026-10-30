import Foundation
import ImageIO
import UniformTypeIdentifiers

// ansirender <input> <output.png> [scale]
// ansirender --frame <bytes> <input> <output.png>   (screen after that many bytes, as during playback)
// ansirender --still png|jpeg|webp <scale> <input> <output>
// ansirender --animate gif|webp|mp4 <baud> <scale> <input> <output>
// ansirender --stats <input>...
let args = CommandLine.arguments
func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}
guard args.count >= 3 else { fail("usage: ansirender <input> <output.png> [scale] | --stats <input>...", 2) }
precondition(CP437.unicode.count == 256, "CP437 table has \(CP437.unicode.count) entries")

if args[1] == "--stats" {
    for path in args.dropFirst(2) {
        let url = URL(fileURLWithPath: path)
        let source = AnsiSource(data: try Data(contentsOf: url), fileExtension: url.pathExtension)
        var terminal = AnsiTerminal(source)
        terminal.runToEnd()
        let analysis = AnsiAnalysis(source)
        print(String(format: "%-14@ bytes=%6d writes=%6d overwrites=%5d clears=%2d blink=%@ animated=%@",
                     url.lastPathComponent, source.bytes.count, terminal.writes, terminal.overwrites,
                     terminal.clearsAfterDrawing, analysis.finalScreen.hasBlink ? "Y" : "n",
                     analysis.isAnimated ? "Y" : "n"))
    }
    exit(0)
}

if args[1] == "--still", args.count >= 6, let scale = Int(args[3]) {
    let format: StillFormat = ["png": .png, "jpeg": .jpeg, "webp": .webp][args[2]] ?? .png
    let input = URL(fileURLWithPath: args[4])
    let source = AnsiSource(data: try Data(contentsOf: input), fileExtension: input.pathExtension)
    try AnsiExporter.exportStill(AnsiAnalysis(source).finalScreen, format: format, scale: scale,
                                 to: URL(fileURLWithPath: args[5]))
    print("wrote \(args[5])")
    exit(0)
}

if args[1] == "--animate", args.count >= 7, let baud = Int(args[3]), let scale = Int(args[4]) {
    let format: AnimationFormat = ["gif": .gif, "webp": .webp, "mp4": .mp4][args[2]] ?? .gif
    let input = URL(fileURLWithPath: args[5])
    let source = AnsiSource(data: try Data(contentsOf: input), fileExtension: input.pathExtension)
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
    let source = AnsiSource(data: try Data(contentsOf: input), fileExtension: input.pathExtension)
    let analysis = AnsiAnalysis(source)
    var terminal = AnsiTerminal(source)
    terminal.advance(byteCount: byteCount)
    guard let rendered = AnsiRenderer.render(terminal.screen(minimumRows: analysis.canvasRows)),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[4]) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("render failed", 1) }
    CGImageDestinationAddImage(dest, rendered.image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("could not write \(args[4])", 1) }
    print("\(input.lastPathComponent) at byte \(terminal.position) of \(source.bytes.count)")
    exit(0)
}

let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let scale = args.count > 3 ? Int(args[3]) : nil

let screen = AnsiParser.parse(try Data(contentsOf: input), fileExtension: input.pathExtension)
guard let rendered = AnsiRenderer.render(screen, scale: scale),
      let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("render failed", 1) }
CGImageDestinationAddImage(dest, rendered.image, nil)
guard CGImageDestinationFinalize(dest) else { fail("could not write \(output.path)", 1) }
print("\(input.lastPathComponent): \(rendered.columns)x\(rendered.rows) cells, \(rendered.image.width)x\(rendered.image.height) px")
