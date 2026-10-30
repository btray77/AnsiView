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

/// A layered drawing saved as an `.ansiproj` file (ruling 11): JSON, one frame in version 1
/// (the frame list is the seam for animation).
public struct ArtProject: Equatable {
    public static let fileExtension = "ansiproj"
    public static let formatName = "AnsiView project"
    public static let currentVersion = 1

    public var layers: [CanvasLayer]
    public var activeLayer: Int

    public enum ProjectError: Error, Equatable, LocalizedError {
        case notAProject
        case newerVersion(Int)
        case damaged(String)

        public var errorDescription: String? {
            switch self {
            case .notAProject: return "This file is not an AnsiView project."
            case .newerVersion(let version):
                return "This project was saved by a newer AnsiView (project version \(version)). Update AnsiView to open it."
            case .damaged(let reason): return "The project file is damaged: \(reason)."
            }
        }
    }

    public init(layers: [CanvasLayer], activeLayer: Int = 0) {
        self.layers = layers.isEmpty ? [CanvasLayer(name: "Background", canvas: EditCanvas())] : layers
        self.activeLayer = min(self.layers.count - 1, max(0, activeLayer))
    }

    private struct Header: Codable {
        var format: String
        var version: Int
    }

    private struct File: Codable {
        var format: String
        var version: Int
        var columns: Int
        var iceColors: Bool
        var title: String
        var author: String
        var group: String
        var comments: [String]
        var fontName: String
        var sauceFlags: Int
        var sauceTInfo34: [Int]
        var activeLayer: Int
        var frames: [Frame]
    }

    private struct Frame: Codable { var layers: [Layer] }

    private struct Layer: Codable {
        var name: String
        var visible: Bool
        var height: Int
        /// Base64 of the AVCELLS1 cell encoding.
        var cells: String
        /// UTF-8 only cells: [x, y, scalar value].
        var scalars: [[UInt32]]
    }

    public func data() throws -> Data {
        let base = layers[0].canvas
        let file = File(
            format: Self.formatName, version: Self.currentVersion, columns: base.columns, iceColors: base.iceColors,
            title: base.title, author: base.author, group: base.group, comments: base.comments, fontName: base.fontName,
            sauceFlags: Int(base.sauceFlags), sauceTInfo34: base.sauceTInfo34.map(Int.init), activeLayer: activeLayer,
            frames: [Frame(layers: layers.map { layer in
                let canvas = layer.canvas
                var scalars: [[UInt32]] = []
                for y in 0..<canvas.height {
                    for x in 0..<canvas.columns { if let s = canvas[x, y].scalar { scalars.append([UInt32(x), UInt32(y), s.value]) } }
                }
                let region = canvas.region(CellRect(x: 0, y: 0, width: canvas.columns, height: canvas.height))
                return Layer(name: layer.name, visible: layer.visible, height: canvas.height,
                             cells: CanvasEditor.encode(region).base64EncodedString(), scalars: scalars)
            })])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    public init(data: Data) throws {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.format == Self.formatName else {
            throw ProjectError.notAProject
        }
        guard header.version <= Self.currentVersion else { throw ProjectError.newerVersion(header.version) }
        let file: File
        do { file = try decoder.decode(File.self, from: data) } catch { throw ProjectError.damaged("missing or invalid fields") }
        guard let frame = file.frames.first, !frame.layers.isEmpty else { throw ProjectError.damaged("no layers") }
        var result: [CanvasLayer] = []
        for layer in frame.layers {
            guard let bytes = Data(base64Encoded: layer.cells), let region = CanvasEditor.decode(bytes),
                  region.width == min(EditCanvas.maxColumns, max(1, file.columns)) else {
                throw ProjectError.damaged("layer \"\(layer.name)\" has unreadable cells")
            }
            var canvas = EditCanvas(columns: file.columns, height: region.height)
            canvas.setIceColors(file.iceColors)
            canvas.paste(region, x: 0, y: 0)
            for entry in layer.scalars where entry.count == 3 {
                guard let scalar = Unicode.Scalar(entry[2]) else { continue }
                var cell = canvas[Int(entry[0]), Int(entry[1])]
                cell.scalar = scalar
                canvas.set(cell, x: Int(entry[0]), y: Int(entry[1]))
            }
            canvas.title = file.title
            canvas.author = file.author
            canvas.group = file.group
            canvas.comments = file.comments
            canvas.fontName = file.fontName
            canvas.sauceFlags = UInt8(clamping: file.sauceFlags)
            canvas.sauceTInfo34 = file.sauceTInfo34.prefix(2).map { UInt16(clamping: $0) }
            result.append(CanvasLayer(name: layer.name, visible: layer.visible, canvas: canvas))
        }
        self.init(layers: result, activeLayer: file.activeLayer)
    }
}
