import AnsiCore
import AppKit

// File > Share Image and Share Animation, sent through the responder chain to the focused art view.
extension AnsiCanvasView {
    @objc func shareImage(_ sender: Any?) {
        guard let player else { return }
        do {
            ShareController.show([try ShareController.prepareImage(from: player)], from: self)
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc func shareAnimation(_ sender: Any?) {
        guard let player, let window else { return }
        ShareController.prepareAnimation(from: player, in: window) { [weak self] url in
            guard let self else { return }
            ShareController.show([url], from: self)
        }
    }
}

/// Writes the frame on screen (a 2x PNG) or the playback (a 1x GIF) to a temporary folder and
/// offers it to the system share sheet.
@MainActor
enum ShareController {
    /// For checks: the names of the services the picker proposed.
    static var onServices: (([String]) -> Void)?
    private static let delegate = PickerDelegate()
    private static var cleanup: NSObjectProtocol?

    /// Removed when the app quits.
    static var shareFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AnsiView Share", isDirectory: true)
    }

    static func prepareImage(from player: AnsiPlayerViewController) throws -> URL {
        var settings = ExportSettings()
        settings.kind = .still(.png)
        settings.scale = 2
        let url = try freshURL(name(player), extension: "png")
        try AnsiExporter.export(player.source, screen: player.screen, settings: settings, to: url)
        return url
    }

    /// Exports the playback at the file's speed behind the progress sheet, then calls `ready`.
    static func prepareAnimation(from player: AnsiPlayerViewController, in window: NSWindow,
                                 ready: @escaping (URL) -> Void) {
        var settings = ExportSettings()
        settings.kind = .animation(.gif)
        settings.scale = 1
        settings.baud = player.speed.baud
        let source = player.source
        let url: URL
        do {
            url = try freshURL(name(player), extension: "gif")
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
            return
        }
        ExportController.runWithProgress(in: window, title: "Preparing Animation", work: { report, isCancelled in
            try AnsiExporter.export(source, settings: settings, to: url, progress: report, isCancelled: isCancelled)
        }, onSuccess: { _ in ready(url) })
    }

    /// Shows the share picker from the top centre of `view`.
    static func show(_ urls: [URL], from view: NSView) {
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = delegate
        let anchor = NSRect(x: view.bounds.midX - 1, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY - 2,
                            width: 2, height: 2)
        picker.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
    }

    private static func name(_ player: AnsiPlayerViewController) -> String {
        let base = player.fileURL?.deletingPathExtension().lastPathComponent ?? player.source.title ?? ""
        let clean = base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return clean.isEmpty ? "ANSI Art" : clean
    }

    /// `name.ext` in a new folder of its own, so shared files keep the art's name.
    private static func freshURL(_ name: String, extension ext: String) throws -> URL {
        if cleanup == nil {
            cleanup = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { _ in
                try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
                    .appendingPathComponent("AnsiView Share", isDirectory: true))
            }
        }
        let folder = shareFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name + "." + ext)
    }
}

private final class PickerDelegate: NSObject, NSSharingServicePickerDelegate {
    func sharingServicePicker(_ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                              proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        let names = proposed.map(\.title)
        MainActor.assumeIsolated { ShareController.onServices?(names) }
        return proposed
    }
}
