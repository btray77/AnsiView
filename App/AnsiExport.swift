import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import libwebp

/// One still in an exported animation.
struct AnsiFrame {
    var screen: AnsiScreen
    var duration: Double
    var blinkVisible = true
}

enum AnsiFrameSequence {
    static let holdSeconds = 3.0

    /// Plays the file at `baud`, sampling `fps` times a second and merging frames that did not change.
    /// Ends with a hold on the final screen; blinking text blinks during the hold.
    static func make(_ source: AnsiSource, baud: Int, fps: Double = 15) -> [AnsiFrame] {
        let analysis = AnsiAnalysis(source)
        let rows = analysis.canvasRows
        var frames: [AnsiFrame] = []
        if baud > 0 {
            var terminal = AnsiTerminal(source)
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
                    frames.append(AnsiFrame(screen: screen, duration: 1 / fps))
                }
            }
        }
        var final = analysis.finalScreen
        while final.rows.count < rows {
            final.rows.append(Array(repeating: AnsiCell(), count: source.columns))
        }
        if final.hasBlink {
            let blinks = Int(holdSeconds / AnsiPlayerViewController.blinkInterval)
            for i in 0..<max(2, blinks) {
                frames.append(AnsiFrame(screen: final, duration: AnsiPlayerViewController.blinkInterval,
                                        blinkVisible: i % 2 == 0))
            }
        } else if let last = frames.last, last.screen.rows == final.rows {
            frames[frames.count - 1].duration += holdSeconds
        } else {
            frames.append(AnsiFrame(screen: final, duration: holdSeconds))
        }
        return frames
    }
}

enum AnsiExportError: LocalizedError {
    case renderFailed
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "The art could not be rendered."
        case .encodeFailed(let detail): return "The file could not be written (\(detail))."
        }
    }
}

enum StillFormat: String, CaseIterable {
    case png = "PNG", jpeg = "JPEG", webp = "WebP"

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp: return "webp"
        }
    }

    var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .image }
}

enum AnimationFormat: String, CaseIterable {
    case gif = "GIF", webp = "Animated WebP", mp4 = "MP4 Video"

    var fileExtension: String {
        switch self {
        case .gif: return "gif"
        case .webp: return "webp"
        case .mp4: return "mp4"
        }
    }

    var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .data }
}

enum AnsiExporter {
    // MARK: Stills

    static func exportStill(_ screen: AnsiScreen, format: StillFormat, scale: Int, to url: URL) throws {
        guard let image = AnsiRenderer.render(screen, scale: scale)?.image else { throw AnsiExportError.renderFailed }
        switch format {
        case .png, .jpeg:
            let type = format == .png ? UTType.png : UTType.jpeg
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
            else { throw AnsiExportError.encodeFailed("image destination") }
            let options = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil
            CGImageDestinationAddImage(dest, image, options)
            guard CGImageDestinationFinalize(dest) else { throw AnsiExportError.encodeFailed("finalize") }
        case .webp:
            let rgba = try rgbaBytes(image)
            var output: UnsafeMutablePointer<UInt8>?
            let size = rgba.withUnsafeBufferPointer { buffer in
                WebPEncodeLosslessRGBA(buffer.baseAddress, Int32(image.width), Int32(image.height),
                                       Int32(image.width * 4), &output)
            }
            guard size > 0, let output else { throw AnsiExportError.encodeFailed("WebP") }
            defer { WebPFree(output) }
            try Data(bytes: output, count: size).write(to: url)
        }
    }

    // MARK: Animations

    static func exportAnimation(
        _ frames: [AnsiFrame], format: AnimationFormat, scale: Int, to url: URL,
        progress: (Double) -> Void
    ) throws {
        switch format {
        case .gif: try writeGIF(frames, scale: scale, to: url, progress: progress)
        case .webp: try writeAnimatedWebP(frames, scale: scale, to: url, progress: progress)
        case .mp4: try writeMP4(frames, scale: scale, to: url, progress: progress)
        }
    }

    private static func render(_ frame: AnsiFrame, atlas: GlyphAtlas) throws -> CGImage {
        guard let image = AnsiRenderer.render(frame.screen, blinkVisible: frame.blinkVisible, atlas: atlas)?.image
        else { throw AnsiExportError.renderFailed }
        return image
    }

