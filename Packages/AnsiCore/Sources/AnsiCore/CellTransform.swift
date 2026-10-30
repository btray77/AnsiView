import Foundation

/// Mirroring and rotating blocks of cells, with characters remapped so the picture turns too
/// (editor tools plan, ruling 9).
public enum CellTransform: String, CaseIterable, Equatable {
    case mirrorHorizontal, mirrorVertical, rotate180, rotateClockwise

    public var title: String {
        switch self {
        case .mirrorHorizontal: return "Mirror Horizontally"
        case .mirrorVertical: return "Mirror Vertically"
        case .rotate180: return "Rotate 180"
        case .rotateClockwise: return "Rotate 90 Clockwise"
        }
    }

    /// Pairs swapped by a horizontal mirror (box characters go through their joins).
    private static let horizontalPairs: [(UInt8, UInt8)] = [
        (221, 222), (0x2F, 0x5C), (0x3C, 0x3E), (0x28, 0x29), (0x5B, 0x5D), (0x7B, 0x7D),
        (26, 27), (16, 17), (174, 175),
    ]
    /// Pairs swapped by a vertical mirror.
    private static let verticalPairs: [(UInt8, UInt8)] = [
        (223, 220), (0x2F, 0x5C), (24, 25), (30, 31), (244, 245),
    ]
    /// Cycles for a quarter turn clockwise: each maps to the next.
    private static let clockwiseCycles: [[UInt8]] = [
        [223, 222, 220, 221],  // ▀ ▐ ▄ ▌
        [0x2F, 0x5C],          // / \
        [0x2D, 0x7C],          // - |
        [24, 26, 25, 27],      // ↑ → ↓ ←
        [30, 16, 31, 17],      // ▲ ► ▼ ◄
    ]

    private static func table(_ build: (UInt8) -> UInt8) -> [UInt8] { (0...255).map { build(UInt8($0)) } }

    private static func pairs(_ list: [(UInt8, UInt8)]) -> [UInt8: UInt8] {
        var map: [UInt8: UInt8] = [:]
        for (a, b) in list { map[a] = b; map[b] = a }
        return map
    }

    private static let horizontalTable = table { code in
        if let join = BoxJoin(code: code) { return BoxDrawing.code(for: join.mirroredHorizontally) ?? code }
        return pairs(horizontalPairs)[code] ?? code
    }
    private static let verticalTable = table { code in
        if let join = BoxJoin(code: code) { return BoxDrawing.code(for: join.mirroredVertically) ?? code }
        return pairs(verticalPairs)[code] ?? code
    }
    private static let clockwiseTable = table { code in
        if let join = BoxJoin(code: code) { return BoxDrawing.code(for: join.rotatedClockwise) ?? code }
        for cycle in clockwiseCycles { if let index = cycle.firstIndex(of: code) { return cycle[(index + 1) % cycle.count] } }
        return code
    }

    /// The character that shows `code` transformed.
    public func map(_ code: UInt8) -> UInt8 {
        switch self {
        case .mirrorHorizontal: return Self.horizontalTable[Int(code)]
        case .mirrorVertical: return Self.verticalTable[Int(code)]
        case .rotate180: return Self.verticalTable[Int(Self.horizontalTable[Int(code)])]
        case .rotateClockwise: return Self.clockwiseTable[Int(code)]
        }
    }

    /// Whether the transform turns a width x height block on its side.
    public var swapsSize: Bool { self == .rotateClockwise }

    func cell(_ cell: AnsiCell) -> AnsiCell {
        guard cell.scalar == nil else { return cell }
        var result = cell
        result.code = map(cell.code)
        return result
    }
}

extension CanvasRegion {
    /// The block transformed, characters remapped.
    public func transformed(_ transform: CellTransform) -> CanvasRegion {
        let padded = cells.map { $0.count < width ? $0 + Array(repeating: AnsiCell(), count: width - $0.count) : $0 }
        let result: [[AnsiCell]]
        switch transform {
        case .mirrorHorizontal: result = padded.map { $0.reversed() }
        case .mirrorVertical: result = padded.reversed()
        case .rotate180: result = padded.reversed().map { $0.reversed() }
        case .rotateClockwise:
            result = (0..<width).map { column in (0..<height).map { row in padded[height - 1 - row][column] } }
        }
        return CanvasRegion(cells: result.map { $0.map(transform.cell) })
    }
}

extension EditCanvas {
    /// Keeps only the cells in `rect` (clipped); metadata stays. Nothing happens when no cell is inside.
    public mutating func crop(to rect: CellRect) {
        guard let clipped = clip(rect) else { return }
        rows = region(clipped).cells
        columns = clipped.width
    }
}
