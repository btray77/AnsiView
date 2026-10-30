import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// File > Import Image... (and images opened, dropped or dragged to the Dock): the import
/// window with its live preview.
final class ImageImportWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<ImageImportWindowController> = []
    let importController: ImageImportViewController

    /// Asks for an image, then opens the import window for it.
    static func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to convert to ANSI art."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    static func open(url: URL) {
        do {
            open(data: try Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func open(data: Data, name: String) {
        do {
            let controller = ImageImportWindowController(image: try ImageToAnsi.load(data), name: name)
            open.insert(controller)
            controller.showWindow(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private init(image: CGImage, name: String) {
        importController = ImageImportViewController(image: image, name: name)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Import \(name)"
        window.minSize = NSSize(width: 860, height: 560)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentViewController = importController
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        importController.onOpenInEditor = { canvas, name, format in
            EditorWindowController.open(canvas: canvas, name: name, suggestedFormat: format)
        }
        importController.onClose = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }
}

/// File > Convert Images to ANSI...: many pictures (or folders of them) to .ans files with the
/// remembered import settings, written to a folder the user picks.
enum ImageBatchConverter {
    static func start() {
        let input = NSOpenPanel()
        input.allowedContentTypes = [.image, .folder]
        input.canChooseDirectories = true
        input.allowsMultipleSelection = true
        input.message = "Choose images or folders of images to convert to ANSI art."
        input.prompt = "Choose"
        guard input.runModal() == .OK, !input.urls.isEmpty else { return }
        let output = NSOpenPanel()
        output.canChooseFiles = false
        output.canChooseDirectories = true
        output.canCreateDirectories = true
        output.message = "Choose the folder for the converted files. Existing files are not replaced."
        output.prompt = "Convert Here"
        guard output.runModal() == .OK, let folder = output.url else { return }
        run(inputs: input.urls, folder: folder)
    }

    private static func run(inputs: [URL], folder: URL) {
        let expanded = ImageBatch.expand(inputs)
        let preset = ImageImportSettings.preset
        let base = ImageImportSettings.options
        let progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(max(1, expanded.images.count))
        let label = NSTextField(labelWithString: "Converting \(expanded.images.count) images...")
        let stack = NSStackView(views: [label, progress])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Convert Images to ANSI"
        window.contentView = stack
        progress.widthAnchor.constraint(equalToConstant: 380).isActive = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            var naming = BatchNaming(existing: Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []))
            var written = 0
            var problems = expanded.skipped.map { "\($0.lastPathComponent): not an image" }
            for (index, source) in expanded.images.enumerated() {
                DispatchQueue.main.async {
                    label.stringValue = "Converting \(source.lastPathComponent) (\(index + 1) of \(expanded.images.count))"
                    progress.doubleValue = Double(index)
                }
                do {
                    let image = try ImageToAnsi.load(try Data(contentsOf: source))
                    var options = preset.options(base: base, imageWidth: image.width, imageHeight: image.height)
                    var canvas: EditCanvas
                    if preset == .auto, let best = ImageToAnsi.autoCandidates(image, base: options, cancel: { false })?.first {
                        options = best.options
                        canvas = best.canvas
                    } else {
                        canvas = ImageToAnsi.convert(image, options: options)
                    }
                    canvas.title = String(source.deletingPathExtension().lastPathComponent.prefix(35))
                    let format = options.palette.saveFormat
                    let url = folder.appendingPathComponent(naming.name(for: source.lastPathComponent, fileExtension: format.fileExtension))
                    try ArtWriter.data(canvas, format: format).write(to: url)
                    written += 1
                } catch {
                    problems.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                window.close()
                let alert = NSAlert()
                alert.messageText = "Converted \(written) of \(expanded.images.count) images"
                alert.informativeText = problems.isEmpty ? "The files are in \(folder.lastPathComponent)."
                    : problems.prefix(20).joined(separator: "\n") + (problems.count > 20 ? "\n..." : "")
                alert.addButton(withTitle: "Show in Finder")
                alert.addButton(withTitle: "OK")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
        }
    }
}

/// Dropping an image file on an editor opens the import window (image import ruling 11).
extension EditorCanvasView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageImportRootView.imageURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = ImageImportRootView.imageURL(from: sender) else { return false }
        ImageImportWindowController.open(url: url)
        return true
    }
}