    private static func writeGIF(_ frames: [AnsiFrame], scale: Int, to url: URL, progress: (Double) -> Void) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw AnsiExportError.encodeFailed("GIF destination") }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let atlas = GlyphAtlas(scale: scale)
        var exactTime = 0.0
        var writtenHundredths = 0.0
        for (index, frame) in frames.enumerated() {
            // GIF delays are stored in hundredths of a second; round the running total, not each
            // frame, so the animation's length does not drift.
            exactTime += frame.duration
            let hundredths = max(2, (exactTime * 100).rounded() - writtenHundredths)
            writtenHundredths += hundredths
            let delay = hundredths / 100
            CGImageDestinationAddImage(dest, try render(frame, atlas: atlas), [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
            progress(Double(index + 1) / Double(frames.count))
        }
        guard CGImageDestinationFinalize(dest) else { throw AnsiExportError.encodeFailed("GIF finalize") }
    }

    private static func writeAnimatedWebP(
        _ frames: [AnsiFrame], scale: Int, to url: URL, progress: (Double) -> Void
    ) throws {
        let atlas = GlyphAtlas(scale: scale)
        let first = try render(frames[0], atlas: atlas)
        let width = Int32(first.width), height = Int32(first.height)

        var options = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&options) != 0 else { throw AnsiExportError.encodeFailed("WebP options") }
        options.anim_params.loop_count = 0
        guard let encoder = WebPAnimEncoderNew(width, height, &options) else {
            throw AnsiExportError.encodeFailed("WebP encoder")
        }
        defer { WebPAnimEncoderDelete(encoder) }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw AnsiExportError.encodeFailed("WebP config") }
        config.lossless = 1
        config.method = 4

        var timestamp = 0
        for (index, frame) in frames.enumerated() {
            let image = index == 0 ? first : try render(frame, atlas: atlas)
            let rgba = try rgbaBytes(image)
            var picture = WebPPicture()
            guard WebPPictureInit(&picture) != 0 else { throw AnsiExportError.encodeFailed("WebP picture") }
            picture.width = width
            picture.height = height
            picture.use_argb = 1
            let imported = rgba.withUnsafeBufferPointer {
                WebPPictureImportRGBA(&picture, $0.baseAddress, Int32(image.width * 4))
            }
            defer { WebPPictureFree(&picture) }
            guard imported != 0, WebPAnimEncoderAdd(encoder, &picture, Int32(timestamp), &config) != 0 else {
                throw AnsiExportError.encodeFailed("WebP frame \(index)")
            }
            timestamp += max(20, Int((frame.duration * 1000).rounded()))
            progress(Double(index + 1) / Double(frames.count))
        }
        guard WebPAnimEncoderAdd(encoder, nil, Int32(timestamp), nil) != 0 else {
            throw AnsiExportError.encodeFailed("WebP end")
        }
        var data = WebPData()
        WebPDataInit(&data)
        defer { WebPDataClear(&data) }
        guard WebPAnimEncoderAssemble(encoder, &data) != 0, let bytes = data.bytes else {
            throw AnsiExportError.encodeFailed("WebP assemble")
        }
        try Data(bytes: bytes, count: data.size).write(to: url)
    }

    private static func writeMP4(_ frames: [AnsiFrame], scale: Int, to url: URL, progress: (Double) -> Void) throws {
        let atlas = GlyphAtlas(scale: scale)
        let first = try render(frames[0], atlas: atlas)
        let width = first.width, height = first.height
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 4],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw AnsiExportError.encodeFailed(writer.error?.localizedDescription ?? "MP4") }
        writer.startSession(atSourceTime: .zero)

        var milliseconds: Int64 = 0
        for (index, frame) in frames.enumerated() {
            let image = index == 0 ? first : try render(frame, atlas: atlas)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { throw AnsiExportError.encodeFailed("pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw AnsiExportError.encodeFailed("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.interpolationQuality = .none
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: milliseconds, timescale: 1000)) else {
                throw AnsiExportError.encodeFailed(writer.error?.localizedDescription ?? "MP4 frame \(index)")
            }
            milliseconds += max(1, Int64((frame.duration * 1000).rounded()))
            progress(Double(index + 1) / Double(frames.count))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: milliseconds, timescale: 1000))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw AnsiExportError.encodeFailed(writer.error?.localizedDescription ?? "MP4 finish")
        }
    }

    // MARK: Helpers

    /// Raw RGBA bytes (alpha 255) for a rendered frame.
    private static func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard ok else { throw AnsiExportError.renderFailed }
        return bytes
    }
}
