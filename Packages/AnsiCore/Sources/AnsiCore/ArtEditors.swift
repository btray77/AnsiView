import Foundation

/// ANSI art editors AnsiView can hand the current file to (File > Open in Moebius / PabloDraw).
public struct ArtEditor: Equatable {
    public let name: String
    /// How macOS knows the app; looked up with Launch Services at click time.
    public let bundleIdentifier: String
    /// Where to get it when it is not installed.
    public let downloadPage: URL

    public var menuTitle: String { "Open in \(name)" }

    /// The alert shown when the editor is not installed.
    public var notInstalledMessage: (title: String, detail: String) {
        ("\(name) is not installed",
         "AnsiView opens the current file in \(name) when it is installed. \(name) is free; download it, "
            + "move it to Applications, then try again.")
    }

    /// Moebius: `appId` in the Moebius repository's electron-builder.yml.
    public static let moebius = ArtEditor(
        name: "Moebius", bundleIdentifier: "org.andyherbert.moebius",
        downloadPage: URL(string: "https://github.com/blocktronics/moebius/releases")!)
    /// PabloDraw: `CFBundleIdentifier` in the PabloDraw repository's Source/PabloDraw/Info.plist.
    public static let pabloDraw = ArtEditor(
        name: "PabloDraw", bundleIdentifier: "ca.picoe.pablodraw",
        downloadPage: URL(string: "https://github.com/cwensley/pablodraw/releases")!)

    public static let all = [moebius, pabloDraw]
}
