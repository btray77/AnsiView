import Foundation

/// The dialing directory list as a retro text screen (ruling 14): keys and mouse turn into
/// events the app carries out. Pure; the directory itself is passed in.
public struct DirectoryBrowser {
    public enum Event: Equatable {
        case none
        case dial([UUID])
        case edit(UUID)
        case new
        case duplicate(UUID)
        case delete([UUID])
        case reorder([UUID], before: UUID?)
        case settings
        case importFile
        case exportFile
        case close
    }

    public static let sortCycle: [DialingDirectory.SortKey?] = [nil, .name, .address, .lastCalled, .totalCalls]

    public var search = ""
    public private(set) var searching = false
    public var tag: String?
    public var sort: DialingDirectory.SortKey?
    /// Entries queued for dialing with Space, in the order of the list.
    public private(set) var marked: [UUID] = []
    /// A status line message (cleared by the next key).
    public private(set) var message = ""
    private var selected: UUID?

    public init() {}

    /// Most recent call and most calls first; names and addresses A to Z.
    static func ascending(_ key: DialingDirectory.SortKey) -> Bool {
        key != .lastCalled && key != .totalCalls
    }

    public func visible(in directory: DialingDirectory) -> [BBSEntry] {
        let list = directory.filtered(search: search, tag: tag)
        guard let sort else { return list }
        return DialingDirectory.sorted(list, by: sort, ascending: Self.ascending(sort))
    }

    public func selectedID(in directory: DialingDirectory) -> UUID? {
        let list = visible(in: directory)
        if let selected, list.contains(where: { $0.id == selected }) { return selected }
        return list.first?.id
    }

    private func selectedIndex(in list: [BBSEntry]) -> Int {
        list.firstIndex { $0.id == selected } ?? 0
    }

    public mutating func select(_ id: UUID?) { selected = id }

    private mutating func moveSelection(by delta: Int, in list: [BBSEntry]) {
        guard !list.isEmpty else { return }
        let index = min(list.count - 1, max(0, selectedIndex(in: list) + delta))
        selected = list[index].id
    }

    /// The marked entries still visible, in list order, or else the selected one.
    private func targets(in list: [BBSEntry], directory: DialingDirectory) -> [UUID] {
        let markedSet = Set(marked)
        let chosen = list.filter { markedSet.contains($0.id) }.map(\.id)
        if !chosen.isEmpty { return chosen }
        return selectedID(in: directory).map { [$0] } ?? []
    }

