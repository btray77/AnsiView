import CoreGraphics
import Foundation
import ImageIO

/// What a copy of selected cells puts on the pasteboard (copy and paste plan, rulings 1 to 4):
/// lossless cells for AnsiView, plain text, ANSI escape text and a picture. AppKit free, so the
/// app writes `representations` to an `NSPasteboard` as one item.
public struct CellClipboard {
    /// Which representations a copy writes: everything (Copy) or one kind (Copy As).
    public enum Kind: CaseIterable { case all, text, ansi, image, discord, slack }

    /// AnsiView's lossless cells (characters, exact colours, blink).
    public static let cellsType = "com.traynham.ansiview.cells"
    /// UTF-8 text with 24 bit SGR colour codes, for terminals.
    public static let ansiType = "com.traynham.ansiview.ansi"
    public static let textType = "public.utf8-plain-text"
    public static let pngType = "public.png"
    public static let tiffType = "public.tiff"
    public static let jpegType = "public.jpeg"
    /// Image types a paste can convert, in order of preference.
    public static let imageTypes = [pngType, tiffType, jpegType]

    /// Output pixels per font pixel in the picture.
    public static let imageScale = 2

    public let region: CanvasRegion
    public let font: BitmapFont
    public let ninePixel: Bool

    public init(region: CanvasRegion, font: BitmapFont = .vga, ninePixel: Bool = false) {
        self.region = region
        self.font = font
        self.ninePixel = ninePixel
    }

    public var screen: AnsiScreen {
        var screen = AnsiScreen(columns: region.width, rows: region.cells)
        screen.font = font
        return screen
    }

    /// The `AVCELLS1` bytes the editor reads back exactly.
    public var cellsData: Data { CanvasEditor.encode(region) }

    /// The characters as Unicode text (CP437 mapped), trailing spaces trimmed.
    public var text: String { TextConvert.utf8Text(screen) }

    /// UTF-8 text with 24 bit colour escape codes.
    public var ansiText: String { TextConvert.modernANSI(screen, colors: .trueColor) }

    /// The cells drawn with the font at `imageScale`, blink shown. Nil when the renderer could not
    /// draw every row (over its memory limit even at scale 1), so a picture is never cut short.
    public func image() -> CGImage? {
        // Known not to fit even at scale 1: skip the (slow, partial) render.
        guard canDrawImage else { return nil }
        let options = RenderOptions(font: font, ninePixel: ninePixel, scale: Self.imageScale, blinkVisible: true)
        guard let rendered = AnsiRenderer.render(screen, options: options), rendered.rows == region.height else { return nil }
        return rendered.image
    }

    /// True when the selection can be drawn whole (decided from its size, without drawing).
    public var canDrawImage: Bool {
        guard region.width > 0, region.height > 0 else { return false }
        let cellWidth = font.width + (ninePixel ? 1 : 0)
        return region.width * cellWidth * region.height * font.height * 4 <= AnsiRenderer.maxImageBytes
    }

    /// The text representations of a copy, cheap enough to write at once.
    public func immediateRepresentations(_ kind: Kind) -> [(type: String, data: Data)] {
        switch kind {
        case .all:
            return [(Self.cellsType, cellsData), (Self.textType, Data(text.utf8)), (Self.ansiType, Data(ansiText.utf8))]
        case .text:
            return [(Self.textType, Data(text.utf8))]
        case .ansi:
            let ansi = Data(ansiText.utf8)
            return [(Self.textType, ansi), (Self.ansiType, ansi)]
        case .image:
            return []
        case .discord:
            return [(Self.textType, Data(ChatCodeBlock.discord(screen).utf8))]
        case .slack:
            return [(Self.textType, Data(ChatCodeBlock.slack(screen).utf8))]
        }
    }

    /// The picture types a copy offers, drawn only when an app asks (`imageData(forType:)`).
    public func deferredImageTypes(_ kind: Kind) -> [String] {
        guard kind == .all || kind == .image, canDrawImage else { return [] }
        return [Self.pngType, Self.tiffType]
    }

    /// PNG or TIFF bytes of the picture, or nil for another type or when it cannot be drawn.
    public func imageData(forType type: String) -> Data? {
        switch type {
        case Self.pngType: return pngData()
        case Self.tiffType: return tiffData()
        default: return nil
        }
    }

    public func pngData() -> Data? { image().flatMap { Self.encode($0, type: Self.pngType, properties: [:]) } }

