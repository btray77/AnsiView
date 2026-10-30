import AnsiCore
import AppKit

/// Copying from a viewer window's selection (copy and paste plan, rulings 8 and 9). App only:
/// the Quick Look extension compiles `Shared/` but not this file, and never turns selection on.
enum ViewerCopy {
    /// Where viewer copies go (a private pasteboard in tests).
    static var pasteboard = NSPasteboard.general

    /// Turns on drag selection, copying and the context menu for a player in an app window.
    static func enable(_ player: AnsiPlayerViewController) {
        player.allowsSelection = true
        if AnsiCanvasView.selectionMenu == nil { AnsiCanvasView.selectionMenu = contextMenu }
    }

    static func contextMenu(for canvas: AnsiCanvasView) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(AnsiCanvasView.copy(_:)), keyEquivalent: "").target = canvas
        let copyAs = NSMenuItem(title: "Copy As", action: nil, keyEquivalent: "")
        copyAs.submenu = ArtPasteboard.copyAsMenu(target: canvas)
        menu.addItem(copyAs)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(AnsiCanvasView.selectAll(_:)), keyEquivalent: "").target = canvas
        return menu
    }
}

extension AnsiCanvasView: NSMenuItemValidation {
    private func copySelection(_ kind: CellClipboard.Kind) {
        guard let clip = player?.selectionClipboard, ArtPasteboard.write(clip, kind: kind, to: ViewerCopy.pasteboard) else {
            NSSound.beep()
            return
        }
    }

    @objc func copy(_ sender: Any?) { copySelection(.all) }
    @objc func copyAsText(_ sender: Any?) { copySelection(.text) }
    @objc func copyAsANSI(_ sender: Any?) { copySelection(.ansi) }
    @objc func copyAsImage(_ sender: Any?) { copySelection(.image) }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(copyAsText(_:)), #selector(copyAsANSI(_:)), #selector(copyAsImage(_:)):
            return player?.selection != nil
        case #selector(selectAll(_:)):
            return player?.allowsSelection == true
        default:
            return true
        }
    }
}
