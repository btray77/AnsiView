import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// Window > ANSI Music Editor: compose BBS "ANSI music" (BASIC PLAY strings) with a piano roll
/// and a PLAY text field kept in sync, play it like a PC speaker, keep snippets, and export.
final class MusicEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var current: MusicEditorWindowController?

    static func show() {
        if let current {
            current.showWindow(nil)
            return
        }
        let controller = MusicEditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ANSI Music Editor"
        window.contentMinSize = NSSize(width: 900, height: 520)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1120, height: 720))
        let windowController = MusicEditorWindowController(window: window)
        window.delegate = windowController
        window.center()
        current = windowController
        windowController.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        (contentViewController as? MusicEditorViewController)?.stopPlayback()
        Self.current = nil
    }
}

/// Where the snippet library lives: the app container's Application Support folder.
enum MusicLibraryStore {
    static var url: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("AnsiView", isDirectory: true).appendingPathComponent("MusicLibrary.json")
    }

    static func load() -> MusicLibrary {
        guard let url, let data = try? Data(contentsOf: url) else { return MusicLibrary() }
        return MusicLibrary.decode(data)
    }

    static func save(_ library: MusicLibrary) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try library.encoded().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Short explanations behind the (?) buttons.
enum MusicHelp {
    static let mode = "MF (foreground): a terminal waits until the music has finished before it shows more of the screen.\n\n"
        + "MB (background): the music plays while the screen keeps drawing."
    static let articulation = "How much of each note sounds:\n\nNormal (MN): 7/8 of the note, with a short gap.\n"
        + "Legato (ML): the whole note, so notes run together.\nStaccato (MS): 3/4 of the note, short and detached."
    static let introducer = "The escape sequence that starts the music. All of them end with Ctrl-N (0x0E).\n\n"
        + "ESC[M: the original from Qmodem, Telix and TeleMate. It is also the standard Delete Line code, so modern "
        + "terminals such as SyncTERM only treat it as music when ANSI music is fully enabled.\n\n"
        + "ESC[N: BananaCom's version, accepted by SyncTERM by default.\n\nESC[|: SyncTERM's standards-safe form."
    static let shiftIn = "Adds Shift In (0x0F) after the 0x0E that ends the music. 0x0E is also Shift Out, which "
        + "garbles the screen on terminals without ANSI music; 0x0F undoes it (SyncTERM's advice)."
    static let playString = "The tune as a BASIC PLAY string, the language ANSI music uses:\n\n"
        + "A to G: notes (# or + sharp, - flat), then an optional length (1 whole, 4 quarter ... 64) and dots.\n"
        + "O0 to O6: octave. < and >: octave down and up. L1 to L64: default length.\n"
        + "P: pause. N0 to N84: note by number. T32 to T255: tempo in quarter notes per minute.\n"
        + "MN, ML, MS: normal, legato, staccato. MF, MB: foreground, background."
}