    public func tiffData() -> Data? {
        image().flatMap {
            Self.encode($0, type: Self.tiffType, properties: [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5] as CFDictionary,
            ])
        }
    }

    /// The pasteboard types and bytes for a copy of `kind`, in the order they are offered.
    /// Every representation with its bytes (the pictures drawn now), in the order they are offered.
    public func representations(_ kind: Kind) -> [(type: String, data: Data)] {
        var out = immediateRepresentations(kind)
        let types = deferredImageTypes(kind)
        if !types.isEmpty, let image = image() {
            if let png = Self.encode(image, type: Self.pngType, properties: [:]) { out.append((Self.pngType, png)) }
            if let tiff = Self.encode(image, type: Self.tiffType, properties: Self.tiffProperties) { out.append((Self.tiffType, tiff)) }
        }
        return out
    }

    private static let tiffProperties: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5] as CFDictionary,
    ]

    /// True when text holds escape sequences (ANSI art copied from a terminal or as ANSI).
    public static func looksLikeANSI(_ text: String) -> Bool { text.contains("\u{1B}[") }

    /// ANSI text read as art: the cells up to the last one drawn on, or nil when nothing is.
    public static func region(fromANSI text: String) -> CanvasRegion? {
        let screen = AnsiParser.parse(Data(text.utf8), fileExtension: "ans")
        let rows = TextConvert.trimmedRows(screen)
        let blank = AnsiCell()
        let width = rows.map { row in (row.prefix(screen.columns).lastIndex { $0 != blank } ?? -1) + 1 }.max() ?? 0
        guard width > 0 else { return nil }
        let clipped = min(width, EditCanvas.maxColumns)
        return CanvasRegion(cells: rows.prefix(AnsiTerminal.maxRows).map { row in
            (0..<clipped).map { $0 < row.count ? row[$0] : blank }
        })
    }

    /// Cells copied by AnsiView, or nil for other data.
    public static func region(fromCells data: Data) -> CanvasRegion? { CanvasEditor.decode(data) }

    /// What a paste reads from a pasteboard offering `types` (ruling 4).
    public enum PasteChoice: Equatable {
        case cells
        /// AnsiView's ANSI text type, read back as art.
        case ansi
        case image(String)
        case text
    }

    /// Cells first; then a picture when there is no plain text (a screenshot, a copied web image);
    /// then text (apps such as Word put a picture of copied text beside the text); then a picture.
    public static func pasteChoice(types: [String]) -> PasteChoice? {
        if types.contains(cellsType) { return .cells }
        if types.contains(ansiType) { return .ansi }
        let image = imageTypes.first { types.contains($0) }
        let hasText = types.contains(textType) || types.contains("NSStringPboardType")
        if let image, !hasText { return .image(image) }
        if hasText { return .text }
        return image.map { .image($0) }
    }

    /// Columns for a pasted picture (ruling 7): the selection's width, else the image's pixel
    /// width capped at the canvas width; at least 1.
    public static func imageColumns(imageWidth: Int, selectionWidth: Int?, canvasColumns: Int) -> Int {
        let columns = selectionWidth ?? min(imageWidth, canvasColumns)
        return min(EditCanvas.maxColumns, max(1, columns))
    }

    public static func encode(_ image: CGImage, type: String, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension AnsiScreen {
    /// The cells inside `rect` clipped to the screen's width and rows; short rows are padded with blanks.
    public func region(_ rect: CellRect) -> CanvasRegion {
        let x0 = max(0, rect.x), y0 = max(0, rect.y)
        let x1 = min(columns, rect.x + rect.width), y1 = min(rows.count, rect.y + rect.height)
        guard x1 > x0, y1 > y0 else { return CanvasRegion(cells: []) }
        return CanvasRegion(cells: (y0..<y1).map { y in
            (x0..<x1).map { x in x < rows[y].count ? rows[y][x] : AnsiCell() }
        })
    }
}

/// Maps between points in a view that shows a grid of cells stretched to its size and the cells.
public enum CellGrid {
    /// The cell under `point` (top left origin), clamped to the grid.
    public static func cell(at point: CGPoint, in size: CGSize, columns: Int, rows: Int) -> (x: Int, y: Int) {
        guard size.width > 0, size.height > 0, columns > 0, rows > 0 else { return (0, 0) }
        let x = Int(floor(point.x / (size.width / CGFloat(columns))))
        let y = Int(floor(point.y / (size.height / CGFloat(rows))))
        return (min(columns - 1, max(0, x)), min(rows - 1, max(0, y)))
    }

    /// The area `rect` covers, in the view's points (top left origin).
    public static func rect(for rect: CellRect, in size: CGSize, columns: Int, rows: Int) -> CGRect {
        guard columns > 0, rows > 0 else { return .zero }
        let w = size.width / CGFloat(columns), h = size.height / CGFloat(rows)
        return CGRect(x: CGFloat(rect.x) * w, y: CGFloat(rect.y) * h, width: CGFloat(rect.width) * w, height: CGFloat(rect.height) * h)
    }
}
