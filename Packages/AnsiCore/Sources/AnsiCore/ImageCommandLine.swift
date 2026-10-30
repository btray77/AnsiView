import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// `ansirender --from-image` arguments (image import ruling 12).
public struct ImageCommand {
    public enum ParseError: Error, LocalizedError {
        case usage(String)

        public var errorDescription: String? {
            switch self { case .usage(let message): return message }
        }
    }

    public static let usage = """
        usage: ansirender --from-image <image|folder|->... [--preset auto|photo|logo|pixel|line]
          [--width N] [--mode glyph|half|full|shade] [--palette vga|truecolor|xbin]
          [--dither none|fs|serpentine|atkinson|sierra|ordered] [--strength 0-100] [--extended-glyphs]
          [--ice|--no-ice] [--no-aspect] [--nearest] [--levels] [--brightness -100-100] [--contrast -100-100]
          [--saturation -100-100] [--gamma 0.2-5] [--sharpen 0-200] [--remove-background [0-50]]
          [--crop x,y,w,h] [-o file|folder]
        """

    public private(set) var preset: ImagePreset?
    public private(set) var inputs: [String] = []
    public private(set) var output: String?
    /// The settings given on the command line, applied after the preset so they win.
    private var changes: [(inout ImageToAnsi.Options) -> Void] = []

    /// The options for one image: defaults, then the preset, then the explicit flags.
    public func options(imageWidth: Int, imageHeight: Int) -> ImageToAnsi.Options {
        var o = ImageToAnsi.Options()
        for change in changes { change(&o) }
        if let preset { o = preset.options(base: o, imageWidth: imageWidth, imageHeight: imageHeight) }
        for change in changes { change(&o) }
        return o
    }

    public static func parse(_ args: [String]) throws -> ImageCommand {
        var c = ImageCommand()
        var rest = args[...]
        func fail(_ message: String) -> ParseError { .usage(message + "\n" + usage) }
        func value(_ name: String) throws -> String {
            guard let v = rest.popFirst() else { throw fail("\(name) needs a value") }
            return v
        }
        func number(_ name: String, _ range: ClosedRange<Float>) throws -> Float {
            guard let n = Float(try value(name)), range.contains(n) else {
                throw fail("\(name) takes \(range.lowerBound.clean) to \(range.upperBound.clean)")
            }
            return n
        }
        func choice<T: RawRepresentable>(_ name: String, _ type: T.Type) throws -> T where T.RawValue == String, T: CaseIterable {
            let v = try value(name)
            guard let result = T(rawValue: v) else {
                throw fail("\(name) takes " + T.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return result
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--preset":
                let p = try choice(argument, ImagePreset.self)
                guard p != .custom else { throw fail("--preset takes auto, photo, logo, pixel or line") }
                c.preset = p
            case "--width":
                let n = Int(try number(argument, 1...Float(EditCanvas.maxColumns)))
                c.changes.append { $0.columns = n }
            case "--mode": let m = try choice(argument, ImageToAnsi.Mode.self); c.changes.append { $0.mode = m }
            case "--palette": let p = try choice(argument, ImageToAnsi.PaletteChoice.self); c.changes.append { $0.palette = p }
            case "--dither": let d = try choice(argument, ImageToAnsi.Dither.self); c.changes.append { $0.dither = d }
            case "--strength": let n = try number(argument, 0...100) / 100; c.changes.append { $0.ditherStrength = n }
            case "--extended-glyphs": c.changes.append { $0.extendedGlyphs = true }
            case "--ice": c.changes.append { $0.iceColors = true }
            case "--no-ice": c.changes.append { $0.iceColors = false }
            case "--no-aspect": c.changes.append { $0.aspectCorrection = false }
            case "--nearest": c.changes.append { $0.nearestNeighbour = true }
            case "--levels": c.changes.append { $0.adjustments.autoLevels = true }
            case "--brightness": let n = try number(argument, -100...100) / 100; c.changes.append { $0.adjustments.brightness = n }
            case "--contrast": let n = try number(argument, -100...100) / 100; c.changes.append { $0.adjustments.contrast = n }
            case "--saturation": let n = try number(argument, -100...100) / 100; c.changes.append { $0.adjustments.saturation = n }
            case "--gamma": let n = try number(argument, 0.2...5); c.changes.append { $0.adjustments.gamma = n }
            case "--sharpen": let n = try number(argument, 0...200) / 100; c.changes.append { $0.adjustments.sharpen = n }
            case "--remove-background":
                var tolerance: Float?
                if let next = rest.first, let n = Float(next) {
                    guard (0...50).contains(n) else { throw fail("--remove-background takes 0 to 50") }
                    rest.removeFirst()
                    tolerance = n / 100
                }
                c.changes.append {
                    $0.adjustments.removeBackground = true
                    if let tolerance { $0.adjustments.backgroundTolerance = tolerance }
                }
            case "--crop":
                let parts = try value(argument).split(separator: ",").compactMap { Double($0) }
                guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { throw fail("--crop takes x,y,width,height") }
                let rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                c.changes.append { $0.crop = rect }
            case "-o", "--output":
                c.output = try value(argument)
            default:
                if argument != "-", argument.hasPrefix("-") { throw fail("unknown option \(argument)") }
                c.inputs.append(argument)
            }
        }
        guard !c.inputs.isEmpty else { throw fail("no image given") }
        return c
    }
}

private extension Float {
    var clean: String { self == rounded() ? String(Int(self)) : String(self) }
}

/// Many images to ANSI at once (app and CLI).
public enum ImageBatch {
    /// Whether the file's extension names an image type ImageIO may read.
    public static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// Inputs with folders replaced by their images (not recursive, sorted by name without case);
    /// files that are not images are returned as skipped. Hidden files are ignored.
    public static func expand(_ inputs: [URL]) -> (images: [URL], skipped: [URL]) {
        var images: [URL] = [], skipped: [URL] = []
        for url in inputs {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                              options: [.skipsHiddenFiles])) ?? []
                for file in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                    if isImage(file) { images.append(file) } else { skipped.append(file) }
                }
            } else if isImage(url) {
                images.append(url)
            } else {
                skipped.append(url)
            }
        }
        return (images, skipped)
    }

    /// Output files in `outputFolder`, named after each image, never reusing a name taken in
    /// the batch or in `existing` (the folder's current names).
    public static func plan(_ images: [URL], outputFolder: URL, fileExtension: String,
                            existing: Set<String>) -> [(source: URL, output: URL)] {
        var naming = BatchNaming(existing: existing)
        return images.map { ($0, outputFolder.appendingPathComponent(naming.name(for: $0.lastPathComponent, fileExtension: fileExtension))) }
    }
}
