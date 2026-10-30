import AnsiCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let ansiArt = UTType(importedAs: "com.traynham.ansiview.ans")
}

/// Read only document holding the file's bytes.
struct AnsiDocument: FileDocument {
    /// .bin and .adf belong to other system types; AnsiView opens them as an alternate viewer.
    static var readableContentTypes: [UTType] {
        [.ansiArt, UTType("com.apple.macbinary-archive"), UTType("com.amiga.adf-archive")].compactMap { $0 }
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
    /// The focused art window's speed; speed commands change that file's remembered speed.
    @FocusedObject private var focusedSpeed: PlayerSpeed?

    /// The focused file's speed, or the global speed when no art window is focused.
    private var speedBinding: Binding<Int> {
        Binding(get: { focusedSpeed?.baud ?? baud },
                set: { newValue in
                    if let focusedSpeed { focusedSpeed.set(newValue) } else { baud = newValue }
                })
    }

    var body: some Scene {
        DocumentGroup(viewing: AnsiDocument.self) { file in
            AnsiPlayerScene(source: file.document.source)
        }
        // A DOS screen (640x400) at one and a half times size.
        .defaultSize(width: 960, height: 600)
        .commands {
            CommandGroup(after: .importExport) {
                Button("Export Image...") { send(#selector(AnsiCanvasView.exportImage(_:))) }
                    .keyboardShortcut("e")
                Button("Export Animation...") { send(#selector(AnsiCanvasView.exportAnimation(_:))) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(before: .toolbar) {
                Toggle("CRT Effect", isOn: $crtEffect)
                    .keyboardShortcut("k", modifiers: [.command, .shift])
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
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Frame") { send(#selector(AnsiCanvasView.nextFrame(_:))) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
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
        }
    }
}

/// One document window: the player plus its per file speed, published to the menu commands.
struct AnsiPlayerScene: View {
    let source: ArtFile
    @StateObject private var speed: PlayerSpeed

    init(source: ArtFile) {
        self.source = source
        _speed = StateObject(wrappedValue: PlayerSpeed(fileKey: source.identity))
    }

    var body: some View {
        AnsiPlayerView(source: source, speed: speed)
            .focusedSceneObject(speed)
    }
}

struct AnsiPlayerView: NSViewControllerRepresentable {
    let source: ArtFile
    let speed: PlayerSpeed

    func makeNSViewController(context: Context) -> AnsiPlayerViewController {
        let controller = AnsiPlayerViewController(source: source, speed: speed)
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
