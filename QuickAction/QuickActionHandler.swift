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
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { [log] url, error in
                defer { group.leave() }
                guard let url else {
                    log.error("No file: \(String(describing: error), privacy: .public)")
                    return
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let written = try QuickActionConversion.convert(url, format: format, fallbackFolder: downloads)
                    log.info("Wrote \(written.path, privacy: .public)")
                } catch {
                    log.error("\(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        group.notify(queue: .main) {
            context.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
