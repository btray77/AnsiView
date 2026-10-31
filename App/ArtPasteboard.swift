import AnsiCore
import AppKit

/// Puts copied cells on an `NSPasteboard` and reads pastes back (copy and paste plan, rulings 1 to 4).
enum ArtPasteboard {
    /// Writes a copy of `kind` as one pasteboard item, replacing what was there. Cells and text are
    /// written at once; the picture is promised and drawn only when an app asks for it, so a big
    /// selection copies without a pause.
    @discardableResult
    static func write(_ clip: CellClipboard, kind: CellClipboard.Kind, to board: NSPasteboard) -> Bool {
        let immediate = clip.immediateRepresentations(kind)
        let deferred = clip.deferredImageTypes(kind)
        guard !immediate.isEmpty || !deferred.isEmpty else { return false }
        board.clearContents()
        let item = NSPasteboardItem()
        for representation in immediate {
            item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
        }
        if !deferred.isEmpty {
            let provider = ImageProvider(clip)
            ImageProvider.current = provider
            item.setDataProvider(provider, forTypes: deferred.map { NSPasteboard.PasteboardType($0) })
        }
        return board.writeObjects([item])
    }

    /// Draws the promised picture on request. The latest one is kept alive until the pasteboard
    /// is done with it (another copy replaces it).
    private final class ImageProvider: NSObject, NSPasteboardItemDataProvider {
        static var current: ImageProvider?
        let clip: CellClipboard

        init(_ clip: CellClipboard) { self.clip = clip }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            if let data = clip.imageData(forType: type.rawValue) { item.setData(data, forType: type) }
        }

        func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
            if Self.current === self { Self.current = nil }
        }
    }

    /// After a Discord copy: a sheet on `window` when the block is longer than one Discord message.
    static func warnIfTooLongForDiscord(_ clip: CellClipboard, kind: CellClipboard.Kind, window: NSWindow?) {
        guard kind == .discord, let window else { return }
        let count = ChatCodeBlock.characterCount(ChatCodeBlock.discord(clip.screen))
        guard count > ChatCodeBlock.discordLimit else { return }
        let alert = NSAlert()
        alert.messageText = "Copied, but too long for one Discord message"
        alert.informativeText = "The code block is \(count.formatted()) characters; Discord takes \(ChatCodeBlock.discordLimit.formatted()) (4,000 with Nitro). Select a smaller part of the art and copy again. Colour codes count as characters."
        alert.beginSheetModal(for: window)
    }

    /// The Copy As submenu for a context menu: Text, ANSI and Image, sent to `target` (the editor
    /// canvas or the viewer canvas, which both answer these actions).
    static func copyAsMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: "Copy As")
        let items: [(String, Selector)] = [
            ("Text", NSSelectorFromString("copyAsText:")),
            ("ANSI (escape codes, for terminals)", NSSelectorFromString("copyAsANSI:")),
            ("Image", NSSelectorFromString("copyAsImage:")),
            ("Discord (ANSI colour code block)", NSSelectorFromString("copyAsDiscord:")),
            ("Slack (plain code block)", NSSelectorFromString("copyAsSlack:")),
        ]
        for (title, action) in items {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = target
        }
        return menu
    }

    /// What a paste would bring in.
    enum Content {
        case cells(CanvasRegion)
        case image(CGImage)
        case text(String)
    }

    static func canPaste(_ board: NSPasteboard) -> Bool {
        CellClipboard.pasteChoice(types: (board.types ?? []).map(\.rawValue)) != nil
    }

    /// Cells, then AnsiView's ANSI text and any text with escape codes (read as art), then a
    /// picture or plain text (ruling 4).
    static func read(_ board: NSPasteboard) -> Content? {
        switch CellClipboard.pasteChoice(types: (board.types ?? []).map(\.rawValue)) {
        case .cells:
            return board.data(forType: NSPasteboard.PasteboardType(CellClipboard.cellsType))
                .flatMap(CellClipboard.region(fromCells:)).map(Content.cells)
        case .ansi:
            let text = board.data(forType: NSPasteboard.PasteboardType(CellClipboard.ansiType))
                .map { String(decoding: $0, as: UTF8.self) }
            return text.flatMap(CellClipboard.region(fromANSI:)).map(Content.cells)
        case .image(let type):
            return board.data(forType: NSPasteboard.PasteboardType(type))
                .flatMap { try? ImageToAnsi.load($0) }.map(Content.image)
        case .text:
            guard let text = board.string(forType: .string) else { return nil }
            if CellClipboard.looksLikeANSI(text), let region = CellClipboard.region(fromANSI: text) { return .cells(region) }
            return .text(text)
        case nil:
            return nil
        }
    }
}
