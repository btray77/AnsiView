import AnsiCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let ansiArt = UTType(importedAs: "com.traynham.ansiview.ans")
    /// `.asc` files: a separate type only because Quick Look thumbnails may not claim `.asc`.
    static let asciiArt = UTType(importedAs: "com.traynham.ansiview.asc")
}

/// Read only document holding the file's bytes.
struct AnsiDocument: FileDocument {
    /// .bin and .adf belong to other system types; AnsiView opens them as an alternate viewer.
    /// Images are readable too: opening one (File > Open, the Dock, Finder's Open With) shows
    /// the image import window instead of a viewer (image import ruling 11).
    static var readableContentTypes: [UTType] {
        [.ansiArt, .asciiArt, UTType("com.apple.macbinary-archive"), UTType("com.amiga.adf-archive"), .image].compactMap { $0 }
    }

    let source: ArtFile
    /// The file's bytes when it is a picture to import rather than art.
    let imageData: Data?

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fileExtension = configuration.file.filename.map { ($0 as NSString).pathExtension }
        if configuration.contentType.conforms(to: .image) {
            imageData = data
            source = ArtFile(data: Data(), fileExtension: "ans")
        } else {
            imageData = nil
            source = ArtFile(data: data, fileExtension: fileExtension)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}

/// Sends an action to whichever art view is focused.
private func send(_ action: Selector) {
    NSApp.sendAction(action, to: nil, from: nil)
}

/// Asks about unsaved editor windows on Quit (they are not documents, so AppKit would not).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AnsiCanvasView.imageDropHandler = { ImageImportWindowController.open(url: $0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DialingDirectoryStore.shared.directory.showAtLaunch { DialingDirectoryWindowController.show() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        EditorWindowController.canTerminate() ? .terminateNow : .terminateCancel
    }
}

