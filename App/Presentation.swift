import AnsiCore
import AppKit

/// The borderless black window that presentation mode fills the screen with. Escape leaves.
final class PresentationWindow: NSWindow {
    weak var controller: PresentationController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller?.exit() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { controller?.exit() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            controller?.exit()
            return
        }
        if event.type == .mouseMoved { controller?.mouseMoved() }
        super.sendEvent(event)
    }
}

/// View > Presentation Mode: the art alone on a black screen, menu bar, Dock and cursor hidden.
/// A new player takes over the playback position and hands it back on exit.
final class PresentationController: NSObject {
    private(set) static var current: PresentationController?
    static let cursorHideDelay: TimeInterval = 2

    let window: PresentationWindow
    /// The presented player, for a single file; for a slideshow, its current player.
    var player: AnsiPlayerViewController? { slideshow?.player ?? single }
    private(set) var slideshow: SlideshowViewController?
    private var single: AnsiPlayerViewController?
    private weak var originPlayer: AnsiPlayerViewController?
    private weak var originSlideshow: SlideshowViewController?
    private weak var originWindow: NSWindow?
    private let savedOptions: NSApplication.PresentationOptions
    private var cursorTimer: Timer?

    /// Presents one file, continuing `player`'s playback.
    static func present(player: AnsiPlayerViewController) {
        guard current == nil else { return }
        let presented = AnsiPlayerViewController(source: player.source, speed: player.speed, showsTimeline: false)
        presented.fileURL = player.fileURL
        presented.artName = player.artName
        presented.sound = player.sound == nil ? nil : ModemSoundPlayer()
        presented.music = player.music == nil ? nil : AudioMusicOutput()
        presented.musicMuted = player.musicMuted
        ViewerCopy.enable(presented)
        presented.paletteOverride = player.paletteOverride
        let controller = PresentationController(screen: player.view.window?.screen, origin: player.view.window)
        controller.single = presented
        controller.originPlayer = player
        controller.install(presented)
        presented.takeOver(from: player)
        controller.start()
    }

    /// Presents a slideshow from its current piece; the arrows keep moving between pieces.
    static func present(slideshow origin: SlideshowViewController) {
        guard current == nil else { return }
        let presented = SlideshowViewController(collection: origin.collection, index: origin.index, presenting: true)
        presented.makeSound = origin.makeSound
        presented.zoom = .fit
        let controller = PresentationController(screen: origin.view.window?.screen, origin: origin.view.window)
        controller.slideshow = presented
        controller.originSlideshow = origin
        controller.install(presented)
        presented.resume(from: origin.player)
        origin.suspend()
        controller.start()
    }

    /// Presents a collection from a piece (the gallery).
    static func present(collection: ArtCollection, index: Int, from window: NSWindow?) {
        guard current == nil else { return }
        let presented = SlideshowViewController(collection: collection, index: index, presenting: true)
        presented.makeSound = { ModemSoundPlayer() }
        let controller = PresentationController(screen: window?.screen, origin: window)
        controller.slideshow = presented
        controller.install(presented)
        controller.start()
    }

    private init(screen: NSScreen?, origin: NSWindow?) {
        let frame = (screen ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = PresentationWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        window.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        savedOptions = NSApp.presentationOptions
        originWindow = origin
        super.init()
        window.controller = self
    }

    private func install(_ content: NSViewController) {
        content.view.frame = window.contentView!.bounds
        content.view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(content.view)
    }

    private func start() {
        Self.current = self
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        if let canvas = player?.canvasView { window.makeFirstResponder(canvas) }
        hideCursorSoon(after: 0)
    }

    /// Leaves presentation mode and hands playback back to the window it came from.
    func exit() {
        guard Self.current === self else { return }
        Self.current = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        NSCursor.setHiddenUntilMouseMoves(false)
        if let presented = single, let origin = originPlayer {
            origin.takeOver(from: presented)
        } else if let presented = slideshow, let origin = originSlideshow {
            origin.show(presented.index)
            origin.resume(from: presented.player)
            presented.suspend()
        }
        player?.halt()
        slideshow?.suspend()
        window.orderOut(nil)
        NSApp.presentationOptions = savedOptions
        originWindow?.makeKeyAndOrderFront(nil)
        // Let go of the views only after the window is gone.
        DispatchQueue.main.async { [self] in
            single = nil
            slideshow = nil
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.close()
        }
    }

    fileprivate func mouseMoved() {
        hideCursorSoon(after: Self.cursorHideDelay)
    }

    private func hideCursorSoon(after delay: TimeInterval) {
        cursorTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }
}

extension AnsiPlayerViewController {
    /// View > Presentation Mode: presents this file (or its slideshow), or leaves presentation.
    @objc func presentArt(_ sender: Any?) {
        if let current = PresentationController.current {
            current.exit()
        } else if let slideshow = parent as? SlideshowViewController {
            PresentationController.present(slideshow: slideshow)
        } else {
            PresentationController.present(player: self)
        }
    }
}

extension GalleryViewController {
    /// View > Presentation Mode from a gallery: a slideshow of the pack from the selected piece.
    @objc func presentArt(_ sender: Any?) {
        guard !collection.items.isEmpty else { NSSound.beep(); return }
        PresentationController.present(collection: collection, index: selectedIndex ?? 0, from: view.window)
    }
}
