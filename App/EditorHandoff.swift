import AnsiCore
import AppKit
import os

/// File > Open in Moebius / Open in PabloDraw: hands the current art file to an installed editor.
enum EditorHandoff {
    enum Outcome: Equatable {
        case opened(app: URL)
        /// No art window, or the piece has no file of its own (an entry in a ZIP pack).
        case noFile
        case notInstalled
    }

    /// The file of the focused art window, or of the single piece selected in a gallery. Falls back
    /// to the frontmost window's art when nothing in the responder chain has a file (the app is not
    /// active, say).
    static func currentFile() -> URL? {
        let action = #selector(AnsiPlayerViewController.editorHandoffFile(_:))
        switch NSApp.target(forAction: action) {
        case let player as AnsiPlayerViewController: return player.fileURL
        case let gallery as GalleryViewController: return gallery.editorHandoffURL
        default: break
        }
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible }
        return window?.contentView.flatMap(player(in:))?.fileURL
    }

    /// The player whose art view is inside `view`.
    private static func player(in view: NSView) -> AnsiPlayerViewController? {
        if let canvas = view as? AnsiCanvasView { return canvas.player }
        for subview in view.subviews { if let found = player(in: subview) { return found } }
        return nil
    }

    /// Opens `file` with the editor app at `appURL` (nil when it is not installed).
    @discardableResult
    static func hand(_ file: URL?, appURL: URL?,
                     workspace: NSWorkspace = .shared,
                     completion: ((Error?) -> Void)? = nil) -> Outcome {
        guard let file else { return .noFile }
        guard let app = appURL else { return .notInstalled }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([file], withApplicationAt: app, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion?(error) }
        }
        return .opened(app: app)
    }

    /// The menu command: opens the current file, or explains why it cannot.
    static func open(in editor: ArtEditor) {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier)
        let file = currentFile()
        let outcome = hand(file, appURL: appURL) { error in
            if let error { NSAlert(error: error).runModal() }
        }
        Logger(subsystem: "com.traynham.ansiview", category: "editor")
            .info("Open in \(editor.name, privacy: .public): \(String(describing: outcome), privacy: .public)")
        switch outcome {
        case .opened:
            break
        case .noFile:
            let alert = NSAlert()
            alert.messageText = "No art file to open in \(editor.name)"
            alert.informativeText = "Open an art file first. Pieces inside a ZIP art pack have no file of "
                + "their own; open the pack's folder instead, or export the piece."
            alert.runModal()
        case .notInstalled:
            let message = editor.notInstalledMessage
            let alert = NSAlert()
            alert.messageText = message.title
            alert.informativeText = message.detail
            alert.addButton(withTitle: "Download \(editor.name)")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(editor.downloadPage) }
        }
    }
}

extension AnsiPlayerViewController {
    /// Marks the player as a source of a file for File > Open in (found through the responder chain).
    @objc func editorHandoffFile(_ sender: Any?) {}
}

extension GalleryViewController {
    @objc func editorHandoffFile(_ sender: Any?) {}

    /// The selected piece's file when exactly one piece with a file of its own is selected.
    var editorHandoffURL: URL? {
        guard selectedIndexes.count == 1, let index = selectedIndexes.first else { return nil }
        return collection.items[index].fileURL
    }
}
