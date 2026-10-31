import AnsiCore
import QuickLook
import UIKit

/// Quick Look preview for ANSI art in the Files app (and anywhere iOS shows Quick Look): the same
/// player as the app, so animations play at 2400 baud and text blinks. No sound, no network.
final class PreviewViewController: UIViewController, QLPreviewingController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    /// The app's limit: no art format needs more.
    static let maximumBytes = 16 * 1024 * 1024

    func preparePreviewOfFile(at url: URL) async throws {
        // Read and played through once off the main thread; refused over the size limit.
        let playback = try await Task.detached(priority: .userInitiated) { () throws -> ArtPlayback in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > Self.maximumBytes { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return ArtPlayback(ArtFile(data: data, fileExtension: url.pathExtension))
        }.value
        // The app's speed setting lives in the app's own defaults (no app group): the default speed here.
        let player = ArtPlayerViewController(playback: playback, name: url.lastPathComponent,
                                             baud: MobilePlaybackSpeed.defaultBaud)
        addChild(player)
        player.view.frame = view.bounds
        player.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(player.view)
        player.didMove(toParent: self)
    }
}
