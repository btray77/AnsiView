#if DEBUG
import QuickLook
import QuickLookThumbnailing
import UIKit

/// Debug builds only: shows a file in the system Quick Look viewer, which on iOS uses the app's
/// preview extension for its types, and asks the system thumbnailer for a file's thumbnail (which
/// uses the thumbnail extension). Lets the simulator exercise both without taps.
@MainActor
enum DebugQuickLook {
    private final class Source: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }

    private static var source: Source?

    static func present(_ url: URL) {
        // Wait for the window to exist.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.windows.first?.rootViewController else { return }
            let source = Source(url: url)
            Self.source = source
            let controller = QLPreviewController()
            controller.dataSource = source
            controller.modalPresentationStyle = .fullScreen
            root.present(controller, animated: false)
        }
    }

    /// Writes the thumbnail to tmp/thumbnail.png in the app's container and logs what was made.
    static func thumbnail(_ url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 256, height: 256),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail.png")
            if let representation, let data = representation.uiImage.pngData() {
                try? data.write(to: out)
                NSLog("AnsiView thumbnail: type=%ld size=%@ written to %@", representation.type.rawValue,
                      NSCoder.string(for: representation.uiImage.size), out.path)
            } else {
                NSLog("AnsiView thumbnail failed: %@", String(describing: error))
            }
        }
    }
}
#endif
