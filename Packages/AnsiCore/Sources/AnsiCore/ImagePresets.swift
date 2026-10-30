import CoreGraphics
import Foundation

/// Starting points for common kinds of picture (image import ruling 9).
public enum ImagePreset: String, CaseIterable, Codable {
    case auto
    case photo
    case logo
    case pixelArt = "pixel"
    case lineArt = "line"
    case custom

    public var label: String {
        switch self {
        case .auto: return "Auto (compare methods)"
        case .photo: return "Photo"
        case .logo: return "Logo / flat art"
        case .pixelArt: return "Pixel art"
        case .lineArt: return "Line art"
        case .custom: return "Custom"
        }
    }

    /// `base` with this preset's method settings. Width, colours, iCE, aspect and crop come from
    /// `base` (pixel art sets the width to the image's, one pixel per half block). Auto and
    /// Custom return `base` unchanged; Auto's methods come from `ImageToAnsi.autoCandidates`.
    public func options(base: ImageToAnsi.Options, imageWidth: Int, imageHeight: Int) -> ImageToAnsi.Options {
        var o = base
        switch self {
        case .auto, .custom:
            return base
        case .photo:
            o.mode = .glyphs
            o.dither = .serpentine
            o.ditherStrength = 0.7
            o.extendedGlyphs = false
            o.nearestNeighbour = false
            o.adjustments.autoLevels = true
        case .logo:
            o.mode = .glyphs
            o.dither = .none
            o.extendedGlyphs = false
            o.nearestNeighbour = false
        case .pixelArt:
            let crop = ImageToAnsi.normalizedCrop(base.crop, width: imageWidth, height: imageHeight)
            o.columns = min(EditCanvas.maxColumns, max(1, crop.map { Int($0.width) } ?? imageWidth))
            o.mode = .halfBlocks
            o.dither = .none
            o.nearestNeighbour = true
            o.aspectCorrection = true
        case .lineArt:
            o.mode = .glyphs
            o.extendedGlyphs = true
            o.dither = .none
            o.nearestNeighbour = false
            o.adjustments.autoLevels = true
            o.adjustments.contrast = 0.3
        }
        return o
    }
}

/// One method Auto tried, with its result and score.
public struct AutoCandidate {
    public let name: String
    public let options: ImageToAnsi.Options
    public let canvas: EditCanvas
    public let score: ImageScore.Result
}

extension ImageToAnsi {
    /// The methods Auto compares: `base` (width, colours, iCE, aspect, crop and adjustments)
    /// with each method's settings.
    public static func autoMethods(base: Options) -> [(name: String, options: Options)] {
        func with(_ mode: Mode, _ dither: Dither, _ strength: Float, extended: Bool = false) -> Options {
            var o = base
            o.mode = mode
            o.dither = dither
            o.ditherStrength = strength
            o.extendedGlyphs = extended
            o.nearestNeighbour = false
            return o
        }
        return [
            ("Best character, serpentine dither", with(.glyphs, .serpentine, 0.7)),
            ("Best character, no dither", with(.glyphs, .none, 1)),
            ("Best character with lines, no dither", with(.glyphs, .none, 1, extended: true)),
            ("Half blocks, Floyd-Steinberg", with(.halfBlocks, .floydSteinberg, 1)),
            ("Half blocks, Atkinson", with(.halfBlocks, .atkinson, 1)),
            ("Half blocks, no dither", with(.halfBlocks, .none, 1)),
            ("Shades, Sierra Lite", with(.shades, .sierraLite, 1)),
        ]
    }

    /// Runs every Auto method (in parallel) and returns them best first by delta E; identical
    /// results are listed once. Nil when cancelled.
    public static func autoCandidates(_ image: CGImage, base: Options, cancel: @escaping () -> Bool) -> [AutoCandidate]? {
        let methods = autoMethods(base: base)
        var results = [AutoCandidate?](repeating: nil, count: methods.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: methods.count) { i in
            guard let canvas = convert(image, options: methods[i].options, cancel: cancel), !cancel() else { return }
            let score = ImageScore.score(canvas, source: image, options: methods[i].options)
            lock.lock()
            results[i] = AutoCandidate(name: methods[i].name, options: methods[i].options, canvas: canvas, score: score)
            lock.unlock()
        }
        if cancel() { return nil }
        var unique: [AutoCandidate] = []
        for case let candidate? in results where !unique.contains(where: { $0.canvas == candidate.canvas }) {
            unique.append(candidate)
        }
        guard !unique.isEmpty else { return nil }
        // Stable: equal scores keep the list order above.
        return unique.enumerated().sorted {
            $0.element.score.deltaE != $1.element.score.deltaE ? $0.element.score.deltaE < $1.element.score.deltaE : $0.offset < $1.offset
        }.map(\.element)
    }
}
