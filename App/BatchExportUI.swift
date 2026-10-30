import AnsiCore
import AppKit

/// File > Batch Export: exports a gallery's selection (or all of it), or a folder or art pack
/// chosen in an open panel, into a chosen folder.
@MainActor
enum BatchExportController {
    /// The settings chosen last time, kept for the session.
    private static var lastKind: ExportKind = .still(.png)

    static func start() {
        if let gallery = NSApp.keyWindow?.windowController as? GalleryWindowController {
            let selected = gallery.gallery.selectedIndexes
            chooseOutput(collection: gallery.gallery.collection, indexes: selected.isEmpty ? nil : selected,
                         window: gallery.window)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip]
        panel.prompt = "Choose"
        panel.message = "Choose a folder of art or a ZIP art pack to export."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let collection = try ArtCollection.open(url, scoped: true)
            // The gallery shows what is being exported and hosts the progress sheet.
            let gallery = GalleryWindowController.open(collection: collection)
            chooseOutput(collection: collection, indexes: nil, window: gallery.window)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Asks for the output folder, with the export options as the accessory view.
    static func chooseOutput(collection: ArtCollection, indexes: [Int]?, window: NSWindow?) {
        let items = collection.batchItems(indexes)
        guard !items.isEmpty else { NSSound.beep(); return }
        let options = ExportOptionsView(kinds: ExportKind.all, selected: lastKind, scale: 2)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = items.count == 1 ? "Choose the folder for 1 exported file."
            : "Choose the folder for \(items.count) exported files."
        panel.accessoryView = ExportOptionsView.accessory(options.rows())
        panel.isAccessoryViewDisclosed = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            withExtendedLifetime(options) {}
            guard response == .OK, let folder = panel.url else { return }
            let settings = options.settings
            lastKind = settings.kind
            DispatchQueue.main.async {
                guard let host = window ?? NSApp.keyWindow else { return }
                run(items, collection: collection, settings: settings, to: folder, in: host) { _ in }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Runs the batch behind a progress sheet ("n of N: name", Cancel), then shows the summary.
    /// `completion` gets the results (for checks).
    static func run(_ items: [BatchItem], collection: ArtCollection?, settings: ExportSettings, to folder: URL,
                    in window: NSWindow, showSummary: Bool = true, completion: @escaping ([BatchResult]) -> Void) {
        let sheet = ExportController.ProgressSheet(title: "Exporting \(items.count) files")
        let flag = sheet.flag
        window.beginSheet(sheet.panel)
        let scoped = folder.startAccessingSecurityScopedResource()
        let total = items.count
        DispatchQueue.global(qos: .userInitiated).async {
            let results = BatchExporter.run(items, settings: settings, to: folder, overwrite: false, progress: { index, name, fraction in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard !flag.isCancelled else { return }
                        sheet.label.stringValue = "\(index + 1) of \(total): \(name)"
                        sheet.bar.doubleValue = (Double(index) + fraction) / Double(total)
                    }
                }
            }, isCancelled: { flag.isCancelled })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    withExtendedLifetime(collection) {}
                    if scoped { folder.stopAccessingSecurityScopedResource() }
                    window.endSheet(sheet.panel)
                    if showSummary { summarize(results, total: total, folder: folder, in: window) }
                    completion(results)
                }
            }
        }
    }

    static func summaryAlert(_ results: [BatchResult], total: Int) -> NSAlert {
        let summary = BatchExporter.summary(results, total: total)
        let alert = NSAlert()
        alert.messageText = summary.title
        alert.informativeText = summary.detail
        alert.alertStyle = results.contains { $0.error != nil } ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        return alert
    }

    private static func summarize(_ results: [BatchResult], total: Int, folder: URL, in window: NSWindow) {
        summaryAlert(results, total: total).beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                let written = results.compactMap(\.output)
                NSWorkspace.shared.activateFileViewerSelecting(written.isEmpty ? [folder] : written)
            }
        }
    }
}
