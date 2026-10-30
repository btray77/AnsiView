import Foundation

/// A RIPscrip icon (.ICN, .HIC) or clipboard image: the Borland BGI getimage() layout, a header of
/// width minus 1 and height minus 1 (16 bit little endian), then per scan line four bit planes
/// (plane 3 first, as RIPscrip 1.54 documents), each padded to whole bytes, then one spare byte.
public struct RIPIcon: Equatable {
    public let width: Int
    public let height: Int
    /// Colour indexes 0-15, row major.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Nil for a truncated file or one larger than the 640x350 screen.
    public static func decode(_ bytes: [UInt8]) -> RIPIcon? {
        guard bytes.count >= 4 else { return nil }
        let width = (Int(bytes[0]) | Int(bytes[1]) << 8) + 1
        let height = (Int(bytes[2]) | Int(bytes[3]) << 8) + 1
        guard width >= 1, height >= 1, width <= 640, height <= 350 else { return nil }
        let row = (width + 7) / 8
        guard bytes.count >= 4 + row * 4 * height else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let base = 4 + y * row * 4
            for x in 0..<width {
                let shift = UInt8(7 - x & 7), byte = x / 8
                var c: UInt8 = 0
                for plane in 0..<4 where bytes[base + plane * row + byte] >> shift & 1 == 1 {
                    c |= 1 << UInt8(3 - plane)
                }
                pixels[y * width + x] = c
            }
        }
        return RIPIcon(width: width, height: height, pixels: pixels)
    }

    public func encode() -> [UInt8] {
        let w = width - 1, h = height - 1
        var out: [UInt8] = [UInt8(w & 0xFF), UInt8(w >> 8), UInt8(h & 0xFF), UInt8(h >> 8)]
        let row = (width + 7) / 8
        for y in 0..<height {
            for plane in 0..<4 {
                var bytes = [UInt8](repeating: 0, count: row)
                for x in 0..<width where pixels[y * width + x] >> UInt8(3 - plane) & 1 == 1 {
                    bytes[x / 8] |= 0x80 >> UInt8(x & 7)
                }
                out += bytes
            }
        }
        out.append(0)
        return out
    }
}

/// Where a RIPscrip terminal finds icons and scenes the BBS names (the user's chosen folder).
public protocol RIPFileProvider {
    /// The file's bytes; nil when it does not exist. `name` is already sanitized.
    func data(named name: String) -> [UInt8]?
    /// Size and modification date; nil when the file does not exist.
    func info(named name: String) -> (size: Int, date: Date)?
}

public enum RIPFileName {
    /// A plain file name from a BBS: no folders, no `..`, printable ASCII, at most 64 characters.
    /// Nil when nothing usable is left.
    public static func sanitize(_ raw: [UInt8]) -> String? {
        var text = String(decoding: raw.filter { (0x21...0x7E).contains($0) }, as: UTF8.self)
        if let slash = text.lastIndex(where: { $0 == "/" || $0 == "\\" || $0 == ":" }) {
            text = String(text[text.index(after: slash)...])
        }
        guard !text.isEmpty, text != ".", text != "..", !text.hasPrefix("."), text.count <= 64 else { return nil }
        return text
    }

    /// An icon name with `.ICN` appended when it has no extension.
    public static func icon(_ raw: [UInt8], defaultExtension: String = "ICN") -> String? {
        guard let name = sanitize(raw) else { return nil }
        return name.contains(".") ? name : name + "." + defaultExtension
    }
}

/// A folder of icons and scenes on disk (the app's chosen RIP icon folder). Names match without
/// regard to case, as on DOS.
public struct RIPFolderProvider: RIPFileProvider {
    public let folder: URL
    public static let maxFileBytes = 2 * 1024 * 1024

    public init(folder: URL) { self.folder = folder }

    private func url(_ name: String) -> URL? {
        let lower = name.lowercased()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.first { $0.lowercased() == lower }.map { folder.appendingPathComponent($0) }
    }

    public func data(named name: String) -> [UInt8]? {
        guard let url = url(name), let info = info(named: name), info.size <= Self.maxFileBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return [UInt8](data)
    }

    public func info(named name: String) -> (size: Int, date: Date)? {
        guard let url = url(name), let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return (values.fileSize ?? 0, values.contentModificationDate ?? Date(timeIntervalSince1970: 0))
    }
}
