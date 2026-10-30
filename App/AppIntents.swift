import AnsiCore
import AppIntents
import Foundation
import UniformTypeIdentifiers

// Shortcuts actions (plan 10 ruling 6). They run without opening a window.

enum ArtImageFormat: String, AppEnum {
    case png, jpeg, gif

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Image Format"
    static var caseDisplayRepresentations: [ArtImageFormat: DisplayRepresentation] = [
        .png: "PNG", .jpeg: "JPEG", .gif: "Animated GIF",
    ]

    var format: ArtActions.ImageFormat { ArtActions.ImageFormat(rawValue: rawValue) ?? .png }
}

enum ArtTextFormat: String, AppEnum {
    case utf8, text, ansi, ansi256, html

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Text Format"
    static var caseDisplayRepresentations: [ArtTextFormat: DisplayRepresentation] = [
        .utf8: "UTF-8 Text", .text: "CP437 Text", .ansi: "ANSI (24 bit colour)",
        .ansi256: "ANSI (256 colours)", .html: "HTML",
    ]

    var format: TextFormat { TextFormat(rawValue: rawValue) ?? .utf8 }
}

/// Copies an intent's file into a temporary folder under its own name, so the art's extension
/// (and with it the format) is known.
private func temporaryCopy(of file: IntentFile) throws -> (url: URL, folder: URL) {
    // A rendered image is handed to Shortcuts from its folder, so folders from earlier runs (more
    // than an hour old) are removed here instead.
    let temporary = FileManager.default.temporaryDirectory
    let old = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.creationDateKey])) ?? []
    for url in old where url.lastPathComponent.hasPrefix("AnsiView-intent-") {
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        if created < Date().addingTimeInterval(-3600) { try? FileManager.default.removeItem(at: url) }
    }
    let folder = temporary.appendingPathComponent("AnsiView-intent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = file.filename.isEmpty ? "art.ans" : (file.filename as NSString).lastPathComponent
    let url = folder.appendingPathComponent(name)
    try file.data.write(to: url)
    return (url, folder)
}

struct RenderArtImageIntent: AppIntent {
    static var title: LocalizedStringResource = "Render ANSI Art to Image"
    static var description = IntentDescription(
        "Draws an ANSI, ASCII, BIN or XBin art file with its original font and colours, as a PNG or JPEG of the finished art or an animated GIF of it being drawn.")
    static var openAppWhenRun = false

    @Parameter(title: "Art File", supportedTypeIdentifiers: ["com.traynham.ansiview.ans", "com.traynham.ansiview.asc", "public.data"])
    var file: IntentFile

    @Parameter(title: "Format", default: .png)
    var format: ArtImageFormat

    @Parameter(title: "Scale", description: "Pixels per font pixel (1 is 640 pixels wide for 80 columns).",
               default: 2, inclusiveRange: (1, 4))
    var scale: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Render \(\.$file) as \(\.$format)") { \.$scale }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let input = try temporaryCopy(of: file)
        let format = format.format
        let output = input.folder.appendingPathComponent(
            (input.url.deletingPathExtension().lastPathComponent) + "." + format.fileExtension)
        try ArtActions.render(input.url, to: output, format: format, scale: scale)
        let result = IntentFile(fileURL: output, filename: output.lastPathComponent, type: format.contentType)
        return .result(value: result)
    }
}

struct ConvertArtToTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert ANSI Art to Text"
    static var description = IntentDescription(
        "Turns an art file into UTF-8 or CP437 text, ANSI for modern terminals, or HTML with its colours.")
    static var openAppWhenRun = false

    @Parameter(title: "Art File", supportedTypeIdentifiers: ["com.traynham.ansiview.ans", "com.traynham.ansiview.asc", "public.data"])
    var file: IntentFile

    @Parameter(title: "Format", default: .utf8)
    var format: ArtTextFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$file) to \(\.$format)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let input = try temporaryCopy(of: file)
        defer { try? FileManager.default.removeItem(at: input.folder) }
        let data = try ArtActions.convert(input.url, format: format.format)
        // CP437 text is not UTF-8; Shortcuts gets it with each byte shown as its CP437 character.
        let text = format == .text ? String(String.UnicodeScalarView(data.map { CP437.unicode[Int($0)] }))
                                   : String(decoding: data, as: UTF8.self)
        return .result(value: text)
    }
}

/// Makes the actions show up in Shortcuts without the user building anything.
struct AnsiViewShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RenderArtImageIntent(), phrases: ["Render art with \(.applicationName)"],
                    shortTitle: "Render to Image", systemImageName: "photo")
        AppShortcut(intent: ConvertArtToTextIntent(), phrases: ["Convert art to text with \(.applicationName)"],
                    shortTitle: "Convert to Text", systemImageName: "doc.plaintext")
    }
}
