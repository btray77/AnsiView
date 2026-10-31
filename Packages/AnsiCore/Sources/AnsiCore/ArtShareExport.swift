import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One still of a shared animation.
public struct ShareFrame {
    public var screen: AnsiScreen
    public var duration: Double
    public var blinkVisible: Bool
}

/// PNG and GIF files for the iPhone and iPad share sheet. The frames follow the macOS export
/// (`App/AnsiExport.swift`, without ANSI music): the file played at `baud`, sampled `fps` times a
/// second, unchanged samples merged, then a hold on the finished art in which blinking text blinks.
/// A long stream is sampled less often so there are at most `maxFrames` drawing samples, and the
/// GIF is encoded one frame at a time, so memory does not grow with the length of the file.
public enum ArtShareExport {
    public static let holdSeconds = 3.0
    public static let blinkInterval = 0.46
    /// At most this many samples of the drawing (about 1 minute at 10 a second).
    public static let maxFrames = 600

    /// The finished art as PNG data at `scale` pixels per font pixel.
    public static func png(_ file: ArtFile, scale: Int = 2) -> Data? {
        let playback = ArtPlayback(file)
        var options = RenderOptions(for: playback.finalScreen, scale: max(1, scale))
        options.ninePixel = file.ninePixel
        guard let image = AnsiRenderer.render(playback.finalScreen, options: options)?.image else { return nil }
        return encode([image], delays: [0], type: .png)
    }

    /// Every frame of the share animation, in order.
    public static func frames(_ file: ArtFile, baud: Int, fps: Double = 10) -> [ShareFrame] {
        var frames: [ShareFrame] = []
        forEachFrame(file, baud: baud, fps: fps) { frames.append($0) }
        return frames
    }

    /// Calls `body` with each frame as it is made, holding only the frame being merged.
    static func forEachFrame(_ file: ArtFile, baud: Int, fps: Double, _ body: (ShareFrame) -> Void) {
        let playback = ArtPlayback(file)
        let rows = playback.analysis.canvasRows
        let final = playback.finalScreen
        var pending: ShareFrame?
        func add(_ frame: ShareFrame) {
            if let current = pending, current.blinkVisible, frame.blinkVisible, current.screen.rows == frame.screen.rows {
                pending?.duration += frame.duration
            } else {
                if let current = pending { body(current) }
                pending = frame
            }
        }
        let length = file.stream.count
        if baud > 0, length > 0 {
            let drawSeconds = Double(length) * 10 / Double(baud)
            let rate = min(fps, Double(maxFrames) / drawSeconds)
            var terminal = AnsiTerminal(file)
            let bytesPerFrame = Double(baud) / 10 / rate
            var credit = 0.0
            while !terminal.isFinished {
                credit += bytesPerFrame
                let count = Int(credit)
                credit -= Double(count)
                if count > 0 { terminal.advance(byteCount: count) }
                add(ShareFrame(screen: terminal.screen(minimumRows: rows), duration: 1 / rate, blinkVisible: true))
            }
        }
        if final.hasBlink {
            if let current = pending { body(current) }
            pending = nil
            for index in 0..<max(2, Int(holdSeconds / blinkInterval)) {
                body(ShareFrame(screen: final, duration: blinkInterval, blinkVisible: index % 2 == 0))
            }
        } else {
            add(ShareFrame(screen: final, duration: holdSeconds, blinkVisible: true))
            if let current = pending { body(current) }
        }
    }

    /// A looping GIF of the file at `baud`, one pixel per font pixel (two for art of 25 rows or less).
    /// Two passes over the playback: the colours in use, then each frame rendered and encoded.
    public static func gif(_ file: ArtFile, baud: Int, fps: Double = 10) -> Data? {
        var colors = ColorCollector()
        var count = 0
        forEachFrame(file, baud: baud, fps: fps) { frame in
            colors.add(frame.screen)
            count += 1
        }
        guard count > 0 else { return nil }
        let scale = ArtPlayback(file).analysis.canvasRows <= TerminalViewport.rows ? 2 : 1
        func options(_ frame: ShareFrame) -> RenderOptions {
            var options = RenderOptions(for: frame.screen, scale: scale, blinkVisible: frame.blinkVisible)
            options.ninePixel = file.ninePixel
            return options
        }
        var delays = DelayRounder()
        // AnsiView's own encoder keeps the art's exact colours; past 255 colours ImageIO reduces them.
        if let palette = colors.palette {
            var encoder: GIFEncoder?
            var failed = false
            forEachFrame(file, baud: baud, fps: fps) { frame in
                guard !failed,
                      let image = AnsiRenderer.renderIndexed(frame.screen, options: options(frame), palette: palette)
                else { failed = true; return }
                if encoder == nil { encoder = GIFEncoder(width: image.width, height: image.height, palette: palette) }
                encoder?.add(image, delayHundredths: delays.next(frame.duration))
            }
            return failed ? nil : encoder?.finish()
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil)
        else { return nil }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        var failed = false
        forEachFrame(file, baud: baud, fps: fps) { frame in
            guard !failed, let image = AnsiRenderer.render(frame.screen, options: options(frame))?.image
            else { failed = true; return }
            CGImageDestinationAddImage(destination, image, gifProperties(delays.next(frame.duration)))
        }
        guard !failed, CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The shared file's name: the original name with a new extension, safe for a file system.
    public static func fileName(for name: String, extension ext: String) -> String {
        let base = (name as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "AnsiView" : base).\(ext)"
    }

    /// Delays in hundredths of a second, rounding the running total so the length does not drift;
    /// at least 2 each (browsers slow shorter ones). The same rule as the macOS export.
    struct DelayRounder {
        private var exact = 0.0
        private var written = 0
        mutating func next(_ duration: Double) -> Int {
            exact += duration
            let hundredths = max(2, Int((exact * 100).rounded()) - written)
            written += hundredths
            return hundredths
        }
    }

    /// The colours frames use, as `GIFColors.palette(for:mode: .automatic)` would choose them,
    /// collected one screen at a time.
    struct ColorCollector {
        private var used: [RGB] = [Palette.vga[0]]
        private var seen: Set<RGB> = [Palette.vga[0]]
        private var overflow = false

        mutating func add(_ screen: AnsiScreen) {
            guard !overflow else { return }
            for row in screen.rows {
                for cell in row {
                    for color in [cell.fg, cell.bg] where !seen.contains(color) {
                        seen.insert(color)
                        used.append(color)
                        if used.count > 255 { overflow = true; return }
                    }
                }
            }
        }

        var palette: [RGB]? {
            guard !overflow else { return nil }
            let extra = used.filter { !Palette.vga.contains($0) }
            return Palette.vga.count + extra.count <= 255 ? Palette.vga + extra : used
        }
    }

    private static func gifProperties(_ hundredths: Int) -> CFDictionary {
        let seconds = Double(hundredths) / 100
        return [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: seconds,
                kCGImagePropertyGIFUnclampedDelayTime: seconds,
            ],
        ] as CFDictionary
    }

    private static func encode(_ images: [CGImage], delays: [Int], type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)
        else { return nil }
        for (image, _) in zip(images, delays) {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
