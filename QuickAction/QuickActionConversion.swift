import AnsiCore
import Foundation

/// What a Finder Quick Action does with one file (plan 10 rulings 8 and 9): converts it beside the
/// original when the sandbox lets it, otherwise into `fallbackFolder` (Downloads), never
/// replacing a file that is already there.
enum QuickActionConversion {
    @discardableResult
    static func convert(_ input: URL, format: ArtActions.ImageFormat, fallbackFolder: URL) throws -> URL {
        let beside = ArtActions.outputURL(for: input, fileExtension: format.fileExtension, in: input.deletingLastPathComponent())
        do {
            try ArtActions.render(input, to: beside, format: format, scale: 2)
            return beside
        } catch let error as CocoaError where error.isPermissionError {
            let fallback = ArtActions.outputURL(for: input, fileExtension: format.fileExtension, in: fallbackFolder)
            try ArtActions.render(input, to: fallback, format: format, scale: 2)
            return fallback
        }
    }
}

extension CocoaError {
    /// The write was refused (the sandbox, or a read only folder).
    var isPermissionError: Bool {
        code == .fileWriteNoPermission || code == .fileReadNoPermission || code == .fileWriteVolumeReadOnly
            || (underlying as? POSIXError)?.code == .EPERM || (underlying as? POSIXError)?.code == .EACCES
    }

    private var underlying: Error? { userInfo[NSUnderlyingErrorKey] as? Error }
}
