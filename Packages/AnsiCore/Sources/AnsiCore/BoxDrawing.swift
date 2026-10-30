import Foundation

/// How heavy one arm of a box drawing character is.
public enum BoxWeight: Int, CaseIterable, Equatable {
    case none, single, double
}

/// A box drawing character as its four arms (editor tools plan, ruling 1).
public struct BoxJoin: Equatable, Hashable {
    public var up: BoxWeight
    public var down: BoxWeight
    public var left: BoxWeight
    public var right: BoxWeight

    public init(up: BoxWeight = .none, down: BoxWeight = .none, left: BoxWeight = .none, right: BoxWeight = .none) {
        self.up = up
        self.down = down
        self.left = left
        self.right = right
    }

    /// The arms of a CP437 box character (0xB3 to 0xDA), or nil for any other code.
    public init?(code: UInt8) {
        guard let join = BoxDrawing.joins[code] else { return nil }
        self = join
    }

    public var isEmpty: Bool { up == .none && down == .none && left == .none && right == .none }

    /// Left and right swapped (a horizontal mirror).
    public var mirroredHorizontally: BoxJoin { BoxJoin(up: up, down: down, left: right, right: left) }
    /// Up and down swapped (a vertical mirror).
    public var mirroredVertically: BoxJoin { BoxJoin(up: down, down: up, left: left, right: right) }
    /// Turned a quarter clockwise: what pointed up points right.
    public var rotatedClockwise: BoxJoin { BoxJoin(up: left, down: right, left: down, right: up) }
}

/// The four TheDraw line styles (ruling 2).
public enum LineStyle: String, CaseIterable, Equatable {
    case single, double, singleHDoubleV, doubleHSingleV

    public var horizontal: BoxWeight {
        switch self {
        case .single, .singleHDoubleV: return .single
        case .double, .doubleHSingleV: return .double
        }
    }

    public var vertical: BoxWeight {
        switch self {
        case .single, .doubleHSingleV: return .single
        case .double, .singleHDoubleV: return .double
        }
    }

    public var label: String {
        switch self {
        case .single: return "Single ─│"
        case .double: return "Double ═║"
        case .singleHDoubleV: return "Single across, double down ─║"
        case .doubleHSingleV: return "Double across, single down ═│"
        }
    }
}

public enum BoxDrawing {
    /// Every CP437 box drawing character and its arms: (code, up, down, left, right) with
    /// 0 none, 1 single, 2 double.
    private static let table: [(UInt8, Int, Int, Int, Int)] = [
        (0xB3, 1, 1, 0, 0), (0xB4, 1, 1, 1, 0), (0xB5, 1, 1, 2, 0), (0xB6, 2, 2, 1, 0),
        (0xB7, 0, 2, 1, 0), (0xB8, 0, 1, 2, 0), (0xB9, 2, 2, 2, 0), (0xBA, 2, 2, 0, 0),
        (0xBB, 0, 2, 2, 0), (0xBC, 2, 0, 2, 0), (0xBD, 2, 0, 1, 0), (0xBE, 1, 0, 2, 0),
        (0xBF, 0, 1, 1, 0), (0xC0, 1, 0, 0, 1), (0xC1, 1, 0, 1, 1), (0xC2, 0, 1, 1, 1),
        (0xC3, 1, 1, 0, 1), (0xC4, 0, 0, 1, 1), (0xC5, 1, 1, 1, 1), (0xC6, 1, 1, 0, 2),
        (0xC7, 2, 2, 0, 1), (0xC8, 2, 0, 0, 2), (0xC9, 0, 2, 0, 2), (0xCA, 2, 0, 2, 2),
        (0xCB, 0, 2, 2, 2), (0xCC, 2, 2, 0, 2), (0xCD, 0, 0, 2, 2), (0xCE, 2, 2, 2, 2),
        (0xCF, 1, 0, 2, 2), (0xD0, 2, 0, 1, 1), (0xD1, 0, 1, 2, 2), (0xD2, 0, 2, 1, 1),
        (0xD3, 2, 0, 0, 1), (0xD4, 1, 0, 0, 2), (0xD5, 0, 1, 0, 2), (0xD6, 0, 2, 0, 1),
        (0xD7, 2, 2, 1, 1), (0xD8, 1, 1, 2, 2), (0xD9, 1, 0, 1, 0), (0xDA, 0, 1, 0, 1),
    ]

