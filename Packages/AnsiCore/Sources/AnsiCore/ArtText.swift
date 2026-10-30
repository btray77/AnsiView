import CoreGraphics
import Foundation

/// The words in a piece of art, for Spotlight (and later VoiceOver).
public enum ArtText {
    /// At most this many characters are returned, however tall the art.
    public static let limit = 100_000

    /// The screen as lines of Unicode text. Block, shade and box drawing characters become spaces
    /// so the words stand out; trailing spaces and trailing empty lines are dropped.
    public static func plainText(_ screen: AnsiScreen) -> String {
        var lines: [String] = []
        var total = 0
        for row in screen.rows {
            var scalars = String.UnicodeScalarView()
            for cell in row.prefix(screen.columns) {
                let scalar = cell.scalar ?? (cell.code == 0 ? " " : CP437.unicode[Int(cell.code)])
                scalars.append((0x2500...0x259F).contains(scalar.value) ? " " : scalar)
            }
            var line = String(scalars)
            while line.last == " " { line.removeLast() }
            lines.append(line)
            total += line.count + 1
            if total > limit { break }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let text = lines.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) : text
    }
}

/// What the Spotlight importer records for a file.
public struct SpotlightFields {
    public let title: String?
    public let author: String?
    public let group: String?
    public let date: DateComponents?
    /// SAUCE comment lines joined with newlines.
    public let comment: String?
    public let fontName: String?
    /// "ANSI art", "XBin art" and so on.
    public let kind: String
    public let text: String
    /// Size at 1x: one point per font pixel, with the 4:3 stretch when the file asks for it.
    public let pixelSize: CGSize

    public init(_ file: ArtFile) {
        func nonEmpty(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }
        let sauce = file.sauce
        title = nonEmpty(sauce?.title)
        author = nonEmpty(sauce?.author)
        group = nonEmpty(sauce?.group)
        date = sauce?.date
        comment = nonEmpty(sauce?.comments.filter { !$0.isEmpty }.joined(separator: "\n"))
        fontName = nonEmpty(sauce?.fontName)
        kind = "\(file.format.displayName) art"
        let analysis = AnsiAnalysis(file)
        text = ArtText.plainText(analysis.finalScreen)
        let screen = analysis.finalScreen
        let cellWidth = screen.font.width + (file.ninePixel ? 1 : 0)
        let aspect = AnsiRenderer.pixelAspect(for: screen, ninePixel: file.ninePixel)
        pixelSize = CGSize(width: CGFloat(file.columns * cellWidth),
                           height: (CGFloat(analysis.canvasRows * screen.font.height) * aspect).rounded())
    }
}
