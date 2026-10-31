import AppKit

/// File > Install Screen Saver: opens the saver kept in the app's Resources, so macOS asks the
/// user to install it (plan 10 ruling 13).
enum ScreenSaverInstall {
    static var bundledSaver: URL? { Bundle.main.url(forResource: "AnsiView", withExtension: "saver") }

    static func run() {
        guard let saver = bundledSaver else { NSSound.beep(); return }
        NSWorkspace.shared.open(saver)
    }
}