    static let joins: [UInt8: BoxJoin] = {
        var map: [UInt8: BoxJoin] = [:]
        for (code, u, d, l, r) in table {
            map[code] = BoxJoin(up: BoxWeight(rawValue: u)!, down: BoxWeight(rawValue: d)!,
                                left: BoxWeight(rawValue: l)!, right: BoxWeight(rawValue: r)!)
        }
        return map
    }()

    /// All 81 joins resolved once (exact character, line end, or nearest).
    private static let codes: [BoxJoin: UInt8] = {
        var exact: [BoxJoin: UInt8] = [:]
        for (code, join) in joins { exact[join] = code }
        var result: [BoxJoin: UInt8] = [:]
        for u in BoxWeight.allCases { for d in BoxWeight.allCases { for l in BoxWeight.allCases { for r in BoxWeight.allCases {
            let join = BoxJoin(up: u, down: d, left: l, right: r)
            if join.isEmpty { continue }
            result[join] = exact[join] ?? resolve(join, exact: exact)
        }}}}
        return result
    }()

    /// The character for a join, or nil for no arms (a space).
    public static func code(for join: BoxJoin) -> UInt8? { codes[join] }

    private static func resolve(_ join: BoxJoin, exact: [BoxJoin: UInt8]) -> UInt8 {
        let horizontal = join.left != .none || join.right != .none
        let vertical = join.up != .none || join.down != .none
        // A line end, or a straight line whose two halves differ: the straight character of the axis.
        if horizontal != vertical {
            if horizontal {
                let weight = join.left == .double || join.right == .double ? (join.left == .single || join.right == .single ? preferredMixed(join.left, join.right) : .double) : .single
                return weight == .double ? 0xCD : 0xC4
            }
            let weight = join.up == .double || join.down == .double ? (join.up == .single || join.down == .single ? preferredMixed(join.up, join.down) : .double) : .single
            return weight == .double ? 0xBA : 0xB3
        }
        // Nearest exact character: presence mismatch costs 4, weight mismatch 1; ties keep the
        // horizontal weights, then the lowest code (deterministic).
        func cost(_ a: BoxWeight, _ b: BoxWeight) -> Int {
            if a == b { return 0 }
            return (a == .none) != (b == .none) ? 4 : 1
        }
        var best: (key: (Int, Int, UInt8), code: UInt8)?
        for (candidate, code) in exact {
            let total = cost(join.up, candidate.up) + cost(join.down, candidate.down)
                + cost(join.left, candidate.left) + cost(join.right, candidate.right)
            let horizontalLoss = (join.left == candidate.left ? 0 : 1) + (join.right == candidate.right ? 0 : 1)
            let key = (total, horizontalLoss, code)
            if best == nil || key < best!.key { best = (key, code) }
        }
        return best!.code
    }

    /// For a straight line whose halves are single and double: the first (left or up) half wins.
    private static func preferredMixed(_ first: BoxWeight, _ second: BoxWeight) -> BoxWeight {
        first != .none ? first : second
    }

    /// Cells from `a` to `b` moving horizontally first, then vertically, both ends included.
    public static func manhattanPath(from a: (Int, Int), to b: (Int, Int)) -> [(Int, Int)] {
        var path = [a]
        var (x, y) = a
        while x != b.0 { x += b.0 > x ? 1 : -1; path.append((x, y)) }
        while y != b.1 { y += b.1 > y ? 1 : -1; path.append((x, y)) }
        return path
    }
}

extension EditCanvas {
    /// The arms of the character at a cell (empty for anything that is not a box character).
    public func join(x: Int, y: Int) -> BoxJoin {
        guard x >= 0, x < columns, y >= 0, y < height else { return BoxJoin() }
        return BoxJoin(code: self[x, y].code) ?? BoxJoin()
    }

