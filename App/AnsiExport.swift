import AnsiCore
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
    static func make(_ source: ArtFile, baud: Int, fps: Double = 15) -> [AnsiFrame] {
        make(source, baud: baud, fps: fps, music: false).frames
    }

    /// As `make`, and with `music` the file's ANSI music on the video's clock: foreground music
    /// holds the frames as it holds the viewer, and the final hold lasts until the music ends.
    /// At baud 0 the music plays once from the start.
    static func make(_ source: ArtFile, baud: Int, fps: Double = 15, music: Bool)
        -> (frames: [AnsiFrame], music: [ScheduledMusic]) {
        let analysis = AnsiAnalysis(source)
        let rows = analysis.canvasRows
        var frames: [AnsiFrame] = []
        var scheduler = MusicPlaybackScheduler(file: source)
        let withMusic = music && scheduler.hasMusic
        var elapsed = 0.0
        if baud > 0 {
            var terminal = AnsiTerminal(source)
            let bytesPerFrame = Double(baud) / 10 / fps
            var credit = 0.0
            var index = 0
            while !terminal.isFinished || (withMusic && scheduler.isHolding(at: Double(index) / fps)) {
                let time = Double(index) / fps
                index += 1
                if withMusic, scheduler.isHolding(at: time) {
                    credit = 0
                } else {
                    credit += bytesPerFrame
                    let count = Int(credit)
                    credit -= Double(count)
                    if count > 0 {
                        if withMusic {
                            _ = scheduler.advance(&terminal, by: count, at: time)
                            if scheduler.isHolding(at: time) { credit = 0 }
                        } else {
                            terminal.advance(byteCount: count)
                        }
                    }
                }
                elapsed += 1 / fps
                let screen = terminal.screen(minimumRows: rows)
                if let last = frames.last, last.screen.rows == screen.rows {
                    frames[frames.count - 1].duration += 1 / fps
                } else {
                    frames.append(AnsiFrame(screen: screen, duration: 1 / fps))
                }
            }
        }
        if withMusic, baud <= 0 { _ = scheduler.playAll(at: 0) }
        let played = withMusic ? scheduler.started : []
        // The finished art stays until background music sent at the end has played.
        let musicEnd = played.map(\.end).max() ?? 0
        let hold = max(holdSeconds, musicEnd - elapsed)
        var final = analysis.finalScreen
        while final.rows.count < rows {
            final.rows.append(Array(repeating: AnsiCell(), count: source.columns))
        }
        if final.hasBlink {
            let interval = AnsiPlayerViewController.blinkInterval
            var blinks = Int(hold / interval)
            if Double(blinks) * interval < musicEnd - elapsed { blinks += 1 }  // cover the music's end
            for i in 0..<max(2, blinks) {
                frames.append(AnsiFrame(screen: final, duration: AnsiPlayerViewController.blinkInterval,
                                        blinkVisible: i % 2 == 0))
            }
        } else if let last = frames.last, last.screen.rows == final.rows {
            frames[frames.count - 1].duration += hold
        } else {
            frames.append(AnsiFrame(screen: final, duration: hold))
        }
        return (frames, played)
    }

    /// The music of an export as mono 44.1 kHz samples from the video's start, as long as the
    /// frames (empty without music). Each tune is rendered on its own, so late tunes keep their sound.
    static func audio(_ music: [ScheduledMusic], frames: [AnsiFrame]) -> [Float] {
        guard !music.isEmpty else { return [] }
        let length = max(frames.reduce(0) { $0 + $1.duration }, music.map(\.end).max() ?? 0)
        return MusicPlaybackScheduler.audioSamples(music, length: length)
    }
}

enum AnsiExportError: LocalizedError {
    case renderFailed
    case encodeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "The art could not be rendered."
        case .encodeFailed(let detail): return "The file could not be written (\(detail))."
        case .cancelled: return "The export was cancelled."
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

/// Everything AnsiView can export a piece as.
enum ExportKind: Hashable {
    case still(StillFormat), animation(AnimationFormat), text(TextFormat)

