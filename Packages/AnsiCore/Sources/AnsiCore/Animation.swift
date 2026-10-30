import Foundation

/// One change in a frame's edit log (animation plan, ruling 2): the cell that changed and, in
/// record mode, seconds since recording began (ruling 3).
public struct CellEdit: Equatable {
    public var x: Int
    public var y: Int
    public var time: Double?

    public init(x: Int, y: Int, time: Double? = nil) {
        self.x = x
        self.y = y
        self.time = time
    }
}

/// One screen of a flipbook animation (ruling 1): its own layers, how long it stays on screen
/// once drawn, and the order its cells were edited in.
public struct AnimationFrame: Equatable {
    public static let defaultDelay = 0.5
    public static let delayRange: ClosedRange<Double> = 0...60

    public var layers: [CanvasLayer]
    public var activeLayer: Int
    /// Seconds the finished frame is held before the next one starts drawing.
    public var delay: Double {
        didSet { delay = Self.clampDelay(delay) }
    }
    public var edits: [CellEdit]

    public init(layers: [CanvasLayer], activeLayer: Int = 0, delay: Double = AnimationFrame.defaultDelay, edits: [CellEdit] = []) {
        self.layers = layers.isEmpty ? [CanvasLayer(name: "Background", canvas: EditCanvas())] : layers
        self.activeLayer = min(self.layers.count - 1, max(0, activeLayer))
        self.delay = Self.clampDelay(delay)
        self.edits = edits
    }

    /// What the frame shows: its visible layers flattened.
    public var composite: EditCanvas {
        layers.count == 1 && layers[0].visible ? layers[0].canvas : LayerStack.composite(layers)
    }

    static func clampDelay(_ value: Double) -> Double {
        value.isFinite ? min(delayRange.upperBound, max(delayRange.lowerBound, value)) : defaultDelay
    }
}

/// How an exported animation writes each frame (ruling 4).
public enum AnimationOrder: String, CaseIterable {
    /// The changed cells in the order they were drawn (the default).
    case asDrawn
    /// The changed cells row by row, left to right.
    case topDown
    /// Clear the screen and draw the whole frame.
    case fullRedraw

    public var label: String {
        switch self {
        case .asDrawn: return "As drawn"
        case .topDown: return "Top down"
        case .fullRedraw: return "Full redraw"
        }
    }
}

/// Delays made of padding characters that cost time at a baud rate (ruling 5).
public enum PaddingDelay {
    /// Carriage return: moves the cursor to column 1 and draws nothing; repeated, it does nothing.
    public static let byte: UInt8 = 0x0D
    /// Bits sent per character: 8 data bits plus a start and a stop bit (8N1), as the player assumes.
    public static let bitsPerCharacter = 10

    /// Seconds one character takes at `baud` (0 for unlimited).
    public static func characterTime(baud: Int) -> Double {
        baud > 0 ? Double(bitsPerCharacter) / Double(baud) : 0
    }

    /// Characters that take `seconds` at `baud`, rounded to the nearest; 0 for unlimited speed.
    public static func characters(seconds: Double, baud: Int) -> Int {
        guard baud > 0, seconds > 0, seconds.isFinite else { return 0 }
        return Int((seconds * Double(baud) / Double(bitsPerCharacter)).rounded())
    }
}
