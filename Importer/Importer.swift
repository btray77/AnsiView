import AnsiCore
import CoreServices
import Foundation

/// Spotlight importer entry point, called from PlugIn.c: records the SAUCE fields and the words in
/// the art. Shares `SpotlightFields` with the Core Spotlight import extension.
@_cdecl("AnsiViewImportURL")
func importURL(_ attributes: CFMutableDictionary, _ contentType: CFString, _ url: CFURL) -> DarwinBoolean {
    let fileURL = url as URL
    guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return false }
    let fields = SpotlightFields(ArtFile(data: data, fileExtension: fileURL.pathExtension))
    var values: [CFString: Any] = [
        kMDItemTextContent: fields.text,
        kMDItemPixelWidth: Int(fields.pixelSize.width),
        kMDItemPixelHeight: Int(fields.pixelSize.height),
    ]
    if let title = fields.title { values[kMDItemTitle] = title }
    if let author = fields.author { values[kMDItemAuthors] = [author] }
    if let group = fields.group { values[kMDItemOrganizations] = [group] }
    if let comment = fields.comment { values[kMDItemComment] = comment }
    if let font = fields.fontName { values[kMDItemFonts] = [font] }
    if let date = fields.date, let day = Calendar(identifier: .gregorian).date(from: date) {
        values[kMDItemContentCreationDate] = day
    }
    let dictionary = attributes as NSMutableDictionary
    for (key, value) in values { dictionary[key as String] = value }
    return true
}
