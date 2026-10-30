import Foundation

/// Which files in a folder or art pack are art, and the order a slideshow or gallery shows them.
public enum ArtFiles {
    /// Extensions AnsiView opens (`.bin` and `.adf` included: in a folder they are almost always art).
    public static let extensions: Set<String> = ["ans", "ice", "diz", "nfo", "asc", "xb", "idf", "pcb", "avt", "bin", "adf"]

    /// True for a path whose extension is an art extension, outside hidden and `__MACOSX` folders.
    public static func isArt(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let name = components.last,
              !components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { return false }
        return extensions.contains((String(name) as NSString).pathExtension.lowercased())
    }

    /// The art paths in `paths`, in Finder order by file name (numbers compare as numbers).
    public static func ordered(_ paths: [String]) -> [String] {
        paths.filter(isArt).sorted { a, b in
            let order = (a as NSString).lastPathComponent.localizedStandardCompare((b as NSString).lastPathComponent)
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
    }
}

/// Moving between slides: wraps at both ends.
public enum SlideOrder {
    public static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}