    static let all: [ExportKind] = StillFormat.allCases.map(ExportKind.still)
        + AnimationFormat.allCases.map(ExportKind.animation) + TextFormat.allCases.map(ExportKind.text)

    /// Names used by `ansirender`.
    static let commandNames: [(String, ExportKind)] = [
        ("png", .still(.png)), ("jpeg", .still(.jpeg)), ("webp", .still(.webp)),
        ("gif", .animation(.gif)), ("awebp", .animation(.webp)), ("mp4", .animation(.mp4)),
        ("html", .text(.html)), ("ansi", .text(.ansi)), ("ansi256", .text(.ansi256)),
        ("text", .text(.text)), ("utf8", .text(.utf8)),
    ]

    var label: String {
        switch self {
        case .still(let format): return format.rawValue
        case .animation(let format): return format.rawValue
        case .text(let format): return format.label
        }
    }

    var fileExtension: String {
        switch self {
        case .still(let format): return format.fileExtension
        case .animation(let format): return format.fileExtension
        case .text(let format): return format.fileExtension
        }
    }

    var isAnimation: Bool { if case .animation = self { return true } else { return false } }
    var isText: Bool { if case .text = self { return true } else { return false } }
}

/// The choices behind one export.
struct ExportSettings {
    var kind: ExportKind = .still(.png)
    /// Pixels per font pixel.
    var scale = 2
    /// Playback speed for animations (0 draws instantly).
    var baud = 2400
    /// Frames per second sampled from the playback.
    var fps = 15.0
    var palette: GIFPalette = .automatic
    var limit: SizeLimit = .none
    /// MP4 only: the file's ANSI music as a sound track (GIF and WebP have no sound).
    var includeMusic = false
}

/// What an export produced.
struct ExportOutcome {
    let bytes: Int
    /// A byte limit could not be met; the smallest result was kept.
    let overLimit: Bool
    /// The scale and frame rate used (nil for text).
    let attempt: ExportAttempt?
}

enum AnsiExporter {
    // MARK: Settings driven export

    /// Exports `source` (or `screen`, the frame on screen, for stills and text) with `settings`.
    /// A byte limit exports to a temporary folder until a result fits, then moves it to `url`.
    @discardableResult
    static func export(
        _ source: ArtFile, screen: AnsiScreen? = nil, settings: ExportSettings, to url: URL,
        progress: @escaping (Double) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false }
    ) throws -> ExportOutcome {
        let analysis = AnsiAnalysis(source)
        var still = screen ?? analysis.finalScreen

        if case .text(let format) = settings.kind {
            let data = TextConvert.data(still, format: format)
            try data.write(to: url, options: .atomic)
            progress(1)
            var over = false
            if case .maxBytes(let target) = settings.limit { over = data.count > target }
            return ExportOutcome(bytes: data.count, overLimit: over, attempt: nil)
        }

        while still.rows.count < analysis.canvasRows {
            still.rows.append(Array(repeating: AnsiCell(), count: still.columns))
        }
        let animated = settings.kind.isAnimation
        func write(_ attempt: ExportAttempt, to destination: URL) throws {
            switch settings.kind {
            case .still(let format):
                try writeStill(still, format: format, scale: attempt.scale, to: destination)
                progress(1)
            case .animation(let format):
                let made = AnsiFrameSequence.make(source, baud: settings.baud, fps: attempt.fps,
                                                  music: settings.includeMusic && format == .mp4)
                try writeAnimation(made.frames, format: format, scale: attempt.scale, palette: settings.palette,
                                   audio: AnsiFrameSequence.audio(made.music, frames: made.frames),
                                   to: destination, progress: progress, isCancelled: isCancelled)
            case .text:
                break
            }
        }
        let requested = ExportAttempt(scale: Double(max(1, settings.scale)), fps: animated ? settings.fps : 0)

        // Every attempt is written to a temporary folder; only a finished file replaces `url`, so
        // a failed or cancelled export leaves whatever was there before.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnsiView-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var number = 0
        func attemptFile(_ attempt: ExportAttempt) throws -> (url: URL, bytes: Int) {
            if isCancelled() { throw AnsiExportError.cancelled }
            number += 1
            let candidate = folder.appendingPathComponent("attempt\(number).\(settings.kind.fileExtension)")
            try write(attempt, to: candidate)
            return (candidate, fileSize(candidate))
        }

        switch settings.limit {
        case .none:
            let file = try attemptFile(requested)
            try place(file.url, at: url)
            return ExportOutcome(bytes: file.bytes, overLimit: false, attempt: requested)
        case .maxPixels(let width, let height):
            let scale = SizeFit.scale(artPixels: onePixelSize(still), requestedScale: settings.scale,
                                      maxPixels: CGSize(width: width, height: height))
            let attempt = ExportAttempt(scale: scale, fps: requested.fps)
            let file = try attemptFile(attempt)
            try place(file.url, at: url)
            return ExportOutcome(bytes: file.bytes, overLimit: false, attempt: attempt)
        case .maxBytes(let target):
            let ladder = SizeFit.ladder(requestedScale: settings.scale, fps: settings.fps, animated: animated)
            var attempt = ladder[0]
            var best: (url: URL, bytes: Int, attempt: ExportAttempt)?
            while true {
                let file = try attemptFile(attempt)
                if best == nil || file.bytes < best!.bytes { best = (file.url, file.bytes, attempt) }
                if file.bytes <= target { break }
                guard let next = SizeFit.next(after: attempt, bytes: file.bytes, target: target, ladder: ladder) else { break }
                attempt = next
            }
            guard let best else { throw AnsiExportError.encodeFailed("no result") }
            try place(best.url, at: url)
            return ExportOutcome(bytes: best.bytes, overLimit: best.bytes > target, attempt: best.attempt)
        }
    }

