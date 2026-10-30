import AppKit
import os
import UniformTypeIdentifiers

/// The Finder Quick Action extension (Convert to PNG, Convert to GIF). It has no window; the
/// format comes from the extension's Info.plist (`AnsiViewQuickActionFormat`).
final class QuickActionHandler: NSObject, NSExtensionRequestHandling {
    private let log = Logger(subsystem: "com.traynham.ansiview", category: "quick-action")

    func beginRequest(with context: NSExtensionContext) {
        let name = Bundle.main.object(forInfoDictionaryKey: "AnsiViewQuickActionFormat") as? String ?? "png"
        let format = ArtActions.ImageFormat(rawValue: name) ?? .png
        let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // The file URLs arrive on separate queues; they are gathered first and converted one at a
        // time, so two pieces with the same name never write the same output.
        let lock = NSLock()
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { [log] url, error in
                defer { group.leave() }
                guard let url else {
                    log.error("No file: \(String(describing: error), privacy: .public)")
                    return
                }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { [log] in
            let inputs = urls.sorted { $0.path < $1.path }
            let scoped = inputs.map { $0.startAccessingSecurityScopedResource() }
            defer { for (url, started) in zip(inputs, scoped) where started { url.stopAccessingSecurityScopedResource() } }
            for (input, result) in zip(inputs, QuickActionConversion.convertAll(inputs, format: format, fallbackFolder: downloads)) {
                switch result {
                case .success(let written): log.info("Wrote \(written.path, privacy: .public)")
                case .failure(let error):
                    log.error("\(input.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            DispatchQueue.main.async { context.completeRequest(returningItems: nil, completionHandler: nil) }
        }
    }
}
