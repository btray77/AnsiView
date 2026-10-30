import AnsiCore
import Foundation

/// What a Finder Quick Action does with the files (plan 10 rulings 8 and 9): converts each beside
/// the original when the sandbox lets it, otherwise into `fallbackFolder` (Downloads), never
/// replacing a file that is already there.
enum QuickActionConversion {
    /// Converts the files one after another, so outputs with the same name cannot collide.
    static func convertAll(_ inputs: [URL], format: ArtActions.ImageFormat, fallbackFolder: URL) -> [Result<URL, Error>] {
        inputs.map { input in Result { try convert(input, format: format, fallbackFolder: fallbackFolder) } }
    }

    @discardableResult
    static func convert(_ input: URL, format: ArtActions.ImageFormat, fallbackFolder: URL) throws -> URL {
        let folder = input.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: folder.path) {
            let beside = ArtActions.outputURL(for: input, fileExtension: format.fileExtension, in: folder)
            do {
                try ArtActions.render(input, to: beside, format: format, scale: 2)
                return beside
            } catch {
                // Any refusal (the sandbox reports it in different ways) falls back to Downloads.
                // The export writes to a temporary folder first, so nothing partial is left here.
            }
        }
        let fallback = ArtActions.outputURL(for: input, fileExtension: format.fileExtension, in: fallbackFolder)
        try ArtActions.render(input, to: fallback, format: format, scale: 2)
        return fallback
    }
}
