import Foundation

/// Where an installed font came from.
public enum FontSource: String, Codable {
    /// Made for AnsiView (OriginalFonts).
    case original
    /// The FIGlet 2.2.5 distribution (New BSD), bundled.
    case figletDistribution
    /// Imported by the user into the app's font folder.
    case user

    public var label: String {
        switch self {
        case .original: return "AnsiView original"
        case .figletDistribution: return "FIGlet 2.2.5 (New BSD)"
        case .user: return "Imported"
        }
    }
}

/// One installed font (a TDF file with five fonts gives five entries).
public struct FontEntry: Identifiable, Equatable {
    /// Stable key: source, file name and index ("user/pack.tdf#2").
    public let id: String
    public let name: String
    public let fileName: String
    public let index: Int
    public let source: FontSource
    /// The file on disk (user fonts and bundled FIGlet fonts); nil for the generated originals.
    public let url: URL?
    public let font: TextArtFont

    public var category: TextArtCategory { font.category }
    public var kindLabel: String { category.label }

    var searchText: String {
        "\(name) \(fileName) \(kindLabel) \(source.label)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

public enum FontLibraryError: LocalizedError, Equatable {
    case unknownFormat
    case bundled

    public var errorDescription: String? {
        switch self {
        case .unknownFormat: return "This is not a TheDraw (.tdf) or FIGlet (.flf, .tlf) font file."
        case .bundled: return "Fonts that come with AnsiView cannot be removed."
        }
    }
}

/// Reads the fonts in one file of either kind.
public enum FontLoader {
    public static let extensions: Set<String> = ["tdf", "flf", "tlf"]

    public static func fonts(in data: Data, name fileName: String) throws -> [TextArtFont] {
        if TDFFile.isTDF(data) { return try TDFFile.parse(data).fonts.map { .tdf($0) } }
        if FIGletFont.isFIGlet(data) {
            let base = (fileName as NSString).deletingPathExtension
            return [.figlet(try FIGletFont.parse(data, name: base.isEmpty ? "FIGlet" : base))]
        }
        throw FontLibraryError.unknownFormat
    }
}

/// The installed fonts: AnsiView's originals, the bundled FIGlet fonts and the user's imports
/// in `directory` (plan ruling 15). Not thread safe: use it from one thread (the main thread).
public final class FontLibrary {
    public struct ImportReport: Equatable {
        public struct Failure: Equatable {
            public let file: String
            public let reason: String
        }
        public var filesAdded = 0
        public var fontsAdded = 0
        public var duplicates = 0
        public var failures: [Failure] = []

        /// A one line summary for the user.
        public var summary: String {
            var parts = ["\(fontsAdded) font\(fontsAdded == 1 ? "" : "s") from \(filesAdded) file\(filesAdded == 1 ? "" : "s") imported"]
            if duplicates > 0 { parts.append("\(duplicates) already installed") }
            if !failures.isEmpty { parts.append("\(failures.count) could not be read") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// At most this many files (zip entries included) are looked at in one import.
    public var maxImportFiles = 2000
    /// Files larger than this are refused before they are read.
    public var maxImportFileSize = 64 << 20

    public let directory: URL
    public private(set) var entries: [FontEntry] = []
    public private(set) var favourites: Set<String> = []
    /// Most recently used first, at most 20.
    public private(set) var recent: [String] = []
    public var sampleText = "AnsiView" { didSet { save() } }
    /// Warnings from reading the user's folder (damaged files).
    public private(set) var loadWarnings: [String] = []
    /// Goes up every time the installed fonts are read again (an import or a removal).
    public private(set) var revision = 0

    /// The folder in the app's container (sandbox safe), created when missing.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AnsiView/Fonts", isDirectory: true)
    }

    private static let bundled: [FontEntry] = {
        var list: [FontEntry] = OriginalFonts.tdfFonts.enumerated().map { index, font in
            FontEntry(id: "original/AnsiView.tdf#\(index)", name: font.name, fileName: "AnsiView.tdf", index: index,
                      source: .original, url: nil, font: .tdf(font))
        }
        if let contour = OriginalFonts.figletFont {
            list.append(FontEntry(id: "original/AV Contour.flf#0", name: "AV Contour", fileName: "AV Contour.flf", index: 0,
                                  source: .original, url: nil, font: .figlet(contour)))
        }
        for url in FIGletFont.bundledURLs {
            guard let data = try? Data(contentsOf: url),
                  let font = try? FIGletFont.parse(data, name: url.deletingPathExtension().lastPathComponent) else { continue }
            list.append(FontEntry(id: "figlet/\(url.lastPathComponent)#0", name: font.name, fileName: url.lastPathComponent,
                                  index: 0, source: .figletDistribution, url: url, font: .figlet(font)))
        }
        return list
    }()

    public init(directory: URL = FontLibrary.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadSettings()
        reload()
    }

    public var userEntries: [FontEntry] { entries.filter { $0.source == .user } }

    /// Rereads the user's folder.
    public func reload() {
        var list = Self.bundled
        loadWarnings = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        where FontLoader.extensions.contains(url.pathExtension.lowercased()) {
            do {
                let fonts = try FontLoader.fonts(in: Data(contentsOf: url), name: url.lastPathComponent)
                for (index, font) in fonts.enumerated() {
                    list.append(FontEntry(id: "user/\(url.lastPathComponent)#\(index)", name: font.name,
                                          fileName: url.lastPathComponent, index: index, source: .user, url: url, font: font))
                }
            } catch {
                loadWarnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        entries = list
        revision += 1
    }

    // MARK: Import (ruling 15)

    /// Imports font files, folders (searched recursively) and .zip packs.
    @discardableResult
    public func importFonts(from urls: [URL]) -> ImportReport {
        var report = ImportReport()
        var candidates: [(name: String, data: Data)] = []
        var full: Bool { candidates.count + report.failures.count >= maxImportFiles }
        /// Mac zips carry resource forks as `__MACOSX/._NAME` entries: not fonts (review M5).
        func isResourceFork(_ path: String) -> Bool {
            path.hasPrefix("__MACOSX/") || path.contains("/__MACOSX/") || (path as NSString).lastPathComponent.hasPrefix("._")
        }
        func tooLarge(_ url: URL) -> Bool {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > maxImportFileSize else { return false }
            report.failures.append(.init(file: url.lastPathComponent, reason: "This file is too large to be a font (\(size / 1_048_576) MB)."))
            return true
        }
        func consider(_ url: URL) {
            guard !full else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "zip" {
                guard !tooLarge(url) else { return }
                guard let data = try? Data(contentsOf: url), let zip = try? ZipArchive(data: data) else {
                    report.failures.append(.init(file: url.lastPathComponent, reason: "The ZIP archive could not be read."))
                    return
                }
                for entry in zip.entries where !full && !isResourceFork(entry.path)
                    && FontLoader.extensions.contains((entry.name as NSString).pathExtension.lowercased()) {
                    if let bytes = try? zip.data(for: entry) {
                        candidates.append((entry.name, bytes))
                    } else {
                        report.failures.append(.init(file: entry.name, reason: "This ZIP entry could not be unpacked."))
                    }
                }
            } else if FontLoader.extensions.contains(ext), !isResourceFork(url.lastPathComponent), !tooLarge(url) {
                if let data = try? Data(contentsOf: url) { candidates.append((url.lastPathComponent, data)) }
            }
        }
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                // The walk stops at the cap (choosing the home folder must not walk all of it).
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
                while !full, let item = walker?.nextObject() as? URL { consider(item) }
            } else {
                consider(url)
            }
        }
        let installed = Set(userEntries.compactMap { $0.url }.compactMap { try? Data(contentsOf: $0) })
        var added: Set<Data> = []
        for candidate in candidates {
            let fonts: [TextArtFont]
            do {
                fonts = try FontLoader.fonts(in: candidate.data, name: candidate.name)
            } catch {
                report.failures.append(.init(file: candidate.name, reason: error.localizedDescription))
                continue
            }
            if installed.contains(candidate.data) || added.contains(candidate.data) {
                report.duplicates += 1
                continue
            }
            let target = freeURL(for: candidate.name)
            do {
                try candidate.data.write(to: target, options: .atomic)
            } catch {
                report.failures.append(.init(file: candidate.name, reason: error.localizedDescription))
                continue
            }
            added.insert(candidate.data)
            report.filesAdded += 1
            report.fontsAdded += fonts.count
        }
        reload()
        return report
    }

    /// A name in the folder that is not taken: "name.tdf", "name 2.tdf", ...
    func freeURL(for fileName: String) -> URL {
        let safe = fileName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension.lowercased()
        var candidate = directory.appendingPathComponent(safe)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    // MARK: Remove, favourites, recent

    /// Fonts that go when `entry`'s file is removed.
    public func fontsSharingFile(with entry: FontEntry) -> [FontEntry] {
        entries.filter { $0.source == entry.source && $0.fileName == entry.fileName }
    }

    public func remove(_ entry: FontEntry) throws {
        guard entry.source == .user, let url = entry.url else { throw FontLibraryError.bundled }
        let gone = Set(fontsSharingFile(with: entry).map(\.id))
        try FileManager.default.removeItem(at: url)
        favourites.subtract(gone)
        recent.removeAll { gone.contains($0) }
        save()
        reload()
    }

    public func setFavourite(_ id: String, _ on: Bool) {
        if on { favourites.insert(id) } else { favourites.remove(id) }
        save()
    }

    public func noteUsed(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
        save()
    }

    public func entry(id: String) -> FontEntry? { entries.first { $0.id == id } }

    // MARK: Search

    /// Entries matching every word of `query` (name, file, kind, source; case and accent blind).
    public func search(_ query: String, categories: Set<TextArtCategory> = [], favouritesOnly: Bool = false) -> [FontEntry] {
        FontGallery.filter(entries, search: query, categories: categories, favouritesOnly: favouritesOnly, favourites: favourites)
    }

    // MARK: Settings file

    private struct Settings: Codable {
        var favourites: [String]
        var recent: [String]
        var sampleText: String
    }

    private var settingsURL: URL { directory.appendingPathComponent("library.json") }
    private var loading = false

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        loading = true
        favourites = Set(settings.favourites)
        recent = settings.recent
        sampleText = settings.sampleText
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let settings = Settings(favourites: favourites.sorted(), recent: recent, sampleText: sampleText)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try? encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }
}