final class MusicEditorViewController: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var tune = MusicTune(play: MusicDemos.all[0].play)
    private var library = MusicLibraryStore.load()
    private let player = MusicAudioPlayer()
    private var timer: Timer?
    private var name = "Untitled"

    let roll = PianoRollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private let scroll = NSScrollView()
    let playField = NSTextField()
    private let warningLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "0.0 s")
    private let playButton = NSButton()
    private let stopButton = NSButton()
    private let tempoField = NSTextField()
    private let tempoStepper = NSStepper()
    private let articulationPopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let waveformPopup = NSPopUpButton()
    private let octavePopup = NSPopUpButton()
    private let lengthPopup = NSPopUpButton()
    private let dotCheckbox = NSButton(checkboxWithTitle: "Dotted", target: nil, action: nil)
    private let zoomSlider = NSSlider()
    private let introducerPopup = NSPopUpButton()
    private let shiftInCheckbox = NSButton(checkboxWithTitle: "Add SI after music", target: nil, action: nil)
    private let libraryTable = NSTableView()
    private let demoPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let exportPopup = NSPopUpButton(frame: .zero, pullsDown: true)

    private static let lengths = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 720))
        buildInterface()
        refresh(updateText: true)
        roll.scrollToPitch(42)
    }

    // MARK: Building the window

    private func button(_ title: String, _ action: Selector, tip: String, symbol: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        button.toolTip = tip
        return button
    }

    private func help(_ text: String, tip: String) -> NSButton {
        let button = HelpButton(text: text)
        button.toolTip = tip
        return button
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func buildInterface() {
        // Transport and tune settings.
        playButton.target = self
        playButton.action = #selector(togglePlay(_:))
        playButton.bezelStyle = .rounded
        playButton.toolTip = "Play the tune, or pause it while it plays."
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        stopButton.bezelStyle = .rounded
        stopButton.title = "Stop"
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
        stopButton.imagePosition = .imageLeading
        stopButton.toolTip = "Stop playback and return to the start."
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.toolTip = "Playback position and the tune's length in seconds."

        tempoField.integerValue = tune.tempo
        tempoField.frame.size.width = 44
        tempoField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        tempoField.target = self
        tempoField.action = #selector(tempoTyped(_:))
        tempoField.toolTip = "Starting tempo in quarter notes per minute (T32 to T255). PLAY's default is 120."
        tempoStepper.minValue = 32
        tempoStepper.maxValue = 255
        tempoStepper.increment = 5
        tempoStepper.target = self
        tempoStepper.action = #selector(tempoStepped(_:))
        tempoStepper.toolTip = "Change the starting tempo by 5."

        articulationPopup.addItems(withTitles: ["Normal (MN)", "Legato (ML)", "Staccato (MS)"])
        articulationPopup.target = self
        articulationPopup.action = #selector(articulationChosen(_:))
        articulationPopup.toolTip = "How much of each note sounds at the start of the tune (MN, ML or MS)."
        modePopup.addItems(withTitles: ["Foreground (MF)", "Background (MB)"])
        modePopup.target = self
        modePopup.action = #selector(modeChosen(_:))
        modePopup.toolTip = "Whether a terminal holds the screen while the music plays (MF) or keeps drawing (MB)."
        waveformPopup.addItems(withTitles: Waveform.allCases.map(\.title))
        waveformPopup.toolTip = "The sound used for playback and WAV export: a PC speaker square wave, or a softer tone."

        let transport = row([playButton, stopButton, timeLabel, NSView(),
                             label("Tempo"), tempoField, tempoStepper,
                             label("Articulation"), articulationPopup,
                             help(MusicHelp.articulation, tip: "What normal, legato and staccato mean."),
                             label("Play"), modePopup, help(MusicHelp.mode, tip: "What MF and MB mean."),
                             label("Sound"), waveformPopup])

        // Note entry.
        octavePopup.addItems(withTitles: (0...6).map { "Octave \($0)" })
        octavePopup.target = self
        octavePopup.action = #selector(entryChosen(_:))
        octavePopup.toolTip = "Octave for notes typed on the keyboard (Z and X change it). Octave 4 is PLAY's default."
        lengthPopup.addItems(withTitles: Self.lengths.map { "1/\($0)" })
        lengthPopup.target = self
        lengthPopup.action = #selector(entryChosen(_:))
        lengthPopup.toolTip = "Length of new notes: 1/4 is a quarter note. Keys 1 to 7 pick 1/1 to 1/64."
        dotCheckbox.target = self
        dotCheckbox.action = #selector(entryChosen(_:))
        dotCheckbox.toolTip = "Make new notes dotted (one and a half times as long). The period key toggles it."
        zoomSlider.minValue = 64
        zoomSlider.maxValue = 768
        zoomSlider.doubleValue = Double(roll.pixelsPerWhole)
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged(_:))
        zoomSlider.toolTip = "Zoom the piano roll in time."
        zoomSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let keysHint = label("Keys: A W S E D F T G Y H U J K = C to C, Z/X octave, 1-7 length, . dot, Space rest")
        keysHint.font = .systemFont(ofSize: 11)
        keysHint.toolTip = "Click the piano roll first, then type to enter notes at the end of the tune."
        let entry = row([label("New notes"), octavePopup, lengthPopup, dotCheckbox, label("Zoom"), zoomSlider, NSView(), keysHint])

        // PLAY text.
        playField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        playField.delegate = self
        playField.lineBreakMode = .byWordWrapping
        playField.usesSingleLineMode = false
        playField.cell?.wraps = true
        playField.cell?.isScrollable = false
        playField.toolTip = "The PLAY string. Edit it here and the piano roll follows; edit the piano roll and this text is rewritten in canonical form."
        playField.heightAnchor.constraint(equalToConstant: 46).isActive = true
        warningLabel.textColor = .systemOrange
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.toolTip = "Characters PLAY does not understand are skipped; they are listed here."
        let textRow = row([label("PLAY"), playField, help(MusicHelp.playString, tip: "The PLAY string language in brief.")])
        playField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Piano roll.
        scroll.documentView = roll
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        roll.onChange = { [weak self] tune in
            self?.tune = tune
            self?.refresh(updateText: true)
        }
        roll.onEntryChange = { [weak self] in self?.syncEntryControls() }
        roll.onPreview = { [weak self] semitone in self?.preview(semitone) }

        // Library.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Snippet"
        libraryTable.addTableColumn(column)
        libraryTable.headerView = nil
        libraryTable.dataSource = self
        libraryTable.delegate = self
        libraryTable.doubleAction = #selector(insertSnippet(_:))
        libraryTable.target = self
        libraryTable.toolTip = "Your saved snippets. Double-click one to insert it at the end of the tune."
        let tableScroll = NSScrollView()
        tableScroll.documentView = libraryTable
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        let saveSnippet = button("Save Tune as Snippet...", #selector(saveSnippet(_:)),
                                 tip: "Keep the current tune in your library under a name.")
        let insert = button("Insert", #selector(insertSnippet(_:)),
                            tip: "Insert the selected snippet after the selected note, or at the end.")
        let load = button("Open", #selector(loadSnippet(_:)), tip: "Replace the current tune with the selected snippet.")
        let remove = button("Delete", #selector(deleteSnippet(_:)), tip: "Remove the selected snippet from the library.")
        demoPopup.addItem(withTitle: "Demo Tunes")
        for demo in MusicDemos.all {
            let item = NSMenuItem(title: demo.title, action: #selector(loadDemo(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = demo.credit
            demoPopup.menu?.addItem(item)
        }
        demoPopup.toolTip = "Load a sample tune: public domain melodies and original pieces."
        let sideTitle = NSTextField(labelWithString: "Library")
        sideTitle.font = .boldSystemFont(ofSize: 12)
        let side = NSStackView(views: [sideTitle, tableScroll, row([insert, load, remove]), saveSnippet, demoPopup])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 6
        tableScroll.widthAnchor.constraint(equalToConstant: 230).isActive = true
        side.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let middle = NSStackView(views: [scroll, side])
        middle.orientation = .horizontal
        middle.alignment = .top
        middle.spacing = 10
        side.heightAnchor.constraint(equalTo: middle.heightAnchor).isActive = true
        scroll.heightAnchor.constraint(equalTo: middle.heightAnchor).isActive = true

        // Import and export.
        let importButton = button("Import from ANSI File...", #selector(importFromAnsi(_:)),
                                  tip: "Find the music in an .ans file and load one of its sequences.", symbol: "square.and.arrow.down")
        exportPopup.addItem(withTitle: "Export")
        let exports: [(String, Selector, String)] = [
            ("Copy Escape Sequence", #selector(copyEscape(_:)), "Copy the music as an ANSI escape sequence to paste into art or a BBS message."),
            ("Save as ANSI Snippet...", #selector(saveSnippetFile(_:)), "Save the escape sequence alone as an .ans file."),
            ("Embed into ANSI File...", #selector(embedIntoFile(_:)), "Insert the music into a copy of an existing .ans file at a position you choose."),
            ("Export WAV...", #selector(exportWAV(_:)), "Save the tune as a WAV sound file with the chosen sound."),
            ("Export MIDI...", #selector(exportMIDI(_:)), "Save the notes as a standard MIDI file (an extra; ANSI music itself is the PLAY string)."),
        ]
        for (title, action, tip) in exports {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = tip
            exportPopup.menu?.addItem(item)
        }
        exportPopup.toolTip = "Copy, save, embed or export the tune."
        introducerPopup.addItems(withTitles: ["ESC[M", "ESC[N", "ESC[|"])
        introducerPopup.toolTip = "The escape sequence that starts the music in copied, saved and embedded output."
        shiftInCheckbox.state = .on
        shiftInCheckbox.toolTip = "Follow the music with 0x0F so terminals without ANSI music recover."
        let bottom = row([importButton, NSView(), label("Introducer"), introducerPopup,
                          help(MusicHelp.introducer, tip: "What ESC[M, ESC[N and ESC[| mean."),
                          shiftInCheckbox, help(MusicHelp.shiftIn, tip: "Why Shift In follows the music."), exportPopup])

        let main = NSStackView(views: [transport, entry, textRow, warningLabel, middle, bottom])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 8
        main.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        main.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            main.topAnchor.constraint(equalTo: view.topAnchor),
            main.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        for stack in [transport, entry, textRow, middle, bottom] {
            stack.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -24).isActive = true
        }
        middle.setContentHuggingPriority(.defaultLow, for: .vertical)
        middle.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        syncEntryControls()
        updatePlayButton()
    }

    // MARK: State to controls

    private func refresh(updateText: Bool) {
        roll.tune = tune
        if updateText {
            playField.stringValue = tune.play
            warningLabel.stringValue = ""
        }
        tempoField.integerValue = tune.tempo
        tempoStepper.integerValue = tune.tempo
        articulationPopup.selectItem(at: Articulation.allCases.firstIndex(of: tune.articulation) ?? 0)
        modePopup.selectItem(at: tune.background ? 1 : 0)
        updateTime()
    }

    private func syncEntryControls() {
        octavePopup.selectItem(at: roll.entryOctave)
        lengthPopup.selectItem(at: Self.lengths.firstIndex(of: roll.entryLength) ?? 3)
        dotCheckbox.state = roll.entryDots > 0 ? .on : .off
    }

    private func updateTime() {
        let total = tune.duration
        let now = player.isActive ? player.currentTime : 0
        timeLabel.stringValue = String(format: "%.1f / %.1f s", now, total)
    }

    private func updatePlayButton() {
        let playing = player.isPlaying
        playButton.title = playing ? "Pause" : "Play"
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: playButton.title)
        playButton.imagePosition = .imageLeading
    }

    // MARK: Text and controls

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === playField else { return }
        let parsed = PlayString.parse(playField.stringValue)
        tune = MusicTune(play: playField.stringValue)
        warningLabel.stringValue = parsed.warnings.isEmpty ? "" : parsed.warnings.prefix(5).joined(separator: "; ")
        refresh(updateText: false)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === playField else { return }
        playField.stringValue = tune.play
    }

    @objc private func tempoTyped(_ sender: NSTextField) {
        tune.tempo = sender.integerValue
        refresh(updateText: true)
    }

    @objc private func tempoStepped(_ sender: NSStepper) {
        tune.tempo = sender.integerValue
        refresh(updateText: true)
    }

    @objc private func articulationChosen(_ sender: NSPopUpButton) {
        tune.articulation = Articulation.allCases[max(0, sender.indexOfSelectedItem)]
        refresh(updateText: true)
    }

    @objc private func modeChosen(_ sender: NSPopUpButton) {
        tune.background = sender.indexOfSelectedItem == 1
        refresh(updateText: true)
    }

    @objc private func entryChosen(_ sender: Any) {
        roll.entryOctave = max(0, octavePopup.indexOfSelectedItem)
        roll.entryLength = Self.lengths[max(0, lengthPopup.indexOfSelectedItem)]
        roll.entryDots = dotCheckbox.state == .on ? 1 : 0
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        roll.pixelsPerWhole = CGFloat(sender.doubleValue)
    }

    // MARK: Playback

    private var waveform: Waveform { Waveform.allCases[max(0, waveformPopup.indexOfSelectedItem)] }

    @objc func togglePlay(_ sender: Any?) {
        if player.isPlaying {
            player.pause()
        } else if player.isPaused {
            player.resume()
        } else {
            player.onFinish = { [weak self] in self?.stopPlayback() }
            player.play(tune.notes, waveform: waveform)
            startTimer()
        }
        updatePlayButton()
    }

    @objc private func stop(_ sender: Any?) {
        stopPlayback()
    }

    func stopPlayback() {
        player.stop()
        timer?.invalidate()
        timer = nil
        roll.playhead = nil
        updatePlayButton()
        updateTime()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let seconds = player.currentTime
        roll.playhead = Self.position(at: seconds, in: tune)
        if let x = roll.playheadX {
            let visible = scroll.contentView.bounds
            if x > visible.maxX - 40 || x < visible.minX + PianoRollView.keyWidth {
                roll.scroll(NSPoint(x: max(0, x - PianoRollView.keyWidth - 40), y: visible.minY))
            }
        }
        updateTime()
    }

    /// Converts seconds into the piano roll's whole-note position.
    static func position(at seconds: Double, in tune: MusicTune) -> Double {
        let notes = tune.notes, placed = tune.placed
        for (note, place) in zip(notes, placed) where seconds < note.end {
            let fraction = note.duration > 0 ? (seconds - note.start) / note.duration : 0
            return place.position + max(0, fraction) * place.length
        }
        return tune.totalLength
    }

    /// Sounds one note while entering, unless the tune is playing.
    private func preview(_ semitone: Int) {
        // Never interrupt the tune itself; previews replace each other.
        if player.isActive, player.onFinish != nil { return }
        let note = TimedNote(semitone: semitone, frequency: PlayString.frequency(semitone: semitone), start: 0,
                             sounding: 0.18, duration: 0.2, background: false)
        player.onFinish = nil
        player.play([note], waveform: waveform)
    }

    // MARK: Library

    func numberOfRows(in tableView: NSTableView) -> Int { library.snippets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let snippet = library.snippets[row]
        let cell = NSTextField(labelWithString: snippet.name)
        cell.toolTip = snippet.play
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    private var selectedSnippet: MusicLibrary.Snippet? {
        let row = libraryTable.selectedRow
        return library.snippets.indices.contains(row) ? library.snippets[row] : nil
    }

    @objc private func saveSnippet(_ sender: Any?) {
        guard !tune.items.isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Save Snippet"
        alert.informativeText = "Name for this tune in your library:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespaces)
        library.add(name: title.isEmpty ? "Untitled" : title, play: tune.play)
        MusicLibraryStore.save(library)
        libraryTable.reloadData()
    }

    @objc private func insertSnippet(_ sender: Any?) {
        guard let snippet = selectedSnippet else { NSSound.beep(); return }
        var index = tune.items.count
        if let selected = roll.selectedIndex { index = selected + 1 }
        tune.insert(MusicTune(play: snippet.play), at: index)
        refresh(updateText: true)
    }

    @objc private func loadSnippet(_ sender: Any?) {
        guard let snippet = selectedSnippet else { NSSound.beep(); return }
        load(MusicTune(play: snippet.play), name: snippet.name)
    }

    @objc private func deleteSnippet(_ sender: Any?) {
        guard let snippet = selectedSnippet else { NSSound.beep(); return }
        library.remove(id: snippet.id)
        MusicLibraryStore.save(library)
        libraryTable.reloadData()
    }

    @objc private func loadDemo(_ sender: NSMenuItem) {
        guard let demo = MusicDemos.all.first(where: { $0.title == sender.title }) else { return }
        load(MusicTune(play: demo.play), name: demo.title)
    }

    func load(_ newTune: MusicTune, name: String) {
        stopPlayback()
        tune = newTune
        self.name = name
        refresh(updateText: true)
        if let first = tune.placed.first(where: { $0.semitone != nil })?.semitone { roll.scrollToPitch(first) }
        roll.scroll(NSPoint(x: 0, y: scroll.contentView.bounds.minY))
    }

    // MARK: Import

    private static var artTypes: [UTType] {
        ["ans", "asc", "txt", "nfo", "diz", "ice", "pcb", "avt"].compactMap { UTType(filenameExtension: $0) }
    }

    @objc private func importFromAnsi(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.artTypes
        panel.allowsOtherFileTypes = true
        panel.message = "Choose an ANSI file that contains music."
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let art = ArtFile(data: data, fileExtension: url.pathExtension)
        let sequences = AnsiMusic.scan(art.stream, mode: .all).playable
        guard !sequences.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No ANSI music found"
            alert.informativeText = "\(url.lastPathComponent) has no ESC[M, ESC[N or ESC[| music sequences."
            alert.runModal()
            return
        }
        var chosen = sequences[0]
        if sequences.count > 1 {
            let alert = NSAlert()
            alert.messageText = "Choose a music sequence"
            alert.informativeText = "\(url.lastPathComponent) has \(sequences.count) music sequences."
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
            for sequence in sequences {
                popup.addItem(withTitle: String(format: "Byte %d: %.1f s, %@", sequence.offset, sequence.duration,
                                                String(sequence.body.prefix(30))))
            }
            popup.addItem(withTitle: "All sequences, one after another")
            alert.accessoryView = popup
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if popup.indexOfSelectedItem == sequences.count {
                var joined = MusicTune(items: sequences[0].items, startingFrom: sequences[0].startState)
                for sequence in sequences.dropFirst() {
                    joined.insert(MusicTune(items: sequence.items, startingFrom: sequence.startState), at: joined.items.count)
                }
                load(joined, name: url.deletingPathExtension().lastPathComponent)
                return
            }
            chosen = sequences[popup.indexOfSelectedItem]
        }
        load(MusicTune(items: chosen.items, startingFrom: chosen.startState), name: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: Export

    private var introducer: MusicIntroducer { MusicIntroducer.allCases[max(0, introducerPopup.indexOfSelectedItem)] }

    var escapeSequence: [UInt8] {
        AnsiMusic.escape(tune.play, introducer: introducer, shiftIn: shiftInCheckbox.state == .on)
    }

    @objc private func copyEscape(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: escapeSequence, as: UTF8.self), forType: .string)
    }

    private func savePanel(_ fileName: String, _ types: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func write(_ data: Data, to url: URL) {
        do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }

    @objc private func saveSnippetFile(_ sender: Any?) {
        guard let url = savePanel("\(name).ans", [UTType(filenameExtension: "ans") ?? .data]) else { return }
        write(Data(escapeSequence), to: url)
    }

    @objc private func embedIntoFile(_ sender: Any?) {
        let open = NSOpenPanel()
        open.allowedContentTypes = Self.artTypes
        open.allowsOtherFileTypes = true
        open.message = "Choose the ANSI file to add the music to. A new copy is saved; the original is not changed."
        guard open.runModal() == .OK, let source = open.url, let data = try? Data(contentsOf: source) else { return }
        let alert = NSAlert()
        alert.messageText = "Where should the music play?"
        alert.informativeText = "The music starts when the viewer or terminal reaches this point of the file."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        popup.addItems(withTitles: ["At the start", "At the end of the art", "After line..."])
        let lineField = NSTextField(frame: NSRect(x: 210, y: 2, width: 60, height: 22))
        lineField.integerValue = 1
        lineField.toolTip = "The line number after which the music starts."
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        accessory.addSubview(popup)
        accessory.addSubview(lineField)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let position: AnsiMusic.EmbedPosition
        switch popup.indexOfSelectedItem {
        case 0: position = .start
        case 1: position = .end
        default: position = .afterLine(max(0, lineField.integerValue))
        }
        let output = AnsiMusic.embed(escapeSequence, into: [UInt8](data), at: position)
        let base = source.deletingPathExtension().lastPathComponent
        guard let url = savePanel("\(base) with music.\(source.pathExtension.isEmpty ? "ans" : source.pathExtension)",
                                  [UTType(filenameExtension: source.pathExtension.isEmpty ? "ans" : source.pathExtension) ?? .data])
        else { return }
        write(Data(output), to: url)
    }

    @objc private func exportWAV(_ sender: Any?) {
        guard !tune.notes.isEmpty, let url = savePanel("\(name).wav", [.wav]) else { return }
        write(WAVFile.data(MusicSynth(waveform: waveform).render(tune.notes)), to: url)
    }

    @objc private func exportMIDI(_ sender: Any?) {
        guard !tune.notes.isEmpty, let url = savePanel("\(name).mid", [.midi]) else { return }
        write(MIDIFile.data(tune.notes), to: url)
    }
}

/// A round (?) button that shows a short explanation in a popover.
final class HelpButton: NSButton {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(frame: NSRect(x: 0, y: 0, width: 21, height: 21))
        bezelStyle = .helpButton
        title = ""
        target = self
        action = #selector(showHelp(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func showHelp(_ sender: Any?) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 320
        label.translatesAutoresizingMaskIntoConstraints = false
        let controller = NSViewController()
        controller.view = NSView()
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -10),
            label.widthAnchor.constraint(equalToConstant: 320),
        ])
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}
