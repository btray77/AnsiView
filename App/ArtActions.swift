import AnsiCore
import Foundation
import UniformTypeIdentifiers

/// Render and convert without a window (plan 10 rulings 6 to 9): used by the Shortcuts actions,
/// the AppleScript commands and the Finder Quick Actions.
enum ArtActions {
    enum ImageFormat: String, CaseIterable {
        case png, jpeg, gif

        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        var contentType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .gif: return .gif
            }
        }
    }

    /// Speed an animated GIF plays the art at (the viewer's default speed is slower; this keeps
    /// Quick Action GIFs short).
    static let gifBaud = 9600

    /// The art types the actions take (as the app declares them).
    static let artTypes: [UTType] = [UTType(importedAs: "com.traynham.ansiview.ans"),
                                     UTType(importedAs: "com.traynham.ansiview.asc"), .data]

    static func load(_ url: URL) throws -> ArtFile {
        ArtFile(data: try Data(contentsOf: url), fileExtension: url.pathExtension)
    }

    /// Writes the finished art (PNG, JPEG) or its playback (GIF) to `output`.
    static func render(_ input: URL, to output: URL, format: ImageFormat, scale: Int) throws {
        var settings = ExportSettings()
        settings.scale = max(1, min(4, scale))
        switch format {
        case .png: settings.kind = .still(.png)
        case .jpeg: settings.kind = .still(.jpeg)
        case .gif:
            settings.kind = .animation(.gif)
            settings.baud = gifBaud
        }
        try AnsiExporter.export(try load(input), settings: settings, to: output)
    }

    /// The finished art as text (UTF-8, CP437, modern ANSI or HTML).
    static func convert(_ input: URL, format: TextFormat) throws -> Data {
        TextConvert.data(AnsiAnalysis(try load(input)).finalScreen, format: format)
    }

    /// `input`'s name with a new extension in `folder`, never one already there.
    static func outputURL(for input: URL, fileExtension: String, in folder: URL) -> URL {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var naming = BatchNaming(existing: Set(existing))
        return folder.appendingPathComponent(naming.name(for: input.lastPathComponent, fileExtension: fileExtension))
    }
}
