import Foundation

/// Finding text inside art: in one screen (cell positions to highlight), and across many pieces
/// (a folded haystack of names, SAUCE fields and the art's words). Plan 9 ruling 1.
public enum ArtSearch {
    /// Lowercased with diacritics removed, so "CaFÉ" finds "cafe".
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// The query's words, folded; empty when it has none.
    public static func words(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Where `query` appears in the screen's rows, one rect per match (a match stays in one row).
    /// Spaces in the query match one or more spaces (or blocks, which read as spaces) in the art.
    public static func matches(in screen: AnsiScreen, query: String) -> [CellRect] {
        let tokens = words(query).map(Array.init)
        guard !tokens.isEmpty else { return [] }
        var found: [CellRect] = []
        for (y, row) in screen.rows.enumerated() {
            let (chars, columns) = foldedRow(row.prefix(screen.columns))
            var i = 0
            while i < chars.count {
                if let end = match(tokens, in: chars, at: i) {
                    found.append(CellRect(x: columns[i], y: y, width: columns[end - 1] - columns[i] + 1, height: 1))
                    i = end
                } else {
                    i += 1
                }
            }
        }
        return found
    }

    /// The row as folded characters, with the column each character came from.
    static func foldedRow(_ cells: ArraySlice<AnsiCell>) -> (chars: [Character], columns: [Int]) {
        var chars: [Character] = []
        var columns: [Int] = []
        chars.reserveCapacity(cells.count)
        columns.reserveCapacity(cells.count)
        for (offset, cell) in cells.enumerated() {
            let scalar = cell.scalar ?? (cell.code == 0 ? " " : CP437.unicode[Int(cell.code)])
            let column = offset
            if (0x2500...0x259F).contains(scalar.value) || scalar.properties.isWhitespace || cell.code == 0xFF && cell.scalar == nil {
                chars.append(" ")
                columns.append(column)
                continue
            }
            for character in fold(String(Character(scalar))) {
                chars.append(character)
                columns.append(column)
            }
        }
        return (chars, columns)
    }

    /// The end of a match of `tokens` (separated by runs of spaces) starting at `start`, or nil.
    private static func match(_ tokens: [[Character]], in chars: [Character], at start: Int) -> Int? {
        var i = start
        for (index, token) in tokens.enumerated() {
            if index > 0 {
                guard i < chars.count, chars[i] == " " else { return nil }
                while i < chars.count, chars[i] == " " { i += 1 }
            }
            guard i + token.count <= chars.count else { return nil }
            for (k, character) in token.enumerated() where chars[i + k] != character { return nil }
            i += token.count
        }
        return i
    }

    /// True when `needle` (folded) occurs in `haystack` (folded), compared as UTF-8 bytes.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var hay = haystack, word = needle
        return hay.withUTF8 { h in
            word.withUTF8 { n in
                guard n.count <= h.count, let hb = h.baseAddress, let nb = n.baseAddress else { return false }
                return memmem(hb, h.count, nb, n.count) != nil
            }
        }
    }
}

/// What a search across many pieces looks in: the name, SAUCE fields and the art's words, folded
/// once so each query is a plain byte search.
public struct SearchHaystack {
    public let text: String
    private let folded: String

    public init(name: String, title: String, author: String, group: String, comments: String, text: String) {
        self.text = text
        folded = ArtSearch.fold([name, title, author, group, comments, text].joined(separator: "\n"))
    }

    /// True when every word (already folded, from `ArtSearch.words`) appears somewhere.
    public func matches(words: [String]) -> Bool {
        words.allSatisfy { ArtSearch.contains(folded, $0) }
    }

    /// The art text around the first occurrence of `word`, within its line, `radius` characters
    /// either side; nil when the art's text does not contain it.
    public func snippet(for word: String, radius: Int) -> String? {
        guard !word.isEmpty,
              let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let from = text.index(range.lowerBound, offsetBy: -radius, limitedBy: lineStart) ?? lineStart
        let to = text.index(range.upperBound, offsetBy: radius, limitedBy: lineEnd) ?? lineEnd
        return String(text[from..<to]).trimmingCharacters(in: .whitespaces)
    }
}