    /// Moves a finished file to `url`, replacing what is there only now that the new file exists.
    private static func place(_ file: URL, at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: url)
        }
    }

    /// The art's size at 1x: one pixel per font pixel.
    static func onePixelSize(_ screen: AnsiScreen) -> CGSize {
        let options = RenderOptions(for: screen, scale: 1)
        let cellWidth = options.font.width + (options.ninePixel ? 1 : 0)
        return CGSize(width: screen.columns * cellWidth, height: max(1, screen.rows.count) * options.font.height)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: Stills

    static func exportStill(_ screen: AnsiScreen, format: StillFormat, scale: Int, to url: URL) throws {
        try writeStill(screen, format: format, scale: Double(scale), to: url)
    }

    private static func writeStill(_ screen: AnsiScreen, format: StillFormat, scale: Double, to url: URL) throws {
        let image = try renderImage(screen, scale: scale, blinkVisible: true)
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

    /// A screen at `scale` pixels per font pixel; below 1 (or a fraction) it is drawn at the
    /// nearest whole scale under it (at least 1) and resampled down. `even` rounds the size down
    /// to even numbers (H.264 needs them).
    static func renderImage(_ screen: AnsiScreen, scale: Double, blinkVisible: Bool, even: Bool = false) throws -> CGImage {
        let whole = max(1, Int(scale.rounded(.down)))
        let options = RenderOptions(for: screen, scale: whole, blinkVisible: blinkVisible)
        guard let image = AnsiRenderer.render(screen, options: options)?.image else { throw AnsiExportError.renderFailed }
        var width = image.width, height = image.height
        if Double(whole) != scale {
            width = max(1, Int((Double(image.width) * scale / Double(whole)).rounded()))
            height = max(1, Int((Double(image.height) * scale / Double(whole)).rounded()))
        }
        if even {
            width = max(2, width & ~1)
            height = max(2, height & ~1)
        }
        if width == image.width, height == image.height { return image }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw AnsiExportError.renderFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resampled = context.makeImage() else { throw AnsiExportError.renderFailed }
        return resampled
    }

    // MARK: Animations

    /// The animation as before plan 4: ImageIO's own GIF colours. Used by `ansirender --animate`.
    static func exportAnimation(
        _ frames: [AnsiFrame], format: AnimationFormat, scale: Int, to url: URL,
        progress: (Double) -> Void
    ) throws {
        try writeAnimation(frames, format: format, scale: Double(scale), palette: .system, to: url,
                           progress: progress, isCancelled: { false })
    }

    static func writeAnimation(
        _ frames: [AnsiFrame], format: AnimationFormat, scale: Double, palette: GIFPalette, audio: [Float] = [],
        to url: URL, progress: (Double) -> Void, isCancelled: () -> Bool
    ) throws {
        let render: (AnsiFrame) throws -> CGImage = { frame in
            if isCancelled() { throw AnsiExportError.cancelled }
            return try renderImage(frame.screen, scale: scale, blinkVisible: frame.blinkVisible, even: format == .mp4)
        }
        switch format {
        case .gif:
            // AnsiView's own encoder keeps the art's exact colours; resampled frames have new colours.
            if scale == scale.rounded(.down), scale >= 1,
               let colors = GIFColors.palette(for: frames.map(\.screen), mode: palette) {
                try writeIndexedGIF(frames, scale: Int(scale), palette: colors, to: url,
                                    progress: progress, isCancelled: isCancelled)
            } else {
                try writeGIF(frames, render: render, to: url, progress: progress)
            }
        case .webp: try writeAnimatedWebP(frames, render: render, to: url, progress: progress)
        case .mp4: try writeMP4(frames, render: render, audio: audio, to: url, progress: progress, isCancelled: isCancelled)
        }
    }

    /// GIF delays in hundredths of a second. The running total is rounded, not each frame, so the
    /// animation's length does not drift; every delay is at least 2 (browsers slow shorter ones).
    static func gifDelays(_ frames: [AnsiFrame]) -> [Int] {
        var exactTime = 0.0
        var written = 0
        return frames.map { frame in
            exactTime += frame.duration
            let hundredths = max(2, Int((exactTime * 100).rounded()) - written)
            written += hundredths
            return hundredths
        }
    }

    private static func writeIndexedGIF(
        _ frames: [AnsiFrame], scale: Int, palette: [RGB], to url: URL,
        progress: (Double) -> Void, isCancelled: () -> Bool
    ) throws {
        let delays = gifDelays(frames)
        var encoder: GIFEncoder?
        for (index, frame) in frames.enumerated() {
            if isCancelled() { throw AnsiExportError.cancelled }
            let options = RenderOptions(for: frame.screen, scale: scale, blinkVisible: frame.blinkVisible)
            guard let image = AnsiRenderer.renderIndexed(frame.screen, options: options, palette: palette)
            else { throw AnsiExportError.renderFailed }
            if encoder == nil { encoder = GIFEncoder(width: image.width, height: image.height, palette: palette) }
            encoder?.add(image, delayHundredths: delays[index])
            progress(Double(index + 1) / Double(frames.count))
        }
        guard var encoder else { throw AnsiExportError.renderFailed }
        try encoder.finish().write(to: url)
    }

    private static func writeGIF(
        _ frames: [AnsiFrame], render: (AnsiFrame) throws -> CGImage, to url: URL, progress: (Double) -> Void
    ) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw AnsiExportError.encodeFailed("GIF destination") }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delays = gifDelays(frames)
        for (index, frame) in frames.enumerated() {
            let delay = Double(delays[index]) / 100
            CGImageDestinationAddImage(dest, try render(frame), [
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
        _ frames: [AnsiFrame], render: (AnsiFrame) throws -> CGImage, to url: URL, progress: (Double) -> Void
    ) throws {
        let first = try render(frames[0])
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
            let image = index == 0 ? first : try render(frame)
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

    static let audioSampleRate = 44100

    /// 16 bit mono PCM at 44.1 kHz, the format the audio samples are handed to the writer in.
    private static func pcmFormat() throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(audioSampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
            mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr, let format
        else { throw AnsiExportError.encodeFailed("audio format") }
        return format
    }

    /// One chunk of samples as a sample buffer starting at sample `start`.
    private static func audioBuffer(_ samples: ArraySlice<Float>, start: Int,
                                    format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let ints = samples.map { Int16((max(-1, min(1, $0)) * 32767).rounded()) }
        let length = ints.count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw AnsiExportError.encodeFailed("audio block") }
        let copied = ints.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: length)
        }
        var buffer: CMSampleBuffer?
        guard copied == noErr,
              CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: ints.count,
                presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(audioSampleRate)),
                packetDescriptions: nil, sampleBufferOut: &buffer) == noErr,
              let buffer else { throw AnsiExportError.encodeFailed("audio buffer") }
        return buffer
    }

    private static func writeMP4(
        _ frames: [AnsiFrame], render: (AnsiFrame) throws -> CGImage, audio: [Float] = [], to url: URL,
        progress: (Double) -> Void, isCancelled: () -> Bool = { false }
    ) throws {
        let first = try render(frames[0])
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
        // The music as AAC, fed in step with the frames so the writer can interleave them.
        var audioInput: AVAssetWriterInput?
        let audioFormat = audio.isEmpty ? nil : try pcmFormat()
        if audioFormat != nil {
            let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ])
            sound.expectsMediaDataInRealTime = false
            writer.add(sound)
            audioInput = sound
        }
        var audioWritten = 0
        var audioFinished = false
        let audioChunk = audioSampleRate / 10
        /// Appends audio up to `seconds` while the writer takes it.
        func feedAudio(upTo seconds: Double) throws {
            guard let audioInput, let audioFormat else { return }
            let limit = seconds.isFinite ? min(audio.count, Int(max(0, seconds) * Double(audioSampleRate))) : audio.count
            while audioWritten < limit, audioInput.isReadyForMoreMediaData {
                let end = min(audio.count, audioWritten + audioChunk)
                guard audioInput.append(try audioBuffer(audio[audioWritten..<end], start: audioWritten, format: audioFormat))
                else { throw AnsiExportError.encodeFailed(writer.error?.localizedDescription ?? "MP4 audio") }
                audioWritten = end
            }
            // Finished audio must say so, or the writer waits for more before taking later video.
            if audioWritten >= audio.count, !audioFinished {
                audioFinished = true
                audioInput.markAsFinished()
            }
        }
        guard writer.startWriting() else { throw AnsiExportError.encodeFailed(writer.error?.localizedDescription ?? "MP4") }
        writer.startSession(atSourceTime: .zero)

        /// A short wait for the writer, giving up if it failed or the export was cancelled.
        func waitForWriter() throws {
            if writer.status == .failed { throw AnsiExportError.encodeFailed(writer.error?.localizedDescription ?? "MP4") }
            if isCancelled() { throw AnsiExportError.cancelled }
            Thread.sleep(forTimeInterval: 0.005)
        }
        var milliseconds: Int64 = 0
        var lastBuffer: CVPixelBuffer?
        do {
            for (index, frame) in frames.enumerated() {
                let image = index == 0 ? first : try render(frame)
                try feedAudio(upTo: Double(milliseconds) / 1000 + 1)
                while !input.isReadyForMoreMediaData {
                    // The writer may want audio past a long held frame before it takes more video;
                    // its own readiness keeps audio from running too far ahead.
                    try feedAudio(upTo: .infinity)
                    try waitForWriter()
                }
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
                lastBuffer = buffer
                milliseconds += max(1, Int64((frame.duration * 1000).rounded()))
                progress(Double(index + 1) / Double(frames.count))
            }
            // With a sound track the writer ends the video at its last sample, cutting the final
            // hold short; the last picture again just before the end keeps the hold.
            if audioInput != nil, let lastBuffer {
                while !input.isReadyForMoreMediaData {
                    try feedAudio(upTo: .infinity)
                    try waitForWriter()
                }
                guard adaptor.append(lastBuffer, withPresentationTime: CMTime(value: milliseconds - 1, timescale: 1000)) else {
                    throw AnsiExportError.encodeFailed(writer.error?.localizedDescription ?? "MP4 last frame")
                }
            }
            input.markAsFinished()
            if let audioInput {
                while !audioFinished {
                    if audioInput.isReadyForMoreMediaData {
                        try feedAudio(upTo: .infinity)
                    } else {
                        try waitForWriter()
                    }
                }
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let audioMilliseconds = Int64((Double(audio.count) / Double(audioSampleRate) * 1000).rounded(.up))
        writer.endSession(atSourceTime: CMTime(value: max(milliseconds, audioMilliseconds), timescale: 1000))
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
