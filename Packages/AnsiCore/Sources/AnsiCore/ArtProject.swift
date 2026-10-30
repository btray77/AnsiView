import Foundation

/// A layered drawing saved as an `.ansiproj` file (editor tools plan, ruling 11): JSON. Version 1
/// holds one frame; version 2 (animation plan, ruling 9) adds every frame's delay and edit log.
public struct ArtProject: Equatable {
    public static let fileExtension = "ansiproj"
    public static let formatName = "AnsiView project"
    public static let currentVersion = 2

    public var frames: [AnimationFrame]
    public var currentFrame: Int

    /// The current frame's layers.
    public var layers: [CanvasLayer] {
        get { frames[currentFrame].layers }
        set { frames[currentFrame].layers = newValue }
    }

    public var activeLayer: Int {
        get { frames[currentFrame].activeLayer }
        set { frames[currentFrame].activeLayer = min(layers.count - 1, max(0, newValue)) }
    }

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
        self.init(frames: [AnimationFrame(layers: layers, activeLayer: activeLayer)])
    }

    public init(frames: [AnimationFrame], currentFrame: Int = 0) {
        self.frames = frames.isEmpty ? [AnimationFrame(layers: [])] : frames
        self.currentFrame = min(self.frames.count - 1, max(0, currentFrame))
    }

    /// Written as version 2; one frame with no edit log stays version 1, byte identical to before.
    var isAnimation: Bool { frames.count > 1 || frames.contains { !$0.edits.isEmpty } }

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
        /// The SAUCE creation date as YYYYMMDD, when the art has one.
        var sauceDate: String?
        /// A fitted 16 colour palette as [r, g, b] triples (image imports saved as XBin).
        var palette: [[Int]]?
        /// The current frame's active layer.
        var activeLayer: Int
        /// Version 2: the frame being edited.
        var currentFrame: Int?
        var frames: [Frame]
    }

    private struct Frame: Codable {
        var layers: [Layer]
        /// Version 2: seconds the frame is held.
        var delay: Double?
        /// Version 2: the frame's active layer.
        var activeLayer: Int?
        /// Version 2: the edit log as [x, y] or [x, y, milliseconds since recording began].
        var edits: [[Int]]?
    }

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
        let animated = isAnimation
        let file = File(
            format: Self.formatName, version: animated ? 2 : 1, columns: base.columns, iceColors: base.iceColors,
            title: base.title, author: base.author, group: base.group, comments: base.comments, fontName: base.fontName,
            sauceFlags: Int(base.sauceFlags), sauceTInfo34: base.sauceTInfo34.map(Int.init),
            sauceDate: base.sauceDate.flatMap { d in
                guard let y = d.year, let m = d.month, let day = d.day else { return nil }
                return String(format: "%04d%02d%02d", y, m, day)
            },
            palette: base.palette.map { $0.map { [Int($0.r), Int($0.g), Int($0.b)] } },
            activeLayer: activeLayer,
            currentFrame: animated ? currentFrame : nil,
            frames: frames.map { frame in
                Frame(layers: frame.layers.map(Self.encodeLayer),
                      delay: animated ? frame.delay : nil,
                      activeLayer: animated ? frame.activeLayer : nil,
                      edits: animated ? frame.edits.map { edit in
                          [edit.x, edit.y] + (edit.time.map { [Int(($0 * 1000).rounded())] } ?? [])
                      } : nil)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    private static func encodeLayer(_ layer: CanvasLayer) -> Layer {
        let canvas = layer.canvas
        var scalars: [[UInt32]] = []
        for y in 0..<canvas.height {
            for x in 0..<canvas.columns { if let s = canvas[x, y].scalar { scalars.append([UInt32(x), UInt32(y), s.value]) } }
        }
        let region = canvas.region(CellRect(x: 0, y: 0, width: canvas.columns, height: canvas.height))
        return Layer(name: layer.name, visible: layer.visible, height: canvas.height,
                     cells: CanvasEditor.encode(region).base64EncodedString(), scalars: scalars)
    }

    public init(data: Data) throws {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.format == Self.formatName else {
            throw ProjectError.notAProject
        }
        guard header.version <= Self.currentVersion else { throw ProjectError.newerVersion(header.version) }
        let file: File
        do { file = try decoder.decode(File.self, from: data) } catch { throw ProjectError.damaged("missing or invalid fields") }
        guard !file.frames.isEmpty, file.frames.allSatisfy({ !$0.layers.isEmpty }) else { throw ProjectError.damaged("no layers") }
        let current = min(file.frames.count - 1, max(0, file.currentFrame ?? 0))
        var frames: [AnimationFrame] = []
        for (index, frame) in file.frames.enumerated() {
            let layers = try frame.layers.map { try Self.decodeLayer($0, file: file) }
            let edits = (frame.edits ?? []).compactMap { entry -> CellEdit? in
                guard entry.count >= 2 else { return nil }
                return CellEdit(x: entry[0], y: entry[1], time: entry.count >= 3 ? Double(entry[2]) / 1000 : nil)
            }
            frames.append(AnimationFrame(layers: layers, activeLayer: frame.activeLayer ?? (index == current ? file.activeLayer : 0),
                                         delay: frame.delay ?? AnimationFrame.defaultDelay, edits: edits))
        }
        self.init(frames: frames, currentFrame: current)
    }

    private static func decodeLayer(_ layer: Layer, file: File) throws -> CanvasLayer {
        // A layer narrower or wider than the canvas is padded or clipped, not refused.
        guard let bytes = Data(base64Encoded: layer.cells), let region = CanvasEditor.decode(bytes) else {
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
        if let triples = file.palette, triples.count == 16, triples.allSatisfy({ $0.count == 3 }) {
            canvas.palette = triples.map { RGB(r: UInt8(clamping: $0[0]), g: UInt8(clamping: $0[1]), b: UInt8(clamping: $0[2])) }
        }
        if let text = file.sauceDate, text.count == 8, let value = Int(text) {
            canvas.sauceDate = DateComponents(year: value / 10000, month: value / 100 % 100, day: value % 100)
        }
        return CanvasLayer(name: layer.name, visible: layer.visible, canvas: canvas)
    }
}
