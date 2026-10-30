import Foundation

/// What the CP437 character picker shows for a code (editor tools plan, ruling 5).
public struct CharacterInfo: Equatable {
    public let code: UInt8
    public let scalar: Unicode.Scalar

    public init(code: UInt8) {
        self.code = code
        scalar = CP437.unicode[Int(code)]
    }

    /// The Unicode name of the glyph CP437 shows for the code.
    public var name: String {
        if let name = scalar.properties.name, !name.isEmpty { return name }
        if let alias = scalar.properties.nameAlias, !alias.isEmpty { return alias }
        return code == 0 ? "NULL" : String(format: "U+%04X", scalar.value)
    }

    /// "201 (0xC9)  U+2554  BOX DRAWINGS DOUBLE DOWN AND RIGHT"
    public var summary: String {
        "\(code) (\(String(format: "0x%02X", code)))  \(String(format: "U+%04X", scalar.value))  \(name)"
    }
}

/// The picker's favourites and recently used characters, kept in the user's defaults.
public struct CharacterHistory: Equatable {
    public static let recentLimit = 16
    public private(set) var recent: [UInt8] = []
    public private(set) var favourites: [UInt8] = []

    public init() {}

    /// Restores from `plist`; anything unreadable gives an empty history.
    public init(plist: [String: Any]) {
        recent = Self.codes(plist["recent"]).prefix(Self.recentLimit).map { $0 }
        favourites = Self.codes(plist["favourites"])
    }

    public var plist: [String: Any] {
        ["recent": recent.map(Int.init), "favourites": favourites.map(Int.init)]
    }

    /// Records a use: the code moves to the front of the recent list.
    public mutating func use(_ code: UInt8) {
        recent.removeAll { $0 == code }
        recent.insert(code, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    public mutating func toggleFavourite(_ code: UInt8) {
        if let index = favourites.firstIndex(of: code) { favourites.remove(at: index) } else { favourites.append(code) }
    }

    public func isFavourite(_ code: UInt8) -> Bool { favourites.contains(code) }

    private static func codes(_ value: Any?) -> [UInt8] {
        guard let numbers = value as? [Int] else { return [] }
        var seen = Set<UInt8>()
        return numbers.compactMap { (0...255).contains($0) ? UInt8($0) : nil }.filter { seen.insert($0).inserted }
    }
}
