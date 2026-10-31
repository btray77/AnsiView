import AnsiCore
import AppKit

/// The folder RIPscrip icons (.ICN, .HIC) and scenes (.RIP) are read from, chosen by the user
/// (Terminal > RIP Icon Folder) and kept as a security scoped bookmark. A BBS never writes there:
/// icons it saves with 1W live only for the session (RIPTerminal).
enum RIPIconFolder {
    private static let key = "RIPIconFolderBookmark"
    private static var accessed: URL?

    /// The chosen folder, opened for reading; nil when none was chosen or it is gone.
    static func provider() -> RIPFileProvider? {
        if let accessed { return RIPFolderProvider(folder: accessed) }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        accessed = url
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return RIPFolderProvider(folder: url)
    }

    static var folderName: String? { accessed?.lastPathComponent }

    /// Asks for the folder; returns true when one was chosen.
    @discardableResult
    static func choose() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder that holds your RIPscrip icons (.ICN) and scenes (.RIP)."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: .withSecurityScope) else { return false }
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        UserDefaults.standard.set(data, forKey: key)
        ArtFile.ripFiles = provider()
        return true
    }
}
