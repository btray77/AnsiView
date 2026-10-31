import AnsiCore
import SwiftUI
import UIKit

/// Owns the player for one open piece so the toolbar can drive it.
@MainActor
final class ViewerModel: ObservableObject {
    let item: ArtItem
    let file: ArtFile
    let player: ArtPlayerViewController
    @Published private(set) var state: ArtPlayback.State = .finished
    @Published var baud: Int {
        didSet {
            MobilePlaybackSpeed.current = baud
            player.baud = baud
        }
    }

    init(item: ArtItem, playback: ArtPlayback) {
        self.item = item
        self.file = playback.file
        let baud = MobilePlaybackSpeed.current
        self.baud = baud
        player = ArtPlayerViewController(playback: playback, name: item.name, baud: baud)
        player.onStateChange = { [weak self] state in self?.state = state }
    }

    var title: String {
        let sauceTitle = file.sauce?.title.trimmingCharacters(in: .whitespaces) ?? ""
        return sauceTitle.isEmpty ? item.title : sauceTitle
    }
}

/// A file to hand the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The art on black with a toolbar: play or skip, speed, SAUCE info and share.
struct ViewerScreen: View {
    let item: ArtItem
    @State private var model: ViewerModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                LoadedViewer(model: model)
            } else if let loadError {
                ContentUnavailableView(String(localized: "Cannot Open \(item.name)"),
                                       systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .task(id: item) {
            // Reading and playing the file through once (to find its final screen) happens off the
            // main thread; only the view controller is made on it.
            let item = item
            let loaded = await Task.detached(priority: .userInitiated) {
                Result { ArtPlayback(try ArtLoader.load(item)) }
            }.value
            switch loaded {
            case .success(let playback): model = ViewerModel(item: item, playback: playback)
            case .failure(let error): loadError = error.localizedDescription
            }
        }
    }
}

private struct LoadedViewer: View {
    @ObservedObject var model: ViewerModel
    @State private var showsInfo = false
    @State private var shared: SharedFile?
    /// A GIF is being made (shows the progress overlay).
    @State private var exporting = false
    /// Any export is running.
    @State private var busy = false
    @State private var exportError: String?

    var body: some View {
        PlayerView(player: model.player)
            .ignoresSafeArea(edges: .bottom)
            .background(Color.black)
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            // The art is always on black, so the bar's title is drawn light in either appearance.
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear(perform: debugActions)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    playButton
                    speedMenu
                    Button { showsInfo = true } label: {
                        Label(String(localized: "Info"), systemImage: "info.circle")
                    }
                    shareMenu
                }
            }
            .sheet(isPresented: $showsInfo) {
                ArtInfoSheet(item: model.item, file: model.file)
            }
            .sheet(item: $shared) { file in
                ActivityView(items: [file.url]).ignoresSafeArea()
            }
            .alert(String(localized: "Export Failed"), isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
            .overlay {
                if exporting {
                    ProgressView(String(localized: "Making GIF..."))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
    }

    @ViewBuilder private var playButton: some View {
        if model.state == .finished {
            Button { model.player.replay() } label: {
                Label(String(localized: "Play"), systemImage: "play.fill")
            }
            .disabled(!model.player.canPlay)
            .accessibilityHint(String(localized: "Draws the art again at the chosen modem speed"))
        } else {
            Button { model.player.skipToEnd() } label: {
                Label(String(localized: "Skip to End"), systemImage: "forward.end.fill")
            }
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker(String(localized: "Speed"), selection: $model.baud) {
                ForEach(MobilePlaybackSpeed.choices, id: \.self) { baud in
                    Text(MobilePlaybackSpeed.label(baud)).tag(baud)
                }
            }
        } label: {
            Label(String(localized: "Speed: \(MobilePlaybackSpeed.label(model.baud))"), systemImage: "speedometer")
        }
    }

    private var shareMenu: some View {
        Menu {
            Button { share(gif: false) } label: { Label(String(localized: "Share as PNG"), systemImage: "photo") }
            Button { share(gif: true) } label: {
                Label(String(localized: "Share as GIF"), systemImage: "photo.stack")
            }
            .disabled(!model.player.canPlay && !model.player.playback.finalScreen.hasBlink)
        } label: {
            Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
        }
        // One export at a time.
        .disabled(busy)
    }

    /// Debug builds: `-info YES` opens the info sheet and `-share png|gif` the share sheet, so the
    /// simulator can show them without taps.
    private func debugActions() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "info") { showsInfo = true }
        switch UserDefaults.standard.string(forKey: "share") {
        case "png": share(gif: false)
        case "gif": share(gif: true)
        default: break
        }
        #endif
    }

    /// Writes the export to a temporary folder and opens the share sheet with it.
    private func share(gif: Bool) {
        let file = model.file
        let baud = model.baud == 0 ? MobilePlaybackSpeed.defaultBaud : model.baud
        let name = ArtShareExport.fileName(for: model.item.name, extension: gif ? "gif" : "png")
        guard !busy else { return }
        busy = true
        exporting = gif
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                gif ? ArtShareExport.gif(file, baud: baud) : ArtShareExport.png(file)
            }.value
            exporting = false
            busy = false
            guard let data else {
                exportError = String(localized: "The art could not be rendered.")
                return
            }
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                shared = SharedFile(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

/// Hosts the UIKit player in SwiftUI.
struct PlayerView: UIViewControllerRepresentable {
    let player: ArtPlayerViewController
    func makeUIViewController(context: Context) -> ArtPlayerViewController { player }
    func updateUIViewController(_ controller: ArtPlayerViewController, context: Context) {}
}

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
