import AnsiCore
import AppKit

/// A piano roll for one PLAY tune: rows are the 84 pitches of PLAY's 7 octaves (highest at the
/// top), columns are time in whole notes. Click to add a note, click a note to select it (or move
/// it to the clicked pitch), drag a note's right edge to change its length, Delete to remove it.
/// Typing plays the computer keyboard as a piano (see MusicKeyboard).
final class PianoRollView: NSView {
    static let rowHeight: CGFloat = 11
    static let keyWidth: CGFloat = 54
    static let rows = 84

    var tune = MusicTune() {
        didSet {
            if let selected = selectedIndex, !tune.placed.contains(where: { $0.index == selected }) { selectedIndex = nil }
            updateSize()
            needsDisplay = true
        }
    }
    /// Horizontal zoom.
    var pixelsPerWhole: CGFloat = 192 { didSet { updateSize(); needsDisplay = true } }
    /// Grid used to place clicked notes, in whole notes.
    var grid = 1.0 / 16
    /// Settings for new notes.
    var entryOctave = 4 { didSet { onEntryChange?() } }
    var entryLength = 4 { didSet { onEntryChange?() } }
    var entryDots = 0 { didSet { onEntryChange?() } }
    private(set) var selectedIndex: Int? { didSet { needsDisplay = true } }
    /// Playback position in whole notes, or nil when stopped.
    var playhead: Double? { didSet { if playhead != oldValue { needsDisplay = true } } }

    /// Called after every edit made in the view.
    var onChange: ((MusicTune) -> Void)?
    /// Called when the entry octave, length or dot changes from the keyboard.
    var onEntryChange: (() -> Void)?
    /// Called with a semitone so the editor can sound it while entering notes.
    var onPreview: ((Int) -> Void)?

    private enum Drag { case none, resize(index: Int, start: Double) }
    private var drag = Drag.none

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Click an empty spot to add a note. Click a note to select it or move it to another pitch. "
            + "Drag a note's right edge to change its length. Delete removes the selected note. "
            + "Keys A W S E D F T G Y H U J K play C to C, Z and X change octave, 1 to 7 pick the length, "
            + "period toggles a dot, Space adds a rest."
        updateSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateSize() {
        let width = Self.keyWidth + CGFloat(max(tune.totalLength + 1, 4)) * pixelsPerWhole
        let height = CGFloat(Self.rows) * Self.rowHeight
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
    }

    // MARK: Geometry

    private func y(for semitone: Int) -> CGFloat { CGFloat(Self.rows - 1 - semitone) * Self.rowHeight }
    private func x(for position: Double) -> CGFloat { Self.keyWidth + CGFloat(position) * pixelsPerWhole }
    private func semitone(at point: NSPoint) -> Int { min(Self.rows - 1, max(0, Self.rows - 1 - Int(point.y / Self.rowHeight))) }
    private func position(at point: NSPoint) -> Double { max(0, Double(point.x - Self.keyWidth) / Double(pixelsPerWhole)) }

    private func rect(for placed: MusicTune.Placed) -> NSRect? {
        guard let semitone = placed.semitone else { return nil }
        return NSRect(x: x(for: placed.position), y: y(for: semitone) + 1,
                      width: max(3, CGFloat(placed.length) * pixelsPerWhole - 1), height: Self.rowHeight - 2)
    }

    /// The x of the playhead, for scrolling it into view.
    var playheadX: CGFloat? { playhead.map { x(for: $0) } }

    // MARK: Drawing