    /// The arms of a cell as line drawing sees them. A straight character (─ │ ═ ║) is also
    /// what a line end looks like, so an arm whose neighbour does not connect back is dropped
    /// when the opposite arm does connect.
    func effectiveJoin(x: Int, y: Int) -> BoxJoin {
        var join = self.join(x: x, y: y)
        guard let code = BoxDrawing.code(for: join), [0xB3, 0xBA, 0xC4, 0xCD].contains(code) else { return join }
        let connected = connectedArms(join, x: x, y: y)
        if code == 0xC4 || code == 0xCD {
            if connected == [.left] { join.right = .none }
            if connected == [.right] { join.left = .none }
        } else {
            if connected == [.up] { join.down = .none }
            if connected == [.down] { join.up = .none }
        }
        return join
    }

    enum Arm { case up, down, left, right }

    /// The arms of `join` at a cell whose neighbour has the matching arm back.
    func connectedArms(_ join: BoxJoin, x: Int, y: Int) -> Set<Arm> {
        var arms: Set<Arm> = []
        if join.up != .none, self.join(x: x, y: y - 1).down != .none { arms.insert(.up) }
        if join.down != .none, self.join(x: x, y: y + 1).up != .none { arms.insert(.down) }
        if join.left != .none, self.join(x: x - 1, y: y).right != .none { arms.insert(.left) }
        if join.right != .none, self.join(x: x + 1, y: y).left != .none { arms.insert(.right) }
        return arms
    }

    /// Draws a line through consecutive cells (each step one cell horizontally or vertically;
    /// other steps are ignored), joining with what is already there (ruling 2).
    public mutating func drawLine(path: [(Int, Int)], style: LineStyle, fg: RGB, bg: RGB) {
        if path.count == 1 {
            let (x, y) = path[0]
            var join = effectiveJoin(x: x, y: y)
            if join.isEmpty { join.left = style.horizontal; join.right = style.horizontal }
            writeJoin(join, x: x, y: y, fg: fg, bg: bg)
            return
        }
        for index in path.indices.dropFirst() {
            connect(path[index - 1], path[index], style: style, erase: false, fg: fg, bg: bg)
        }
    }

    /// Removes the line segments between consecutive cells of `path` (ruling 2).
    public mutating func eraseLine(path: [(Int, Int)], fg: RGB, bg: RGB) {
        for index in path.indices.dropFirst() {
            connect(path[index - 1], path[index], style: .single, erase: true, fg: fg, bg: bg)
        }
    }

    private mutating func connect(_ a: (Int, Int), _ b: (Int, Int), style: LineStyle, erase: Bool, fg: RGB, bg: RGB) {
        let dx = b.0 - a.0, dy = b.1 - a.1
        guard abs(dx) + abs(dy) == 1 else { return }
        let weight: BoxWeight = erase ? .none : (dx != 0 ? style.horizontal : style.vertical)
        for (cell, toward) in [(a, (dx, dy)), (b, (-dx, -dy))] {
            let (x, y) = cell
            guard x >= 0, x < columns, y >= 0, y < AnsiTerminal.maxRows else { continue }
            var join = effectiveJoin(x: x, y: y)
            if erase && join.isEmpty { continue }
            switch toward {
            case (1, 0): join.right = weight
            case (-1, 0): join.left = weight
            case (0, 1): join.down = weight
            default: join.up = weight
            }
            if erase, !join.isEmpty, connectedArms(join, x: x, y: y).isEmpty { join = BoxJoin() }
            writeJoin(join, x: x, y: y, fg: fg, bg: bg)
        }
    }

    private mutating func writeJoin(_ join: BoxJoin, x: Int, y: Int, fg: RGB, bg: RGB) {
        let code = BoxDrawing.code(for: join) ?? 0x20
        set(AnsiCell(code: code, fg: fg, bg: bg), x: x, y: y)
    }
}
