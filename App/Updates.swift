import AnsiCore
import AppKit
import os
#if SPARKLE_UPDATES
import Sparkle
#endif

/// Sparkle updates for the direct download build. Built only with the `SPARKLE_UPDATES` Swift
/// condition (set in project.yml; the Mac App Store spec in Packaging/appstore leaves it and the
/// Sparkle package out). The updater starts only when Info.plist has a real `SUPublicEDKey`.
@MainActor
enum Updates {
    /// Why updates are off in this build, or nil when Sparkle is running.
    private(set) static var problem: String? = "not started"

    #if SPARKLE_UPDATES
    private static var controller: SPUStandardUpdaterController?
    #endif

    /// True when this build includes Sparkle (it shows AnsiView > Check for Updates...).
    static var isIncluded: Bool {
        #if SPARKLE_UPDATES
        return true
        #else
        return false
        #endif
    }

    /// Starts Sparkle at launch when the build is set up for it; otherwise logs why not.
    static func start(bundle: Bundle = .main) {
        #if SPARKLE_UPDATES
        guard controller == nil else { return }
        problem = UpdateSettings.problem(publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                                         feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        let log = Logger(subsystem: "com.traynham.ansiview", category: "updates")
        if let problem {
            log.notice("Updates disabled: \(problem, privacy: .public)")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        log.notice("Updates enabled, feed \(bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "", privacy: .public)")
        #else
        problem = "this build has no updater"
        #endif
    }

    /// AnsiView > Check for Updates...
    static func checkForUpdates() {
        #if SPARKLE_UPDATES
        if let controller {
            controller.checkForUpdates(nil)
            return
        }
        #endif
        Logger(subsystem: "com.traynham.ansiview", category: "updates")
            .notice("Check for Updates: not set up (\(problem ?? "unknown", privacy: .public))")
        let alert = NSAlert()
        alert.messageText = "Updates are not set up in this build"
        alert.informativeText = "This copy of AnsiView cannot check for updates (\(problem ?? "unknown reason")). "
            + "Download the latest version from github.com/btray77/AnsiView/releases."
        alert.addButton(withTitle: "Open Releases Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://github.com/btray77/AnsiView/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}
