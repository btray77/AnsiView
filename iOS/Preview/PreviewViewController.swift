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

    func preparePreviewOfFile(at url: URL) async throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let file = ArtFile(data: data, fileExtension: url.pathExtension)
        // The app's speed setting lives in the app's own defaults (no app group): the default speed here.
        let player = ArtPlayerViewController(file: file, name: url.lastPathComponent,
                                             baud: MobilePlaybackSpeed.defaultBaud)
        addChild(player)
        player.view.frame = view.bounds
        player.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(player.view)
        player.didMove(toParent: self)
    }
}
