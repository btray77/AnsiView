import AnsiCore
import AppKit

/// Puts copied cells on an `NSPasteboard` and reads pastes back (copy and paste plan, rulings 1 to 4).
enum ArtPasteboard {
    /// Writes every representation of `kind` as one pasteboard item, replacing what was there.
    @discardableResult
    static func write(_ clip: CellClipboard, kind: CellClipboard.Kind, to board: NSPasteboard) -> Bool {
        let representations = clip.representations(kind)
        guard !representations.isEmpty else { return false }
        board.clearContents()
        let item = NSPasteboardItem()
        for representation in representations {
            item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
        }
        return board.writeObjects([item])
    }

    /// What a paste would bring in.
    enum Content {
        case cells(CanvasRegion)
        case image(CGImage)
        case text(String)
    }

    /// The Copy As submenu for a context menu: Text, ANSI and Image, sent to `target` (the editor
    /// canvas or the viewer canvas, which both answer these actions).
    static func copyAsMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: "Copy As")
        let items: [(String, Selector)] = [
            ("Text", NSSelectorFromString("copyAsText:")),
            ("ANSI (escape codes, for terminals)", NSSelectorFromString("copyAsANSI:")),
            ("Image", NSSelectorFromString("copyAsImage:")),
        ]
        for (title, action) in items {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = target
        }
        return menu
    }

    static func canPaste(_ board: NSPasteboard) -> Bool {
        CellClipboard.pasteChoice(types: (board.types ?? []).map(\.rawValue)) != nil
    }

    static func read(_ board: NSPasteboard) -> Content? {
        switch CellClipboard.pasteChoice(types: (board.types ?? []).map(\.rawValue)) {
        case .cells:
            return board.data(forType: NSPasteboard.PasteboardType(CellClipboard.cellsType))
                .flatMap(CellClipboard.region(fromCells:)).map(Content.cells)
        case .image(let type):
            return board.data(forType: NSPasteboard.PasteboardType(type))
                .flatMap { try? ImageToAnsi.load($0) }.map(Content.image)
        case .text:
            return board.string(forType: .string).map(Content.text)
        case nil:
            return nil
        }
    }
}