    private static let blackKeys: Set<Int> = [1, 3, 6, 8, 10]

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        dirtyRect.fill()
        for semitone in 0..<Self.rows {
            let rowRect = NSRect(x: Self.keyWidth, y: y(for: semitone), width: bounds.width - Self.keyWidth, height: Self.rowHeight)
            guard rowRect.intersects(dirtyRect) else { continue }
            if Self.blackKeys.contains(semitone % 12) {
                (dark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.91, alpha: 1)).setFill()
                rowRect.fill()
            }
            if semitone % 12 == 0 {
                NSColor.separatorColor.setFill()
                NSRect(x: Self.keyWidth, y: rowRect.maxY - 1, width: rowRect.width, height: 1).fill()
            }
        }
        // Grid: sixteenths faint, quarters lighter, whole notes stronger.
        let steps = Int((Double(bounds.width - Self.keyWidth) / Double(pixelsPerWhole)) / (1.0 / 16)) + 1
        for step in 0...steps {
            let gx = x(for: Double(step) / 16)
            guard gx >= dirtyRect.minX - 1, gx <= dirtyRect.maxX + 1 else { continue }
            let alpha: CGFloat = step % 16 == 0 ? 0.45 : step % 4 == 0 ? 0.22 : 0.08
            NSColor.secondaryLabelColor.withAlphaComponent(alpha).setFill()
            NSRect(x: gx, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
        // Rests: a light band across the whole height so gaps are visible.
        for placed in tune.placed where placed.semitone == nil {
            NSColor.systemGray.withAlphaComponent(0.10).setFill()
            NSRect(x: x(for: placed.position), y: 0, width: CGFloat(placed.length) * pixelsPerWhole, height: bounds.height).fill()
        }
        // Notes.
        for placed in tune.placed {
            guard let rect = rect(for: placed), rect.intersects(dirtyRect) else { continue }
            let selected = placed.index == selectedIndex
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            (selected ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.stroke()
            // Length handle.
            NSColor.white.withAlphaComponent(0.6).setFill()
            NSRect(x: rect.maxX - 3, y: rect.minY + 2, width: 2, height: rect.height - 4).fill()
        }
        // Key column.
        let keys = NSRect(x: 0, y: dirtyRect.minY, width: Self.keyWidth, height: dirtyRect.height)
        NSColor.windowBackgroundColor.setFill()
        keys.fill()
        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        for semitone in 0..<Self.rows {
            let keyRect = NSRect(x: 0, y: y(for: semitone), width: Self.keyWidth - 1, height: Self.rowHeight)
            guard keyRect.intersects(dirtyRect) else { continue }
            let black = Self.blackKeys.contains(semitone % 12)
            (black ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
            NSRect(x: black ? 18 : 0, y: keyRect.minY, width: keyRect.width - (black ? 18 : 0), height: keyRect.height - 0.5).fill()
            if semitone % 12 == 0 || black == false && semitone % 12 == 9 {
                let label = PlayString.noteName(semitone) as NSString
                label.draw(at: NSPoint(x: 2, y: keyRect.minY), withAttributes: [.font: font, .foregroundColor: NSColor.black])
            }
        }
        NSColor.separatorColor.setFill()
        NSRect(x: Self.keyWidth - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        // Playhead.
        if let playhead {
            NSColor.systemRed.setFill()
            NSRect(x: x(for: playhead) - 1, y: dirtyRect.minY, width: 2, height: dirtyRect.height).fill()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard point.x > Self.keyWidth else {
            onPreview?(semitone(at: point))
            return
        }
        // The right edge of a note: start resizing.
        for placed in tune.placed {
            if let rect = rect(for: placed), abs(point.x - rect.maxX) <= 5, point.y >= rect.minY - 1, point.y <= rect.maxY + 1 {
                selectedIndex = placed.index
                drag = .resize(index: placed.index, start: placed.position)
                return
            }
        }
        let pitch = semitone(at: point)
        let raw = position(at: point)
        if let hit = tune.placed(at: raw), hit.semitone != nil {
            if hit.semitone != pitch {
                tune.setPitch(index: hit.index, semitone: pitch)
                onChange?(tune)
            }
            selectedIndex = hit.index
        } else {
            let snapped = (raw / grid).rounded(.down) * grid
            let index = tune.addNote(semitone: pitch, at: snapped, length: entryLength, dots: entryDots)
            selectedIndex = index
            onChange?(tune)
        }
        onPreview?(pitch)
        drag = .none
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .resize(let index, let start) = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let length = max(1.0 / 64, position(at: point) - start)
        let before = tune
        tune.setLength(index: index, wholeNotes: length)
        selectedIndex = index
        if tune != before { onChange?(tune) }
    }

    override func mouseUp(with event: NSEvent) {
        drag = .none
    }

    override func resetCursorRects() {
        for placed in tune.placed {
            guard let rect = rect(for: placed) else { continue }
            addCursorRect(NSRect(x: rect.maxX - 5, y: rect.minY, width: 10, height: rect.height), cursor: .resizeLeftRight)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, let key = characters.first,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            if let selectedIndex {
                tune.delete(index: selectedIndex)
                self.selectedIndex = nil
                onChange?(tune)
            }
            return
        case 126, 125: // Up, Down: move the selected note a semitone
            if let selectedIndex, let placed = tune.placed.first(where: { $0.index == selectedIndex }), let semitone = placed.semitone {
                let next = semitone + (event.keyCode == 126 ? 1 : -1)
                tune.setPitch(index: selectedIndex, semitone: next)
                onChange?(tune)
                onPreview?(min(83, max(0, next)))
            }
            return
        default: break
        }
        if let offset = MusicKeyboard.semitoneOffset(for: key) {
            let semitone = min(83, entryOctave * 12 + offset)
            tune.append(semitone: semitone, length: entryLength, dots: entryDots)
            selectedIndex = tune.placed.last?.index
            onChange?(tune)
            onPreview?(semitone)
            scrollToEnd()
            return
        }
        if let length = MusicKeyboard.length(for: key) {
            entryLength = length
            return
        }
        switch key {
        case "z", "Z": entryOctave = max(0, entryOctave - 1)
        case "x", "X": entryOctave = min(6, entryOctave + 1)
        case ".": entryDots = entryDots == 0 ? 1 : 0
        case " ":
            tune.append(semitone: nil, length: entryLength, dots: entryDots)
            onChange?(tune)
            scrollToEnd()
        default: super.keyDown(with: event)
        }
    }

    private func scrollToEnd() {
        scrollToVisible(NSRect(x: x(for: tune.totalLength) - 40, y: visibleRect.minY, width: 80, height: 1))
    }

    /// Scrolls so the given octave's rows are visible (used when a tune loads).
    func scrollToPitch(_ semitone: Int) {
        scrollToVisible(NSRect(x: 0, y: max(0, y(for: semitone) - 120), width: 1, height: 240))
    }
}
