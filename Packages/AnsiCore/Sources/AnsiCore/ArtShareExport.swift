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
public enum ArtShareExport {
    public static let holdSeconds = 3.0
    public static let blinkInterval = 0.46

    /// The finished art as PNG data at `scale` pixels per font pixel.
    public static func png(_ file: ArtFile, scale: Int = 2) -> Data? {
        let playback = ArtPlayback(file)
        var options = RenderOptions(for: playback.finalScreen, scale: max(1, scale))
        options.ninePixel = file.ninePixel
        guard let image = AnsiRenderer.render(playback.finalScreen, options: options)?.image else { return nil }
        return encode([image], delays: [0], type: .png)
    }

    public static func frames(_ file: ArtFile, baud: Int, fps: Double = 10) -> [ShareFrame] {
        let playback = ArtPlayback(file)
        let rows = playback.analysis.canvasRows
        let final = playback.finalScreen
        var frames: [ShareFrame] = []
        if baud > 0, !file.stream.isEmpty {
            var terminal = AnsiTerminal(file)
            let bytesPerFrame = Double(baud) / 10 / fps
            var credit = 0.0
            while !terminal.isFinished {
                credit += bytesPerFrame
                let count = Int(credit)
                credit -= Double(count)
                if count > 0 { terminal.advance(byteCount: count) }
                let screen = terminal.screen(minimumRows: rows)
                if let last = frames.last, last.screen.rows == screen.rows {
                    frames[frames.count - 1].duration += 1 / fps
                } else {
                    frames.append(ShareFrame(screen: screen, duration: 1 / fps, blinkVisible: true))
                }
            }
        }
        if final.hasBlink {
            for index in 0..<max(2, Int(holdSeconds / blinkInterval)) {
                frames.append(ShareFrame(screen: final, duration: blinkInterval, blinkVisible: index % 2 == 0))
            }
        } else if let last = frames.last, last.screen.rows == final.rows {
            frames[frames.count - 1].duration += holdSeconds
        } else {
            frames.append(ShareFrame(screen: final, duration: holdSeconds, blinkVisible: true))
        }
        return frames
    }

    /// A looping GIF of the file at `baud`, one pixel per font pixel (two for art of 25 rows or less).
    public static func gif(_ file: ArtFile, baud: Int, fps: Double = 10) -> Data? {
        let frames = frames(file, baud: baud, fps: fps)
        guard !frames.isEmpty else { return nil }
        let scale = ArtPlayback(file).analysis.canvasRows <= TerminalViewport.rows ? 2 : 1
        let delays = delays(frames)
        func options(_ frame: ShareFrame) -> RenderOptions {
            var options = RenderOptions(for: frame.screen, scale: scale, blinkVisible: frame.blinkVisible)
            options.ninePixel = file.ninePixel
            return options
        }
        // AnsiView's own encoder keeps the art's exact colours; past 255 colours ImageIO reduces them.
        if let palette = GIFColors.palette(for: frames.map(\.screen), mode: .automatic) {
            var encoder: GIFEncoder?
            for (index, frame) in frames.enumerated() {
                guard let image = AnsiRenderer.renderIndexed(frame.screen, options: options(frame), palette: palette)
                else { return nil }
                if encoder == nil { encoder = GIFEncoder(width: image.width, height: image.height, palette: palette) }
                encoder?.add(image, delayHundredths: delays[index])
            }
            return encoder?.finish()
        }
        let images = frames.compactMap { AnsiRenderer.render($0.screen, options: options($0))?.image }
        guard images.count == frames.count else { return nil }
        return encode(images, delays: delays, type: .gif)
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
    /// at least 2 each (browsers slow shorter ones).
    static func delays(_ frames: [ShareFrame]) -> [Int] {
        var exact = 0.0
        var written = 0
        return frames.map { frame in
            exact += frame.duration
            let hundredths = max(2, Int((exact * 100).rounded()) - written)
            written += hundredths
            return hundredths
        }
    }

    private static func encode(_ images: [CGImage], delays: [Int], type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)
        else { return nil }
        if type == .gif {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
            ] as CFDictionary)
        }
        for (image, delay) in zip(images, delays) {
            let seconds = Double(delay) / 100
            let properties: CFDictionary? = type == .gif ? [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: seconds,
                    kCGImagePropertyGIFUnclampedDelayTime: seconds,
                ],
            ] as CFDictionary : nil
            CGImageDestinationAddImage(destination, image, properties)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
