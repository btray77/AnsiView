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
    static var readableContentTypes: [UTType] {
        [.ansiArt, .asciiArt, UTType("com.apple.macbinary-archive"), UTType("com.amiga.adf-archive")].compactMap { $0 }
    }

    let source: ArtFile

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fileExtension = configuration.file.filename.map { ($0 as NSString).pathExtension }
        source = ArtFile(data: data, fileExtension: fileExtension)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}

/// Sends an action to whichever art view is focused.
private func send(_ action: Selector) {
    NSApp.sendAction(action, to: nil, from: nil)
}

@main
struct AnsiViewApp: App {
    @AppStorage(PlaybackSpeed.defaultsKey, store: PlaybackSpeed.defaults)
    private var baud = PlaybackSpeed.defaultBaud
    @AppStorage(PlaybackSpeed.crtEffectKey, store: PlaybackSpeed.defaults)
    private var crtEffect = false
    @AppStorage(PlaybackSpeed.holdFinalFrameKey, store: PlaybackSpeed.defaults)
    private var holdFinalFrame = false
    @AppStorage(PlaybackSpeed.modemSoundsKey, store: PlaybackSpeed.defaults)
    private var modemSounds = false
    @AppStorage(SlideshowSettings.autoAdvanceKey, store: PlaybackSpeed.defaults)
    private var autoAdvance = false
    @AppStorage(SlideshowSettings.dwellKey, store: PlaybackSpeed.defaults)
    private var dwell = SlideshowSettings.defaultDwell
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

    var body: some Scene {
        DocumentGroup(viewing: AnsiDocument.self) { file in
            AnsiPlayerScene(source: file.document.source, fileURL: file.fileURL)
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
                        })
                }
                Menu("Open Sample") {
                    ForEach(SampleArt.all(), id: \.url) { sample in
                        Button(sample.title) { SampleArt.open(sample) }
                    }
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
            }
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
