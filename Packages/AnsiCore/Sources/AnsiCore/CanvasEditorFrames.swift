import Foundation

/// Flipbook frames in the editor (animation plan, rulings 1 to 3). Each frame has its own layers;
/// frame commands are undo steps, choosing a frame is not.
extension CanvasEditor {
    /// Opens `frames` with `current` being edited.
    public convenience init(frames: [AnimationFrame], current: Int = 0) {
        let list = frames.isEmpty ? [AnimationFrame(layers: [])] : frames
        let index = min(list.count - 1, max(0, current))
        self.init(canvas: list[index].layers[list[index].activeLayer].canvas)
        frameStore = list
        activateFrame(index)
    }

    /// Every frame, first to last.
    public var frames: [AnimationFrame] {
        var list = frameStore
        list[currentFrame].layers = layers
        list[currentFrame].activeLayer = activeLayer
        list[currentFrame].edits = liveEdits
        return list
    }

    /// What frame `index` shows (its visible layers flattened).
    public func frameComposite(_ index: Int) -> EditCanvas {
        index == currentFrame ? flattenedCanvas : frameStore[index].composite
    }

    /// The frame before the current one, for the onion skin.
    public var previousFrameComposite: EditCanvas? {
        currentFrame > 0 ? frameStore[currentFrame - 1].composite : nil
    }

    /// New Frame: a copy of the current frame, with an empty edit log, after it.
    public func addFrame() { insertCopy(name: "New Frame", keepLog: false) }

    /// Duplicate Frame: an exact copy (edit log included) after the current frame.
    public func duplicateFrame() { insertCopy(name: "Duplicate Frame", keepLog: true) }

    private func insertCopy(name: String, keepLog: Bool) {
        perform(name) { editor in
            editor.syncFrame()
            var copy = editor.frameStore[editor.currentFrame]
            if !keepLog { copy.edits = [] }
            editor.frameStore.insert(copy, at: editor.currentFrame + 1)
            editor.activateFrame(editor.currentFrame + 1)
        }
    }

    /// Deletes the current frame; the last frame stays.
    public func deleteFrame() {
        guard frameStore.count > 1 else { return }
        perform("Delete Frame") { editor in
            editor.frameStore.remove(at: editor.currentFrame)
            editor.activateFrame(max(0, editor.currentFrame - 1))
        }
    }

    /// Moves frame `from` to position `to`; the frame being edited stays the one edited.
    public func moveFrame(from: Int, to: Int) {
        guard frameStore.indices.contains(from), frameStore.indices.contains(to), from != to else { return }
        perform("Move Frame") { editor in
            editor.syncFrame()
            var order = Array(editor.frameStore.indices)
            let moved = order.remove(at: from)
            order.insert(moved, at: to)
            let editing = order.firstIndex(of: editor.currentFrame) ?? 0
            editor.frameStore = order.map { editor.frameStore[$0] }
            editor.activateFrame(editing)
        }
    }

    /// Edits another frame (not an undo step).
    public func selectFrame(_ index: Int) {
        guard floating == nil, frameStore.indices.contains(index), index != currentFrame else { return }
        syncFrame()
        activateFrame(index)
        clampToCanvas()
        changed()
    }

    public func setFrameDelay(_ index: Int, seconds: Double) {
        guard frameStore.indices.contains(index) else { return }
        perform("Frame Delay") { $0.frameStore[index].delay = seconds }
    }

    // MARK: Helpers

    /// Writes the live layers and log into the current frame's entry.
    func syncFrame() {
        syncActiveLayer()
        frameStore[currentFrame].layers = layerStore
        frameStore[currentFrame].activeLayer = activeLayer
        frameStore[currentFrame].edits = liveEdits
    }

    /// Makes `index` the frame being edited (its entry must be current).
    func activateFrame(_ index: Int) {
        currentFrame = index
        let frame = frameStore[index]
        layerStore = frame.layers
        liveEdits = frame.edits
        activate(frame.activeLayer)
        if tracksEdits { lastLogged = flattenedCanvas }
    }

    /// Moves every cell that changed since the last look to the end of the current frame's log
    /// (ruling 2). A cell has at most one entry, its last edit, so the log never outgrows the
    /// canvas (review I2).
    func logEdits() {
        guard tracksEdits else { return }
        let now = flattenedCanvas
        defer { lastLogged = now }
        guard let before = lastLogged, before.columns == now.columns else { return }
        let time = recording ? clock() - recordStart : nil
        var changed: [CellEdit] = []
        for y in 0..<now.height {
            if y < before.height, before.rows[y] == now.rows[y] { continue }
            for x in 0..<now.columns where before[x, y] != now[x, y] { changed.append(CellEdit(x: x, y: y, time: time)) }
        }
        guard !changed.isEmpty else { return }
        if changed.count == 1, let last = liveEdits.last, last.x == changed[0].x, last.y == changed[0].y { return }
        let columns = now.columns
        let positions = Set(changed.map { $0.y * columns + $0.x })
        liveEdits.removeAll { positions.contains($0.y * columns + $0.x) }
        liveEdits += changed
    }
}
