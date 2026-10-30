import AnsiCore
import AppKit
import QuickLookUI

/// Quick Look (spacebar) preview for ANSI art. Uses a live view so animations play and text blinks.
final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let data = try Data(contentsOf: url)
        let player = AnsiPlayerViewController(source: ArtFile(data: data, fileExtension: url.pathExtension))
        // Left and Right keep moving between selected files in Quick Look; the scrub bar still works.
        player.handlesArrowKeys = false
        // Never sound on the spacebar: no ANSI music output, so music neither plays nor holds the
        // drawing, and art whose only movement is music stays static here (checked by a harness).
        player.music = nil
        addChild(player)
        player.view.frame = view.bounds
        player.view.autoresizingMask = [.width, .height]
        view.addSubview(player.view)
        preferredContentSize = player.idealViewSize
    }
}
