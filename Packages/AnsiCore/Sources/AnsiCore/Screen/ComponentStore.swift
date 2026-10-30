import Foundation

/// A component the user saved from a selection.
public struct SavedComponent: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var created: Date
    /// The cells in the editor's own `AVCELLS1` form (exact colours and characters).
    public var cells: Data

    public var region: CanvasRegion? { CanvasEditor.decode(cells) }
}

/// The user's components: one JSON file each in `directory` (Application Support in the app).
public struct ComponentStore {
    public enum StoreError: Error, Equatable, LocalizedError {
        case empty
        case notFound

        public var errorDescription: String? {
            switch self {
            case .empty: return "Select some cells first; an empty selection cannot be saved as a component."
            case .notFound: return "That component no longer exists."
            }
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Every readable component, oldest first. Damaged files are skipped.
    public func all() -> [SavedComponent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SavedComponent.self, from: Data(contentsOf: $0)) }
            .filter { $0.region != nil }
            .sorted { ($0.created, $0.name) < ($1.created, $1.name) }
    }

    @discardableResult
    public func save(name: String, region: CanvasRegion, now: Date = Date()) throws -> SavedComponent {
        guard region.width > 0, region.height > 0 else { throw StoreError.empty }
        // Later saves sort after earlier ones even within the same clock tick.
        let created = max(now, (all().last?.created ?? .distantPast).addingTimeInterval(0.001))
        let component = SavedComponent(id: UUID(), name: name.isEmpty ? "Component" : name, created: created,
                                       cells: CanvasEditor.encode(region))
        try write(component)
        return component
    }

    public func rename(_ id: UUID, to name: String) throws {
        guard var component = all().first(where: { $0.id == id }) else { throw StoreError.notFound }
        component.name = name
        try write(component)
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: url(id))
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private func write(_ component: SavedComponent) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(component).write(to: url(component.id), options: .atomic)
    }
}
