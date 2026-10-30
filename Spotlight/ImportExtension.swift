import AnsiCore
import CoreSpotlight
import Foundation

/// Spotlight importer: indexes the SAUCE fields and the art's text, so a search for a title,
/// an artist, a group or words drawn in the art finds the file.
final class ImportExtension: CSImportExtension {
    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let fields = SpotlightFields(ArtFile(data: data, fileExtension: url.pathExtension))
        if let title = fields.title { attributes.title = title }
        if let author = fields.author {
            attributes.authorNames = [author]
            attributes.creator = author
        }
        if let group = fields.group { attributes.organizations = [group] }
        if let date = fields.date, let day = Calendar(identifier: .gregorian).date(from: date) {
            attributes.contentCreationDate = day
        }
        if let comment = fields.comment { attributes.comment = comment }
        if let font = fields.fontName { attributes.fontNames = [font] }
        attributes.kind = fields.kind
        attributes.textContent = fields.text
        attributes.pixelWidth = NSNumber(value: Double(fields.pixelSize.width))
        attributes.pixelHeight = NSNumber(value: Double(fields.pixelSize.height))
    }
}
