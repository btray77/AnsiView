import AnsiCore
import QuartzCore
import UIKit

/// Playback speeds for iPhone and iPad, in bits per second; 0 draws instantly. The same choices
/// and default (2400 baud) as the Mac's `PlaybackSpeed`, kept in the app's own defaults.
enum MobilePlaybackSpeed {
    static let defaultsKey = "playbackBaud"
    static let defaultBaud = 2400
    static let choices = [300, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 57600, 115200, 0]

    static var current: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int
            return stored.flatMap { choices.contains($0) ? $0 : nil } ?? defaultBaud
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func label(_ baud: Int) -> String {
        baud == 0 ? String(localized: "Instant") : String(localized: "\(baud) baud")
    }
}

/// Shows one art file: pinch to zoom, drag to scroll, double tap to switch between fitting and 2x,
/// single tap to skip an animation to its end (or replay it once finished). Animated art replays
/// at modem speed when it first appears; blinking text blinks. Used by the app and by its Quick
/// Look preview extension.
final class ArtPlayerViewController: UIViewController, UIScrollViewDelegate {
    static let blinkInterval: TimeInterval = 0.46

    let file: ArtFile
    let name: String?
    /// Bits per second for playback; 0 is instant.
    var baud: Int
    /// Told whenever playback starts, pauses or finishes.
    var onStateChange: ((ArtPlayback.State) -> Void)?
    /// Replays animated art when the view first appears.
    var autoplays = true

    private(set) var playback: ArtPlayback
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var displayLink: CADisplayLink?
    private var blinkTimer: Timer?
    private var blinkVisible = true
    private var didAutoplay = false
    /// The art's size in points (one point per font pixel, with the CRT aspect stretch).
    private var artSize = CGSize.zero
    private var lastFitBounds = CGSize.zero

    init(file: ArtFile, name: String?, baud: Int = MobilePlaybackSpeed.current) {
        self.file = file
        self.name = name
        self.baud = baud
        self.playback = ArtPlayback(file)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var state: ArtPlayback.State { playback.state }
    /// True when there are bytes to play (binary screen formats have none).
    var canPlay: Bool { playback.length > 0 }

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .black
        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        imageView.layer.magnificationFilter = .nearest
        imageView.layer.minificationFilter = .trilinear
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = [.image]
        imageView.accessibilityLabel = ArtText.accessibilityLabel(file, fileName: name)
        imageView.accessibilityValue = ArtText.accessibilityValue(playback.analysis.finalScreen)
        imageView.accessibilityHint = String(localized: "Pinch to zoom. Double tap to switch between fit and 2x.")
        scrollView.addSubview(imageView)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        view = container
        redraw()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scrollView.bounds.size != lastFitBounds {
            lastFitBounds = scrollView.bounds.size
            updateZoomLimits(resetToFit: true)
        }
        centerArt()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if autoplays, !didAutoplay, playback.isAnimated {
            didAutoplay = true
            replay()
        } else if playback.state == .paused {
            resume()
        }
        updateBlinkTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pause()
        stopBlink()
    }

    // MARK: Playback

    /// Plays the file from its first byte at `baud`.
    func replay() {
        playback.play(baud: baud, at: CACurrentMediaTime())
        redraw()
        if playback.state == .playing { startDisplayLink() }
        onStateChange?(playback.state)
    }

    func skipToEnd() {
        stopDisplayLink()
        playback.skipToEnd()
        redraw()
        onStateChange?(playback.state)
    }

    func pause() {
        guard playback.state == .playing else { return }
        stopDisplayLink()
        playback.pause()
        onStateChange?(playback.state)
    }

    func resume() {
        guard playback.state == .paused else { return }
        playback.resume(at: CACurrentMediaTime())
        startDisplayLink()
        onStateChange?(playback.state)
    }

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard playback.tick(at: CACurrentMediaTime(), baud: baud) else { return }
        redraw()
        if playback.state != .playing {
            stopDisplayLink()
            onStateChange?(playback.state)
        }
    }

    @objc private func singleTapped() {
        switch playback.state {
        case .playing, .paused: skipToEnd()
        case .finished: if playback.isAnimated { replay() }
        }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        let fit = scrollView.minimumZoomScale
        if scrollView.zoomScale > fit * 1.01 {
            scrollView.setZoomScale(fit, animated: true)
        } else {
            let target = min(scrollView.maximumZoomScale, max(fit * 2, 2))
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / target, height: scrollView.bounds.height / target)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }

    // MARK: Drawing

    private func redraw() {
        guard let rendered = playback.image(blinkVisible: blinkVisible) else { return }
        imageView.image = UIImage(cgImage: rendered.image)
        let aspect = AnsiRenderer.pixelAspect(for: playback.finalScreen, ninePixel: file.ninePixel)
        let size = CGSize(width: rendered.pointSize.width, height: (rendered.pointSize.height * aspect).rounded())
        if size != artSize {
            // The 25 row playback window of tall art starts or ends: fit the new size.
            artSize = size
            updateZoomLimits(resetToFit: true)
        }
        updateBlinkTimer()
    }

    /// Fit is the smallest zoom: the whole screen for art of 25 rows or less, the full width
    /// (scrolling down) for taller art. Up to 8 points per font pixel.
    private func updateZoomLimits(resetToFit: Bool) {
        let bounds = scrollView.bounds.size
        guard artSize.width > 0, artSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let widthScale = bounds.width / artSize.width
        let scrolls = artSize.height * widthScale > bounds.height
            && playback.displayedScreen.rows.count > TerminalViewport.rows
        let fit = scrolls ? widthScale : min(widthScale, bounds.height / artSize.height)
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: artSize)
        scrollView.contentSize = artSize
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = max(fit, 8)
        if resetToFit { scrollView.zoomScale = fit }
        centerArt()
        if resetToFit {
            // The top left of the art, inside the centring insets.
            let inset = scrollView.contentInset
            scrollView.contentOffset = CGPoint(x: -inset.left, y: -inset.top)
        }
    }

    private func centerArt() {
        let bounds = scrollView.bounds.size
        let content = imageView.frame.size
        let x = max(0, (bounds.width - content.width) / 2)
        let y = max(0, (bounds.height - content.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerArt() }

    // MARK: Blink

    private func updateBlinkTimer() {
        let needsBlink = playback.displayedScreen.hasBlink && viewIfLoaded?.window != nil
        if needsBlink, blinkTimer == nil {
            let timer = Timer(timeInterval: Self.blinkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blinkVisible.toggle()
                    self.redraw()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else if !needsBlink, blinkTimer != nil {
            stopBlink()
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        if !blinkVisible {
            blinkVisible = true
        }
    }
}
