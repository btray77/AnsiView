import Foundation

/// One layer of a drawing (editor tools plan, ruling 10). On every layer but the bottom one an
/// unset cell (equal to `AnsiCell()`) is transparent.
public struct CanvasLayer: Equatable {
    public var name: String
    public var visible: Bool
    public var canvas: EditCanvas

    public init(name: String, visible: Bool = true, canvas: EditCanvas) {
        self.name = name
        self.visible = visible
        self.canvas = canvas
    }

    /// The unset cell: transparent on an upper layer.
    public static let unset = AnsiCell()
}

public enum LayerStack {
    /// The visible layers drawn bottom to top; the bottom layer's metadata. Hidden layers do not count.
    public static func composite(_ layers: [CanvasLayer]) -> EditCanvas {
        guard var result = layers.first?.canvas else { return EditCanvas() }
        if !layers[0].visible { result.clearCells() }
        let height = layers.filter(\.visible).map(\.canvas.height).max() ?? result.height
        result.ensureHeight(height)
        for layer in layers.dropFirst() where layer.visible { result.overlay(layer.canvas) }
        return result
    }
}

extension EditCanvas {
    /// Every cell unset; size and metadata kept.
    mutating func clearCells() {
        let blank = Array(repeating: AnsiCell(), count: columns)
        for y in rows.indices { rows[y] = blank }
    }

    /// Writes every set cell of `upper` over this canvas (rows grow as needed).
    mutating func overlay(_ upper: EditCanvas) {
        ensureHeight(upper.height)
        let width = min(columns, upper.columns)
        for y in 0..<min(height, upper.height) {
            let line = upper.rows[y]
            for x in 0..<width where line[x] != CanvasLayer.unset { rows[y][x] = line[x] }
        }
    }
}

