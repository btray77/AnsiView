import AnsiCore
import AppKit
import ScreenSaver

/// The saver's options, kept in its own ScreenSaverDefaults (plan 10 ruling 13).
struct SaverSettings {
    static let bauds = [2400, 9600, 19200, 38400, 0]
    static let holds: [Double] = [4, 8, 15, 30]

    let defaults: UserDefaults

    init(bundle: Bundle) {
        defaults = ScreenSaverDefaults(forModuleWithName: bundle.bundleIdentifier ?? "com.traynham.AnsiView.Saver")
            ?? UserDefaults.standard
    }

    /// A folder of art chosen in the options sheet; nil plays the samples inside the saver.
    var folder: URL? {
        get { defaults.string(forKey: "folder").map { URL(fileURLWithPath: $0) } }
        nonmutating set { defaults.set(newValue?.path, forKey: "folder"); defaults.synchronize() }
    }

    var baud: Int {
        get { defaults.object(forKey: "baud") as? Int ?? 9600 }
        nonmutating set { defaults.set(newValue, forKey: "baud"); defaults.synchronize() }
    }

    var holdSeconds: Double {
        get { defaults.object(forKey: "hold") as? Double ?? 8 }
        nonmutating set { defaults.set(newValue, forKey: "hold"); defaults.synchronize() }
    }
}

/// Plays a folder of ANSI art, animation included, with AnsiCore's terminal and renderer.
@objc(AnsiSaverView)
final class AnsiSaverView: ScreenSaverView {
    private var bundle: Bundle { Bundle(for: AnsiSaverView.self) }
    private lazy var settings = SaverSettings(bundle: bundle)
    private var playlist: [URL] = []
    private var next = 0
    private var playback: SaverPlayback?
    private var picture: CGImage?
    /// Where the pieces come from, for the options sheet ("samples" when the folder could not be read).
    private(set) var source = ""
    private var sheet: SaverOptionsSheet?
    /// Fixed for tests and the harness; the time otherwise.
    var seed = UInt64(Date().timeIntervalSince1970)

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 15
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 15
    }

    /// The pieces to play: the chosen folder's art when it can be read, else the samples.
    func loadPlaylist() {
        let samples = bundle.resourceURL?.appendingPathComponent("Samples")
        func art(in folder: URL) -> [URL] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return SaverPlaylist.artFiles(names).map { folder.appendingPathComponent($0) }
        }
        var files: [URL] = []
        if let folder = settings.folder {
            files = art(in: folder)
            source = files.isEmpty ? "Samples (\(folder.lastPathComponent) could not be read or has no art)" : folder.path
        }
        if files.isEmpty, let samples {
            files = art(in: samples)
            if source.isEmpty { source = "Samples" }
        }
        playlist = SaverPlaylist.shuffled(files, seed: seed)
        next = 0
        playback = nil
    }

    override func startAnimation() {
        loadPlaylist()
        super.startAnimation()
    }

    override func animateOneFrame() {
        step(seconds: animationTimeInterval)
        setNeedsDisplay(bounds)
    }

    /// Moves playback on by `seconds`, starting the next piece when one finishes.
    func step(seconds: Double) {
        if playlist.isEmpty { loadPlaylist() }
        guard !playlist.isEmpty else { return }
        var attempts = 0
        while playback == nil || playback?.phase == .finished {
            guard attempts < playlist.count else { return }
            attempts += 1
            let url = playlist[next % playlist.count]
            next += 1
            if next >= playlist.count {
                next = 0
                seed &+= 1
                playlist = SaverPlaylist.shuffled(playlist, seed: seed)
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            playback = SaverPlayback(file: ArtFile(data: data, fileExtension: url.pathExtension),
                                     baud: settings.baud, holdSeconds: settings.holdSeconds)
        }
        guard var current = playback else { return }
        current.advance(seconds: seconds)
        playback = current
        let screen = current.screen
        picture = AnsiRenderer.render(screen, options: RenderOptions(for: screen, scale: 1))?.image
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let picture, let context = NSGraphicsContext.current?.cgContext else { return }
        // Whole number scaling when it fits (crisp pixels), otherwise scaled to fit.
        let size = CGSize(width: picture.width, height: picture.height)
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let scale = fit >= 1 ? fit.rounded(.down) : fit
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (bounds.width - drawn.width) / 2, y: (bounds.height - drawn.height) / 2)
        context.interpolationQuality = scale >= 1 ? .none : .high
        context.draw(picture, in: CGRect(origin: origin, size: drawn))
    }

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let sheet = SaverOptionsSheet(settings: settings) { [weak self] in
            self?.loadPlaylist()
        }
        self.sheet = sheet
        return sheet.window
    }
}

/// Folder, speed and hold time.
final class SaverOptionsSheet: NSObject {
    let window: NSWindow
    private let settings: SaverSettings
    private let done: () -> Void
    private let folderLabel = NSTextField(wrappingLabelWithString: "")
    private let speed = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hold = NSPopUpButton(frame: .zero, pullsDown: false)

    init(settings: SaverSettings, done: @escaping () -> Void) {
        self.settings = settings
        self.done = done
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        speed.addItems(withTitles: SaverSettings.bauds.map { $0 == 0 ? "Instant" : "\($0) baud" })
        speed.selectItem(at: SaverSettings.bauds.firstIndex(of: settings.baud) ?? 1)
        hold.addItems(withTitles: SaverSettings.holds.map { "\(Int($0)) seconds" })
        hold.selectItem(at: SaverSettings.holds.firstIndex(of: settings.holdSeconds) ?? 1)
        updateFolderLabel()
        let choose = NSButton(title: "Choose Folder...", target: self, action: #selector(chooseFolder))
        let samples = NSButton(title: "Use Samples", target: self, action: #selector(useSamples))
        let note = NSTextField(wrappingLabelWithString: "macOS runs screen savers in a sandbox, so a folder outside it may not be readable; the samples inside the screen saver play instead.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let ok = NSButton(title: "OK", target: self, action: #selector(close))
        ok.keyEquivalent = "\r"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Art:"), folderLabel],
            [NSView(), NSStackView(views: [choose, samples])],
            [NSTextField(labelWithString: "Speed:"), speed],
            [NSTextField(labelWithString: "Hold each piece:"), hold],
            [NSView(), note],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        folderLabel.preferredMaxLayoutWidth = 300
        note.preferredMaxLayoutWidth = 300
        let stack = NSStackView(views: [grid, ok])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack
    }

    private func updateFolderLabel() {
        folderLabel.stringValue = settings.folder?.path ?? "The samples inside the screen saver"
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Play This Folder"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.settings.folder = url
            self.updateFolderLabel()
        }
    }

    @objc private func useSamples() {
        settings.folder = nil
        updateFolderLabel()
    }

    @objc private func close() {
        settings.baud = SaverSettings.bauds[max(0, speed.indexOfSelectedItem)]
        settings.holdSeconds = SaverSettings.holds[max(0, hold.indexOfSelectedItem)]
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        done()
    }
}
