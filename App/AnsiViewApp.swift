import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let ansiArt = UTType(importedAs: "com.traynham.ansiview.ans")
}

/// Read only document holding the file's bytes.
struct AnsiDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.ansiArt] }

    let source: AnsiSource

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fileExtension = configuration.file.filename.map { ($0 as NSString).pathExtension }
        source = AnsiSource(data: data, fileExtension: fileExtension)
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

    var body: some Scene {
        DocumentGroup(viewing: AnsiDocument.self) { file in
            AnsiPlayerView(source: file.document.source)
        }
        .commands {
            CommandGroup(after: .importExport) {
                Button("Export Image...") { send(#selector(AnsiCanvasView.exportImage(_:))) }
                    .keyboardShortcut("e")
                Button("Export Animation...") { send(#selector(AnsiCanvasView.exportAnimation(_:))) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { send(#selector(AnsiCanvasView.togglePausePlayback(_:))) }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Replay from Start") { send(#selector(AnsiCanvasView.replayAnimation(_:))) }
                    .keyboardShortcut("r")
                Button("Skip to End") { send(#selector(AnsiCanvasView.skipAnimation(_:))) }
                    .keyboardShortcut(".")
                Divider()
                Button("Faster") { baud = PlaybackSpeed.step(baud, by: 1) }
                    .keyboardShortcut("]")
                Button("Slower") { baud = PlaybackSpeed.step(baud, by: -1) }
                    .keyboardShortcut("[")
                Picker("Speed", selection: $baud) {
                    ForEach(PlaybackSpeed.choices, id: \.self) { choice in
                        Text(PlaybackSpeed.label(choice)).tag(choice)
                    }
                }
            }
        }
    }
}

struct AnsiPlayerView: NSViewControllerRepresentable {
    let source: AnsiSource

    func makeNSViewController(context: Context) -> AnsiPlayerViewController {
        AnsiPlayerViewController(source: source)
    }

    func updateNSViewController(_ controller: AnsiPlayerViewController, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsViewController: AnsiPlayerViewController, context: Context
    ) -> CGSize? {
        let ideal = nsViewController.contentSize
        return CGSize(width: proposal.width ?? ideal.width,
                      height: proposal.height ?? min(ideal.height, 900))
    }
}
