import Compression
import Foundation

public enum ZipError: LocalizedError, Equatable {
    case notAZip
    case corrupt
    case unsupportedMethod(UInt16)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "This file is not a ZIP archive."
        case .corrupt: return "This ZIP archive is damaged or uses a format AnsiView cannot read."
        case .unsupportedMethod(let method):
            return "This ZIP entry uses compression method \(method), which AnsiView cannot read."
        }
    }
}

/// Reads art packs: ZIP files whose entries are stored or DEFLATE compressed. Older PKZIP methods
/// (shrink, reduce, implode) are listed but not read.
public struct ZipArchive {
    public struct Entry: Equatable {
        public let path: String
        public var name: String { (path as NSString).lastPathComponent }
        public let method: UInt16
        public let compressedSize: Int
        public let size: Int
        /// Offset of the entry's local header.
        public let offset: Int
    }

    /// Entries larger than this are refused, so a hostile archive cannot exhaust memory.
    public static let maxEntrySize = 64 << 20
    static let supportedMethods: Set<UInt16> = [0, 8]

    public let entries: [Entry]
    private let bytes: [UInt8]

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }

        // End of central directory: 22 bytes plus a comment of up to 65,535 bytes, at the end.
        guard bytes.count >= 22 else { throw ZipError.notAZip }
        var end = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 22 - 65_535) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 5, bytes[i + 3] == 6 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw ZipError.notAZip }
        let count = u16(end + 10)
        var position = u32(end + 16)
        guard position + 46 * count <= end else { throw ZipError.corrupt }

        var entries: [Entry] = []
        for _ in 0..<count {
            guard position + 46 <= bytes.count, u32(position) == 0x0201_4B50 else { throw ZipError.corrupt }
            let nameLength = u16(position + 28), extraLength = u16(position + 30), commentLength = u16(position + 32)
            let nameStart = position + 46
            guard nameStart + nameLength <= bytes.count else { throw ZipError.corrupt }
            let nameBytes = bytes[nameStart..<(nameStart + nameLength)]
            // Bit 11 marks UTF-8 names; older archives use CP437.
            let path = u16(position + 8) & 0x0800 != 0
                ? String(decoding: nameBytes, as: UTF8.self) : cp437String(nameBytes)
            entries.append(Entry(path: path, method: UInt16(u16(position + 10)), compressedSize: u32(position + 20),
                                 size: u32(position + 24), offset: u32(position + 42)))
            position = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// Art entries this reader can open, in slideshow order (folders inside the pack flattened).
    public var artEntries: [Entry] {
        let readable = entries.filter { ArtFiles.isArt($0.path) && Self.supportedMethods.contains($0.method) }
        let order = ArtFiles.ordered(readable.map(\.path))
        // A dictionary, not a search per path: packs with thousands of entries stay fast (plan 9 item 47).
        let byPath = Dictionary(readable.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byPath[$0] }
    }

    /// Art entries skipped because their compression method is not supported.
    public var skippedCount: Int {
        entries.filter { ArtFiles.isArt($0.path) && !Self.supportedMethods.contains($0.method) }.count
    }

    /// The entry's uncompressed bytes.
    public func data(for entry: Entry) throws -> Data {
        guard Self.supportedMethods.contains(entry.method) else { throw ZipError.unsupportedMethod(entry.method) }
        let local = entry.offset
        guard local >= 0, local + 30 <= bytes.count,
              bytes[local] == 0x50, bytes[local + 1] == 0x4B, bytes[local + 2] == 3, bytes[local + 3] == 4
        else { throw ZipError.corrupt }
        let start = local + 30 + (Int(bytes[local + 26]) | Int(bytes[local + 27]) << 8)
            + (Int(bytes[local + 28]) | Int(bytes[local + 29]) << 8)
        guard entry.compressedSize >= 0, entry.size >= 0, entry.size <= Self.maxEntrySize,
              start + entry.compressedSize <= bytes.count else { throw ZipError.corrupt }
        let packed = bytes[start..<(start + entry.compressedSize)]
        if entry.method == 0 {
            guard entry.size == entry.compressedSize else { throw ZipError.corrupt }
            return Data(packed)
        }
        guard entry.size > 0 else { return Data() }
        guard !packed.isEmpty else { throw ZipError.corrupt }
        // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP method 8 stores.
        var output = [UInt8](repeating: 0, count: entry.size)
        let written = packed.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, destination.count,
                                          source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == entry.size else { throw ZipError.corrupt }
        return Data(output)
    }
}