@main
struct AnsiViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(PlaybackSpeed.defaultsKey, store: PlaybackSpeed.defaults)
    private var baud = PlaybackSpeed.defaultBaud
    @AppStorage(PlaybackSpeed.crtEffectKey, store: PlaybackSpeed.defaults)
    private var crtEffect = false
    @AppStorage(PlaybackSpeed.holdFinalFrameKey, store: PlaybackSpeed.defaults)
    private var holdFinalFrame = false
    @AppStorage(PlaybackSpeed.modemSoundsKey, store: PlaybackSpeed.defaults)
    private var modemSounds = false
    @AppStorage(PlaybackSpeed.ansiMusicKey, store: PlaybackSpeed.defaults)
    private var ansiMusic = true
    @AppStorage(PlaybackSpeed.musicAtInstantKey, store: PlaybackSpeed.defaults)
    private var musicAtInstant = true
    @AppStorage(SlideshowSettings.autoAdvanceKey, store: PlaybackSpeed.defaults)
    private var autoAdvance = false
    @AppStorage(SlideshowSettings.dwellKey, store: PlaybackSpeed.defaults)
    private var dwell = SlideshowSettings.defaultDwell
    @AppStorage(ViewerTools.minimapKey) private var showMinimap = true
    @ObservedObject private var palettes = PaletteLibrary.shared
    /// The focused art window's speed; speed commands change that file's remembered speed.
    @FocusedObject private var focusedSpeed: PlayerSpeed?

    /// The focused file's speed, or the global speed when no art window is focused.
    private var speedBinding: Binding<Int> {
        Binding(get: { focusedSpeed?.baud ?? baud },
                set: { newValue in
                    if let focusedSpeed { focusedSpeed.set(newValue) } else { baud = newValue }
                })
    }

    init() {
        Updates.start()
    }

    /// A palette menu item: on when it is the chosen palette; choosing it applies it to the focused window.
    private func paletteBinding(_ name: String?) -> Binding<Bool> {
        Binding(get: { palettes.currentName == name },
                set: { on in
                    guard on else { return }
                    palettes.choose(name)
                    send(#selector(AnsiCanvasView.applyChosenPalette(_:)))
                })
    }

    var body: some Scene {
        DocumentGroup(viewing: AnsiDocument.self) { file in
            if let imageData = file.document.imageData {
                ImageDocumentRedirect(data: imageData, fileURL: file.fileURL)
            } else {
                AnsiPlayerScene(source: file.document.source, fileURL: file.fileURL)
            }
        }
        // A DOS screen (640x400) at one and a half times size.
        .defaultSize(width: 960, height: 600)
        .commands {
            if Updates.isIncluded {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates...") { Updates.checkForUpdates() }
                }
            }
            CommandGroup(after: .newItem) {
                // The viewer's own New stays disabled (documents are read only); this is the editor's.
                Button("New ANSI Art") { EditorWindowController.newArt() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Edit Art") { EditorWindowController.editFocusedArt() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Import Image...") { EditorWindowController.importImage() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Convert Images to ANSI...") { ImageBatchConverter.start() }
                Divider()
                Button("Open Folder or Art Pack...") { GalleryWindowController.chooseAndOpen() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Browse 16colo.rs...") {
                    SixteenColorsWindowController.show(
                        openPack: { url, _ in
                            do { GalleryWindowController.open(collection: try ArtCollection.open(url, scoped: false)) }
                            catch { NSAlert(error: error).runModal() }
                        },
                        openFile: { url in
                            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                                if let error { NSAlert(error: error).runModal() }
                            }
                        },
                        editFile: { url in
                            guard let data = try? Data(contentsOf: url) else { NSSound.beep(); return }
                            let art = ArtFile(data: data, fileExtension: url.pathExtension)
                            EditorWindowController.open(canvas: EditCanvas(file: art),
                                                        name: url.deletingPathExtension().lastPathComponent + " (edited)",
                                                        suggestedFormat: SaveFormat.suggested(for: art.format))
                        })
                }
                Button("Connect to BBS...") { DialingDirectoryWindowController.show() }
                Menu("Open Sample") {
                    ForEach(SampleArt.all(), id: \.url) { sample in
                        Button(sample.title) { SampleArt.open(sample) }
                    }
                }
            }
            // Find in art (plan 9 ruling 2): replaces the text editing group; text fields still get
            // the standard finder when no art view answers.
            CommandGroup(replacing: .textEditing) {
                Menu("Find") {
                    Button("Find...") { FindCommands.send(#selector(AnsiCanvasView.showArtFind(_:)), textFinderTag: .showFindInterface) }
                        .keyboardShortcut("f")
                    Button("Find Next") { FindCommands.send(#selector(AnsiCanvasView.artFindNext(_:)), textFinderTag: .nextMatch) }
                        .keyboardShortcut("g")
                    Button("Find Previous") { FindCommands.send(#selector(AnsiCanvasView.artFindPrevious(_:)), textFinderTag: .previousMatch) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
            }
            CommandGroup(after: .pasteboard) {
                // Sent to the focused editor or viewer canvas; Copy writes all of these at once.
                Menu("Copy As") {
                    Button("Text") { send(#selector(EditorCanvasView.copyAsText(_:))) }
                    Button("ANSI (escape codes, for terminals)") { send(#selector(EditorCanvasView.copyAsANSI(_:))) }
                        .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                    Button("Image") { send(#selector(EditorCanvasView.copyAsImage(_:))) }
                        .keyboardShortcut("c", modifiers: [.command, .option])
                }
            }
            CommandGroup(after: .importExport) {
                Button("Export Image...") { send(#selector(AnsiCanvasView.exportImage(_:))) }
                    .keyboardShortcut("e")
                Button("Export Animation...") { send(#selector(AnsiCanvasView.exportAnimation(_:))) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export Text...") { send(#selector(AnsiCanvasView.exportText(_:))) }
                    .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                Button("Batch Export...") { BatchExportController.start() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Divider()
                Button("Share Image...") { send(#selector(AnsiCanvasView.shareImage(_:))) }
                Button("Share Animation...") { send(#selector(AnsiCanvasView.shareAnimation(_:))) }
                Divider()
                Button("Get Info") { send(#selector(AnsiPlayerViewController.showArtInfo(_:))) }
                    .keyboardShortcut("i")
                Button("Compare With...") { send(#selector(AnsiCanvasView.compareWithFile(_:))) }
                    .help("Shows this piece next to another one with the cells that differ tinted red.")
                Divider()
                ForEach(ArtEditor.all, id: \.bundleIdentifier) { editor in
                    Button(editor.menuTitle) { EditorHandoff.open(in: editor) }
                }
            }
            CommandGroup(before: .toolbar) {
                Toggle("CRT Effect", isOn: $crtEffect)
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Fit to Window") { send(#selector(AnsiCanvasView.zoomToFit(_:))) }
                    .keyboardShortcut("0")
                Button("Integer Fit") { send(#selector(AnsiCanvasView.zoomIntegerFit(_:))) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Button("Actual Size") { send(#selector(AnsiCanvasView.zoomActualSize(_:))) }
                    .keyboardShortcut("1")
                Button("Zoom 2x") { send(#selector(AnsiCanvasView.zoom2x(_:))) }
                    .keyboardShortcut("2")
                Button("Zoom 3x") { send(#selector(AnsiCanvasView.zoom3x(_:))) }
                    .keyboardShortcut("3")
                Divider()
                Button("Presentation Mode") { send(#selector(AnsiPlayerViewController.presentArt(_:))) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Auto Scroll") { send(#selector(AnsiCanvasView.toggleAutoScroll(_:))) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .help("Scrolls tall art smoothly down the window. While it runs: + and - change speed, Space pauses, Escape stops.")
                Button("Show or Hide Pack Info") { send(#selector(GalleryContainerViewController.togglePackInfo(_:))) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help("In a gallery: the pack's FILE_ID.DIZ and NFO files beside the pieces.")
                Toggle("Show Minimap", isOn: $showMinimap)
                    .help("A strip at the right of tall art showing the whole piece; click or drag in it to jump.")
                Menu("Palette") {
                    Toggle("Art's Own Colours", isOn: paletteBinding(nil))
                    Divider()
                    ForEach(palettes.all, id: \.name) { palette in
                        Toggle(palette.name, isOn: paletteBinding(palette.name))
                    }
                    Divider()
                    Button("Next Palette") {
                        palettes.chooseNext()
                        send(#selector(AnsiCanvasView.applyChosenPalette(_:)))
                    }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    Button("Load Palette File...") { palettes.chooseAndLoad() }
                        .help("JASC .pal, GIMP .gpl, Adobe .act, or an XBin, ADF or IDF file's own palette.")
                    Button("Remove Loaded Palettes") { palettes.removeLoaded() }
                        .disabled(palettes.loaded.isEmpty)
                }
                Divider()
            }
            CommandMenu("Art") {
                Button("Fill Selection with Character") { send(#selector(EditorCanvasView.fillWithCharacter(_:))) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Fill Selection with Colour") { send(#selector(EditorCanvasView.fillWithColour(_:))) }
                    .keyboardShortcut("f", modifiers: [.command, .option, .shift])
                Divider()
                Button("Toggle iCE Colours") { send(#selector(EditorCanvasView.toggleIceColors(_:))) }
                Button("Canvas Size...") { send(#selector(EditorCanvasView.canvasSize(_:))) }
                Button("Edit SAUCE...") { send(#selector(EditorCanvasView.editSauce(_:))) }
                Divider()
                Button("Zoom In") { send(#selector(EditorCanvasView.zoomIn(_:))) }
                    .keyboardShortcut("=")
                Button("Zoom Out") { send(#selector(EditorCanvasView.zoomOut(_:))) }
                    .keyboardShortcut("-")
            }
            EditorToolCommands()
            CommandMenu("Playback") {
                Button("Play / Pause") { send(#selector(AnsiCanvasView.togglePausePlayback(_:))) }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Replay from Start") { send(#selector(AnsiCanvasView.replayAnimation(_:))) }
                    .keyboardShortcut("r")
                Button("Skip to End") { send(#selector(AnsiCanvasView.skipAnimation(_:))) }
                    .keyboardShortcut(".")
                Button("Previous Frame") { send(#selector(AnsiCanvasView.previousFrame(_:))) }
                Button("Next Frame") { send(#selector(AnsiCanvasView.nextFrame(_:))) }
                Divider()
                Button("Faster") { speedBinding.wrappedValue = PlaybackSpeed.step(speedBinding.wrappedValue, by: 1) }
                    .keyboardShortcut("]")
                Button("Slower") { speedBinding.wrappedValue = PlaybackSpeed.step(speedBinding.wrappedValue, by: -1) }
                    .keyboardShortcut("[")
                Picker("Speed", selection: speedBinding) {
                    ForEach(PlaybackSpeed.choices, id: \.self) { choice in
                        Text(PlaybackSpeed.label(choice)).tag(choice)
                    }
                }
                Divider()
                Toggle("Hold Final Frame", isOn: $holdFinalFrame)
                Toggle("Modem Sounds", isOn: $modemSounds)
                Divider()
                Toggle("Play ANSI Music", isOn: $ansiMusic)
                    .help("Plays the BASIC PLAY tunes some ANSI art carries, as BBS terminals did. Foreground music pauses the drawing until it ends.")
                Toggle("Play Music at Instant Speed", isOn: $musicAtInstant)
                    .help("At Instant speed the art appears at once; this plays its music once from the start.")
                Button("Mute Music in This Window") { send(#selector(AnsiCanvasView.toggleMusicMute(_:))) }
                    .help("Silences this window's ANSI music, or turns it back on. Other windows are not affected.")
                Button("About ANSI Music...") { MusicPlaybackHelp.showAbout() }
            }
            // SwiftUI takes at most ten entries per builder, so the later menus share a Group.
            Group {
                CommandGroup(before: .windowList) {
                    Button("ANSI Music Editor") { MusicEditorWindowController.show() }
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                    Button("Text to ASCII") { TextToASCIIWindowController.show(editor: nil) }
                    Divider()
                }
                CommandMenu("Terminal") {
                    Button("Disconnect") { TerminalWindowController.focused?.disconnect() }
                    Button("Reconnect") { TerminalWindowController.focused?.reconnect() }
                        .keyboardShortcut("r", modifiers: [.command, .option])
                    Button("Send Username") { TerminalWindowController.focused?.sendUsername() }
                    Button("Send Password") { TerminalWindowController.focused?.sendPassword() }
                    Button("Log In") { TerminalWindowController.focused?.runLogin() }
                        .keyboardShortcut("l", modifiers: [.command, .option])
                    Divider()
                    Menu("Speed") {
                        ForEach(PlaybackSpeed.choices, id: \.self) { choice in
                            Button(choice == 0 ? "Unlimited" : "\(choice) baud") {
                                TerminalWindowController.focused?.setBaud(choice)
                            }
                        }
                    }
                    Menu("Size") {
                        ForEach(TerminalViewController.sizes.indices, id: \.self) { index in
                            let size = TerminalViewController.sizes[index]
                            Button("\(size.columns) x \(size.rows)") {
                                TerminalWindowController.focused?.setSize(columns: size.columns, rows: size.rows)
                            }
                        }
                    }
                    Divider()
                    Button("Capture Session...") { TerminalWindowController.focused?.startCapture() }
                    Button("Stop Capture") { TerminalWindowController.focused?.stopCapture() }
                    Button("Clear Scrollback") { TerminalWindowController.focused?.clearScrollback() }
                    Divider()
                    Button("Upload File(s)...") { TerminalWindowController.focused?.transfers.chooseUpload() }
                        .keyboardShortcut("u", modifiers: [.command, .option])
                        .help("Sends files to the BBS with XMODEM, YMODEM, ZMODEM or Kermit. Start the upload on the BBS first.")
                    Button("Download...") { TerminalWindowController.focused?.transfers.chooseDownload() }
                        .keyboardShortcut("d", modifiers: [.command, .option])
                        .help("Receives files from the BBS. ZMODEM and Kermit downloads usually start by themselves.")
                    Button("Cancel Transfer") { TerminalWindowController.focused?.transfers.cancel() }
                        .help("Stops the running file transfer and tells the BBS to stop (Escape does the same).")
                    Button("Transfer Log") {
                        if let terminal = TerminalWindowController.focused { TransferLogWindowController.show(entry: terminal.entry) }
                    }
                    .help("Every file transfer with this BBS: protocol details, retries, results and SHA-256 checksums.")
                }
                CommandGroup(after: .windowArrangement) {
                    Button("Dialing Directory") { DialingDirectoryWindowController.show() }
                        .keyboardShortcut("b", modifiers: [.command, .option])
                }
                CommandMenu("Slideshow") {
                    Button("Start Slideshow") { send(#selector(AnsiPlayerViewController.startSlideshow(_:))) }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                    Button("Next Art") { send(#selector(SlideshowViewController.nextSlide(_:))) }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    Button("Previous Art") { send(#selector(SlideshowViewController.previousSlide(_:))) }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Divider()
                    Toggle("Auto Advance", isOn: $autoAdvance)
                    Picker("Dwell Time", selection: $dwell) {
                        ForEach(SlideshowSettings.dwellChoices, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                }
            }
        }
    }
}

/// One document window: the player plus its per file speed, published to the menu commands.
struct AnsiPlayerScene: View {
    let source: ArtFile
    let fileURL: URL?
    @StateObject private var speed: PlayerSpeed

    init(source: ArtFile, fileURL: URL?) {
        self.source = source
        self.fileURL = fileURL
        _speed = StateObject(wrappedValue: PlayerSpeed(fileKey: source.identity))
    }

    var body: some View {
        AnsiPlayerView(source: source, fileURL: fileURL, speed: speed)
            .focusedSceneObject(speed)
    }
}

struct AnsiPlayerView: NSViewControllerRepresentable {
    let source: ArtFile
    let fileURL: URL?
    let speed: PlayerSpeed

    func makeNSViewController(context: Context) -> AnsiPlayerViewController {
        let controller = AnsiPlayerViewController(source: source, speed: speed)
        controller.fileURL = fileURL
        controller.sound = ModemSoundPlayer()
        controller.music = AudioMusicOutput()
        ViewerCopy.enable(controller)
        ViewerTools.enable(controller)
        return controller
    }

    func updateNSViewController(_ controller: AnsiPlayerViewController, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsViewController: AnsiPlayerViewController, context: Context
    ) -> CGSize? {
        let ideal = nsViewController.idealViewSize
        return CGSize(width: proposal.width ?? ideal.width,
                      height: proposal.height ?? min(ideal.height, 900))
    }
}

/// An image opened as a document: hands it to the import window and closes its own window.
struct ImageDocumentRedirect: NSViewControllerRepresentable {
    let data: Data
    let fileURL: URL?

    final class Controller: NSViewController {
        var data = Data()
        var name = "Image"
        private var handed = false

        override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)) }

        override func viewWillAppear() {
            super.viewWillAppear()
            view.window?.alphaValue = 0
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            guard !handed else { return }
            handed = true
            ImageImportWindowController.open(data: data, name: name)
            view.window?.close()
        }
    }

    func makeNSViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.data = data
        controller.name = fileURL?.deletingPathExtension().lastPathComponent ?? "Image"
        return controller
    }

    func updateNSViewController(_ controller: Controller, context: Context) {}
}