    public mutating func handle(_ key: FormKey, in directory: DialingDirectory) -> Event {
        message = ""
        var list = visible(in: directory)
        if searching {
            switch key {
            case .enter: searching = false
            case .escape:
                searching = false
                search = ""
            case .backspace: if !search.isEmpty { search.removeLast() }
            case .character(let c) where c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 }):
                search.append(c)
            case .up, .down, .pageUp, .pageDown, .home, .end:
                searching = false
                return handle(key, in: directory)
            default: break
            }
            list = visible(in: directory)
            if !list.contains(where: { $0.id == selected }) { selected = list.first?.id }
            return .none
        }
        switch key {
        case .up: moveSelection(by: -1, in: list)
        case .down: moveSelection(by: 1, in: list)
        case .pageUp: moveSelection(by: -15, in: list)
        case .pageDown: moveSelection(by: 15, in: list)
        case .home: moveSelection(by: -list.count, in: list)
        case .end: moveSelection(by: list.count, in: list)
        case .enter:
            let ids = targets(in: list, directory: directory)
            return ids.isEmpty ? .none : .dial(ids)
        case .escape:
            if !search.isEmpty || tag != nil {
                search = ""
                tag = nil
                return .none
            }
            return .close
        case .forwardDelete, .backspace:
            let ids = targets(in: list, directory: directory)
            return ids.isEmpty ? .none : .delete(ids)
        case .moveUp, .moveDown:
            return reorder(up: key == .moveUp, in: list, directory: directory)
        case .character(let c):
            return hotkey(c, list: list, directory: directory)
        default: break
        }
        return .none
    }

    private mutating func hotkey(_ c: Character, list: [BBSEntry], directory: DialingDirectory) -> Event {
        let current = selectedID(in: directory)
        switch c.lowercased() {
        case " ":
            guard let current else { return .none }
            if let index = marked.firstIndex(of: current) { marked.remove(at: index) } else { marked.append(current) }
            moveSelection(by: 1, in: list)
        case "u": marked.removeAll()
        case "n": return .new
        case "e": return current.map { .edit($0) } ?? .none
        case "c": return current.map { .duplicate($0) } ?? .none
        case "d": let ids = targets(in: list, directory: directory); return ids.isEmpty ? .none : .delete(ids)
        case "g": return .settings
        case "i": return .importFile
        case "x": return .exportFile
        case "s":
            let index = Self.sortCycle.firstIndex(of: sort) ?? 0
            sort = Self.sortCycle[(index + 1) % Self.sortCycle.count]
        case "t":
            let tags = directory.allTags
            guard !tags.isEmpty else { message = "No tags yet. Add some in the editor (E)."; return .none }
            if let tag, let index = tags.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                self.tag = index + 1 < tags.count ? tags[index + 1] : nil
            } else {
                tag = tags[0]
            }
        case "/":
            searching = true
        default: break
        }
        return .none
    }

    private mutating func reorder(up: Bool, in list: [BBSEntry], directory: DialingDirectory) -> Event {
        guard sort == nil else {
            message = "Reordering uses the saved order. Press S until Sort shows Manual."
            return .none
        }
        guard let current = selectedID(in: directory), let index = list.firstIndex(where: { $0.id == current }) else { return .none }
        if up {
            guard index > 0 else { return .none }
            return .reorder([current], before: list[index - 1].id)
        }
        guard index + 1 < list.count else { return .none }
        return .reorder([current], before: index + 2 < list.count ? list[index + 2].id : nil)
    }

    /// A row dragged with the mouse from one list position to another.
    public mutating func drag(from: Int, to: Int, in directory: DialingDirectory) -> Event {
        let list = visible(in: directory)
        guard from != to, list.indices.contains(from), list.indices.contains(to) else { return .none }
        guard sort == nil else {
            message = "Reordering uses the saved order. Press S until Sort shows Manual."
            return .none
        }
        selected = list[from].id
        let before = from > to ? list[to].id : (to + 1 < list.count ? list[to + 1].id : nil)
        return .reorder([list[from].id], before: before)
    }

    /// A click selects; a double click dials.
    public mutating func click(row: Int, count: Int, map: [Int: Int], in directory: DialingDirectory) -> Event {
        let list = visible(in: directory)
        guard let index = map[row], list.indices.contains(index) else { return .none }
        selected = list[index].id
        return count >= 2 ? .dial([list[index].id]) : .none
    }

    // MARK: Screen

    public struct Rendered {
        public var screen: AnsiScreen
        /// Screen row to index in `visible(in:)`.
        public var entryAtRow: [Int: Int]
    }

    static let keysLine = "Enter Dial  Space Mark  U Unmark  N New  E Edit  C Copy  D Delete  / Search"
    static let footerKeys = " S Sort  T Tag  G Settings  I Import  X Export  Esc Close "

    public func screen(in directory: DialingDirectory, columns: Int = 80, rows: Int = 25, timeZone: TimeZone = .current) -> Rendered {
        var canvas = RetroCanvas(columns: columns, rows: rows)
        canvas.frame(title: "AnsiView Dialing Directory")
        let list = visible(in: directory)
        let current = selectedID(in: directory)
        let nameColumn = 6, addressColumn = 34, lastColumn = 60, callsColumn = 72
        canvas.put("#", row: 1, column: 2, fg: Palette.vga[14])
        canvas.put("Name", row: 1, column: nameColumn, fg: Palette.vga[14])
        canvas.put("Address", row: 1, column: addressColumn, fg: Palette.vga[14])
        canvas.put("Last Called", row: 1, column: lastColumn, fg: Palette.vga[14])
        canvas.put("Calls", row: 1, column: callsColumn, fg: Palette.vga[14])
        canvas.divider(row: 2)
        let listTop = 3
        let listRows = max(1, rows - 10)
        var map: [Int: Int] = [:]
        if list.isEmpty {
            let text = directory.entries.isEmpty
                ? "No BBSes yet. Press N to add one, or I to import a directory."
                : "No BBSes match. Press Esc to show them all."
            canvas.put(text, row: listTop + 1, column: 4, fg: Palette.vga[7])
        }
        let currentIndex = list.firstIndex { $0.id == current } ?? 0
        let top = (currentIndex / listRows) * listRows
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let markedSet = Set(marked)
        for (offset, entry) in list.dropFirst(top).prefix(listRows).enumerated() {
            let row = listTop + offset
            let index = top + offset
            map[row] = index
            let isSelected = entry.id == current
            let fg = isSelected ? Palette.vga[0] : Palette.vga[7]
            let bg = isSelected ? Palette.vga[3] : Palette.vga[0]
            if isSelected { canvas.fill(row: row, column: 1, count: columns - 2, bg: bg) }
            if markedSet.contains(entry.id) { canvas.put("\u{221A}", row: row, column: 1, fg: isSelected ? Palette.vga[15] : Palette.vga[10], bg: bg) }
            canvas.put(String(format: "%3d", index + 1), row: row, column: 2, fg: isSelected ? fg : Palette.vga[8], bg: bg)
            canvas.put(entry.name.isEmpty ? entry.host : entry.name, row: row, column: nameColumn, fg: isSelected ? fg : Palette.vga[15], bg: bg, limit: addressColumn - nameColumn - 1)
            canvas.put(entry.address, row: row, column: addressColumn, fg: fg, bg: bg, limit: lastColumn - addressColumn - 1)
            canvas.put(entry.lastCalled.map { formatter.string(from: $0) } ?? "Never", row: row, column: lastColumn, fg: fg, bg: bg)
            canvas.put(String(format: "%5d", entry.totalCalls), row: row, column: callsColumn, fg: fg, bg: bg)
        }
        if top > 0 { canvas.put("\u{18}", row: listTop, column: columns - 1, fg: Palette.vga[14]) }
        if top + listRows < list.count { canvas.put("\u{19}", row: listTop + listRows - 1, column: columns - 1, fg: Palette.vga[14]) }
        canvas.divider(row: rows - 7)
        if let entry = list.first(where: { $0.id == current }) {
            canvas.put("Notes:", row: rows - 6, column: 3, fg: Palette.vga[3])
            canvas.put(entry.notes.isEmpty ? "(none)" : entry.notes, row: rows - 6, column: 10, fg: Palette.vga[7])
            canvas.put("Tags:", row: rows - 5, column: 3, fg: Palette.vga[3])
            canvas.put(entry.tags.isEmpty ? "(none)" : entry.tags.joined(separator: ", "), row: rows - 5, column: 10, fg: Palette.vga[7])
        }
        var status = ["Sort: " + (sort.map(Self.sortLabel) ?? "Manual"), "Tag: " + (tag ?? "All")]
        if searching || !search.isEmpty { status.append("Search: " + search + (searching ? "_" : "")) }
        if !marked.isEmpty { status.append("Marked: \(marked.count)") }
        status.append("\(list.count) of \(directory.entries.count)")
        canvas.put(status.joined(separator: "   "), row: rows - 4, column: 3, fg: Palette.vga[11])
        canvas.put(message.isEmpty ? "Option-Up/Down or drag a row to reorder. Double click a row to dial it." : message,
                   row: rows - 3, column: 3, fg: message.isEmpty ? Palette.vga[8] : Palette.vga[14])
        canvas.put(Self.keysLine, row: rows - 2, column: 2, fg: Palette.vga[14])
        canvas.footer(Self.footerKeys)
        return Rendered(screen: canvas.screen(title: "Dialing Directory"), entryAtRow: map)
    }

    static func sortLabel(_ key: DialingDirectory.SortKey) -> String {
        switch key {
        case .name: return "Name"
        case .address: return "Address"
        case .lastCalled: return "Last Called"
        case .totalCalls: return "Calls"
        case .notes: return "Notes"
        }
    }
}
