import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// The import settings remembered between imports (the crop belongs to one picture, so it is not kept).
enum ImageImportSettings {
    private static let optionsKey = "imageImportOptions2"
    private static let presetKey = "imageImportPreset"

    static var options: ImageToAnsi.Options {
        get {
            guard let data = UserDefaults.standard.data(forKey: optionsKey),
                  var options = try? JSONDecoder().decode(ImageToAnsi.Options.self, from: data) else { return ImageToAnsi.Options() }
            options.crop = nil
            return options
        }
        set {
            var copy = newValue
            copy.crop = nil
            UserDefaults.standard.set(try? JSONEncoder().encode(copy), forKey: optionsKey)
        }
    }

    static var preset: ImagePreset {
        get { UserDefaults.standard.string(forKey: presetKey).flatMap(ImagePreset.init) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: presetKey) }
    }
}

/// What one preview render produced.
struct ImagePreview {
    struct Candidate {
        let name: String
        let options: ImageToAnsi.Options
        let canvas: EditCanvas
        let image: CGImage
        let score: ImageScore.Result
        let bytes: Int
    }

    let candidates: [Candidate]
    /// Milliseconds the conversion work took (not counting the debounce wait).
    let workMilliseconds: Double
}

/// Shows the original and the result in one coordinate system, so zoom and pan always match.
final class ImageComparisonView: NSView {
    enum Mode: Int { case split, sideBySide, original, result }

    var original: CGImage? { didSet { needsDisplay = true } }
    /// The whole picture, shown while choosing a crop.
    var fullOriginal: CGImage? { didSet { needsDisplay = true } }
    var result: CGImage? { didSet { needsDisplay = true } }
    var mode = Mode.split { didSet { needsDisplay = true } }
    var smoothOriginal = true { didSet { needsDisplay = true } }
    /// 0 to 1 across the frame: original on the left of it, result on the right.
    var split: CGFloat = 0.5 { didSet { needsDisplay = true } }
    private(set) var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    /// Crop mode: drag a rectangle on the full picture. Reports it in image pixels, top left origin.
    var cropping = false { didSet { cropDrag = nil; needsDisplay = true } }
    var crop: CGRect? { didSet { needsDisplay = true } }
    var onCrop: ((CGRect?) -> Void)?

    private enum Drag { case pan(start: CGPoint, origin: CGPoint), split, crop(start: CGPoint) }
    private var drag: Drag?
    private var cropDrag: CGRect?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func zoom(by factor: CGFloat) {
        zoom = min(32, max(1, zoom * factor))
        if zoom == 1 { pan = .zero }
        needsDisplay = true
    }

    func zoomToFit() {
        zoom = 1
        pan = .zero
        needsDisplay = true
    }

    /// The panels the images are drawn in.
    private var panels: [CGRect] {
        let b = bounds.insetBy(dx: 4, dy: 4)
        if mode == .sideBySide && !cropping {
            let half = (b.width - 8) / 2
            return [CGRect(x: b.minX, y: b.minY, width: half, height: b.height),
                    CGRect(x: b.minX + half + 8, y: b.minY, width: half, height: b.height)]
        }
        return [b]
    }

    /// Where the picture is drawn in `panel`: fitted, then zoomed about the centre and panned.
    private func frame(in panel: CGRect, aspect: CGSize) -> CGRect {
        guard aspect.width > 0, aspect.height > 0 else { return panel }
        let scale = min(panel.width / aspect.width, panel.height / aspect.height) * zoom
        let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        return CGRect(x: panel.midX - size.width / 2 + pan.x, y: panel.midY - size.height / 2 + pan.y,
                      width: size.width, height: size.height)
    }

    /// The shape both images share: the result's when there is one (its proportions are the
    /// picture's, rounded to whole cells), else the original's.
    private var aspect: CGSize {
        if cropping, let full = fullOriginal { return CGSize(width: full.width, height: full.height) }
        if let result { return CGSize(width: result.width, height: result.height) }
        if let original { return CGSize(width: original.width, height: original.height) }
        return CGSize(width: 4, height: 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        context.fill(bounds)
        if cropping {
            drawCropping(context)
            return
        }
        let panels = self.panels
        func draw(_ image: CGImage?, in panel: CGRect, smooth: Bool, clip: CGRect? = nil) {
            guard let image else { return }
            context.saveGState()
            context.clip(to: clip ?? panel)
            context.interpolationQuality = smooth ? .high : .none
            context.draw(image, in: frame(in: panel, aspect: aspect))
            context.restoreGState()
        }
        switch mode {
        case .split:
            let panel = panels[0]
            let f = frame(in: panel, aspect: aspect)
            let x = f.minX + f.width * split
            draw(original, in: panel, smooth: smoothOriginal, clip: CGRect(x: panel.minX, y: panel.minY, width: max(0, x - panel.minX), height: panel.height))
            draw(result, in: panel, smooth: false, clip: CGRect(x: x, y: panel.minY, width: max(0, panel.maxX - x), height: panel.height))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: x - 1, y: panel.minY, width: 2, height: panel.height))
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fillEllipse(in: CGRect(x: x - 7, y: panel.midY - 7, width: 14, height: 14))
        case .sideBySide:
            draw(original, in: panels[0], smooth: smoothOriginal)
            draw(result, in: panels[1], smooth: false)
        case .original:
            draw(original, in: panels[0], smooth: smoothOriginal)
        case .result:
            draw(result, in: panels[0], smooth: false)
        }
    }

    private func drawCropping(_ context: CGContext) {
        guard let full = fullOriginal else { return }
        let f = frame(in: panels[0], aspect: aspect)
        context.interpolationQuality = smoothOriginal ? .high : .none
        context.draw(full, in: f)
        guard let rect = cropDrag ?? crop.map({ viewRect(fromImage: $0, frame: f, image: full) }) else { return }
        context.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
        context.addRect(f)
        context.addRect(rect)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.stroke(rect)
    }

    private func viewRect(fromImage r: CGRect, frame f: CGRect, image: CGImage) -> CGRect {
        let sx = f.width / CGFloat(image.width), sy = f.height / CGFloat(image.height)
        return CGRect(x: f.minX + r.minX * sx, y: f.maxY - r.maxY * sy, width: r.width * sx, height: r.height * sy)
    }

    private func imageRect(fromView r: CGRect, frame f: CGRect, image: CGImage) -> CGRect {
        let sx = CGFloat(image.width) / f.width, sy = CGFloat(image.height) / f.height
        return CGRect(x: (r.minX - f.minX) * sx, y: (f.maxY - r.maxY) * sy, width: r.width * sx, height: r.height * sy)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if cropping {
            drag = .crop(start: p)
            return
        }
        if mode == .split {
            let f = frame(in: panels[0], aspect: aspect)
            if abs(p.x - (f.minX + f.width * split)) < 10 { drag = .split; return }
        }
        drag = .pan(start: p, origin: pan)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .split:
            let f = frame(in: panels[0], aspect: aspect)
            split = min(1, max(0, (p.x - f.minX) / max(1, f.width)))
        case .pan(let start, let origin):
            pan = CGPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y)
            needsDisplay = true
        case .crop(let start):
            let f = frame(in: panels[0], aspect: aspect)
            cropDrag = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
                .intersection(f)
            needsDisplay = true
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .crop = drag, let rect = cropDrag, let full = fullOriginal, rect.width > 3, rect.height > 3 {
            let f = frame(in: panels[0], aspect: aspect)
            let imageRect = imageRect(fromView: rect, frame: f, image: full).integral
            crop = ImageToAnsi.normalizedCrop(imageRect, width: full.width, height: full.height)
            onCrop?(crop)
        }
        cropDrag = nil
        drag = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(by: event.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1)
        } else {
            pan.x += event.scrollingDeltaX
            pan.y -= event.scrollingDeltaY
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification)
    }
}

/// The import window's content: settings on the left, the live preview on the right.
final class ImageImportViewController: NSViewController {
    private(set) var image: CGImage
    private(set) var name: String
    private(set) var options: ImageToAnsi.Options
    private(set) var preset: ImagePreset
    /// The latest preview, and which candidate is shown (Auto offers up to three).
    private(set) var preview: ImagePreview?
    private(set) var selectedCandidate = 0
    /// Request to delivery, including the debounce wait, for the last preview.
    private(set) var lastLatencyMilliseconds: Double = 0
    var onPreview: (() -> Void)?
    var onOpenInEditor: ((EditCanvas, String, SaveFormat) -> Void)?
    var onClose: (() -> Void)?

    private let scheduler = PreviewScheduler<ImagePreview>()
    private let comparison = ImageComparisonView()
    private let status = NSTextField(labelWithString: "Converting...")
    private let spinner = NSProgressIndicator()
    private var candidateButtons: [NSButton] = []
    private let candidateRow = NSStackView()
    private let candidateBox = NSStackView()

    // Settings controls
    private let presetPopup = NSPopUpButton()
    private let methodPopup = NSPopUpButton()
    private let widthField = NSTextField()
    private let widthStepper = NSStepper()
    private let palettePopup = NSPopUpButton()
    private let ditherPopup = NSPopUpButton()
    private let strengthSlider = NSSlider()
    private let iceBox = NSButton(checkboxWithTitle: "iCE colours (bright backgrounds)", target: nil, action: nil)
    private let aspectBox = NSButton(checkboxWithTitle: "Keep proportions (8x16 cells)", target: nil, action: nil)
    private let extendedBox = NSButton(checkboxWithTitle: "Also try line and box characters", target: nil, action: nil)
    private let nearestBox = NSButton(checkboxWithTitle: "Sharp pixels (no smoothing)", target: nil, action: nil)
    private let levelsBox = NSButton(checkboxWithTitle: "Auto levels", target: nil, action: nil)
    private let brightnessSlider = NSSlider()
    private let contrastSlider = NSSlider()
    private let saturationSlider = NSSlider()
    private let gammaSlider = NSSlider()
    private let sharpenSlider = NSSlider()
    private let backgroundBox = NSButton(checkboxWithTitle: "Remove background (logos)", target: nil, action: nil)
    private let toleranceSlider = NSSlider()
    private let viewControl = NSSegmentedControl(labels: ["Split", "Side by side", "Original", "Result"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let cropButton = NSButton(title: "Crop", target: nil, action: nil)
    private let resetCropButton = NSButton(title: "Reset Crop", target: nil, action: nil)
    private var valueLabels: [NSSlider: (NSTextField, (Double) -> String)] = [:]
    private var requestedAt = Date()

    init(image: CGImage, name: String, options: ImageToAnsi.Options = ImageImportSettings.options,
         preset: ImagePreset = ImageImportSettings.preset) {
        self.image = image
        self.name = name
        self.options = options
        self.preset = preset
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The canvas the buttons act on.
    var currentCandidate: ImagePreview.Candidate? {
        guard let preview, !preview.candidates.isEmpty else { return nil }
        return preview.candidates[min(selectedCandidate, preview.candidates.count - 1)]
    }

    override func loadView() {
        let root = ImageImportRootView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760))
        root.onDrop = { [weak self] url in
            guard let self else { return }
            do {
                self.replaceImage(try ImageToAnsi.load(try Data(contentsOf: url)), name: url.deletingPathExtension().lastPathComponent)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        let settings = buildSettings()
        let scroll = NSScrollView()
        scroll.documentView = settings
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        settings.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = buildToolbar()
        candidateRow.orientation = .horizontal
        candidateRow.spacing = 10
        candidateRow.alignment = .top
        for index in 0..<3 {
            let button = NSButton(title: "", target: self, action: #selector(pickCandidate(_:)))
            button.tag = index
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageAbove
            button.imageScaling = .scaleProportionallyUpOrDown
            button.font = .systemFont(ofSize: 11)
            button.toolTip = ImageImportHelp.tooltips["candidates"]
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 190).isActive = true
            button.heightAnchor.constraint(equalToConstant: 128).isActive = true
            candidateButtons.append(button)
            candidateRow.addArrangedSubview(button)
        }
        let candidateLabel = NSTextField(labelWithString: "Auto's best three:")
        candidateLabel.font = .boldSystemFont(ofSize: 11)
        candidateBox.setViews([candidateLabel, candidateRow, helpButton("score")], in: .leading)
        candidateBox.orientation = .horizontal
        candidateBox.alignment = .centerY

        comparison.translatesAutoresizingMaskIntoConstraints = false
        comparison.toolTip = ImageImportHelp.tooltips["split"]
        comparison.onCrop = { [weak self] crop in self?.cropChanged(crop) }
        status.toolTip = ImageImportHelp.tooltips["status"]
        status.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.orientation = .horizontal

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save As...", target: self, action: #selector(saveAs(_:)))
        save.toolTip = ImageImportHelp.tooltips["save"]
        let open = NSButton(title: "Open in Editor", target: self, action: #selector(openInEditor(_:)))
        open.keyEquivalent = "\r"
        open.toolTip = ImageImportHelp.tooltips["open"]
        let buttons = NSStackView(views: [statusRow, NSView(), cancel, save, open])
        buttons.orientation = .horizontal
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)

        let right = NSStackView(views: [toolbar, candidateBox, comparison, buttons])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(right)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 372),
            settings.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            settings.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            right.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 8),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            right.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            comparison.widthAnchor.constraint(equalTo: right.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: right.widthAnchor),
            comparison.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        view = root
        root.registerForDraggedTypes([.fileURL])
        showControls()
        refresh()
    }

    // MARK: Building

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func helpButton(_ topic: String) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(showHelp(_:)))
        b.bezelStyle = .helpButton
        b.identifier = NSUserInterfaceItemIdentifier(topic)
        b.toolTip = ImageImportHelp.explanations[topic]?.title
        b.setAccessibilityLabel("Explain " + (ImageImportHelp.explanations[topic]?.title ?? topic))
        return b
    }

    private func section(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.font = .boldSystemFont(ofSize: 12)
        return l
    }

    private func slider(_ s: NSSlider, _ id: String, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> NSView {
        s.minValue = range.lowerBound
        s.maxValue = range.upperBound
        s.target = self
        s.action = #selector(controlChanged(_:))
        s.isContinuous = true
        s.toolTip = ImageImportHelp.tooltips[id]
        s.controlSize = .small
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 42).isActive = true
        valueLabels[s] = (value, format)
        let row = NSStackView(views: [s, value])
        row.orientation = .horizontal
        return row
    }

    private func buildSettings() -> NSView {
        func popup(_ p: NSPopUpButton, _ id: String, _ titles: [String]) {
            p.addItems(withTitles: titles)
            p.target = self
            p.action = #selector(controlChanged(_:))
            p.toolTip = ImageImportHelp.tooltips[id]
        }
        func check(_ b: NSButton, _ id: String) {
            b.target = self
            b.action = #selector(controlChanged(_:))
            b.toolTip = ImageImportHelp.tooltips[id]
        }
        popup(presetPopup, "preset", ImagePreset.allCases.map(\.label))
        popup(methodPopup, "method", ImageToAnsi.Mode.allCases.map(\.label))
        popup(palettePopup, "palette", ImageToAnsi.PaletteChoice.allCases.map(\.label))
        popup(ditherPopup, "dither", ImageToAnsi.Dither.allCases.map(\.label))
        for (b, id) in [(iceBox, "ice"), (aspectBox, "aspect"), (extendedBox, "extended"), (nearestBox, "nearest"),
                        (levelsBox, "levels"), (backgroundBox, "background")] { check(b, id) }
        widthField.formatter = {
            let f = NumberFormatter()
            f.minimum = 1
            f.maximum = NSNumber(value: EditCanvas.maxColumns)
            f.allowsFloats = false
            return f
        }()
        widthField.target = self
        widthField.action = #selector(controlChanged(_:))
        widthField.toolTip = ImageImportHelp.tooltips["width"]
        widthField.translatesAutoresizingMaskIntoConstraints = false
        widthField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        widthStepper.minValue = 1
        widthStepper.maxValue = Double(EditCanvas.maxColumns)
        widthStepper.increment = 1
        widthStepper.valueWraps = false
        widthStepper.target = self
        widthStepper.action = #selector(stepperChanged(_:))
        widthStepper.toolTip = ImageImportHelp.tooltips["width"]
        let widthRow = NSStackView(views: [widthField, widthStepper, NSTextField(labelWithString: "columns")])

        let percent: (Double) -> String = { "\(Int($0.rounded()))%" }
        let signed: (Double) -> String = { $0 > 0.5 ? "+\(Int($0.rounded()))" : "\(Int($0.rounded()))" }
        let rows: [[NSView]] = [
            [section("Method"), NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Preset:"), presetPopup, NSGridCell.emptyContentView],
            [label("Characters:"), methodPopup, helpButton("glyph")],
            [label("Width:"), widthRow, NSGridCell.emptyContentView],
            [label("Colours:"), palettePopup, helpButton("xbin")],
            [label("Dithering:"), ditherPopup, helpButton("dither")],
            [label("Strength:"), slider(strengthSlider, "strength", range: 0...100, format: percent), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, iceBox, helpButton("ice")],
            [NSGridCell.emptyContentView, aspectBox, helpButton("aspect")],
            [NSGridCell.emptyContentView, extendedBox, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, nearestBox, NSGridCell.emptyContentView],
            [section("Picture"), NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, levelsBox, NSGridCell.emptyContentView],
            [label("Brightness:"), slider(brightnessSlider, "brightness", range: -100...100, format: signed), NSGridCell.emptyContentView],
            [label("Contrast:"), slider(contrastSlider, "contrast", range: -100...100, format: signed), NSGridCell.emptyContentView],
            [label("Saturation:"), slider(saturationSlider, "saturation", range: -100...100, format: signed), NSGridCell.emptyContentView],
            [label("Gamma:"), slider(gammaSlider, "gamma", range: 0.2...3, format: { String(format: "%.2f", $0) }), NSGridCell.emptyContentView],
            [label("Sharpen:"), slider(sharpenSlider, "sharpen", range: 0...200, format: percent), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, backgroundBox, NSGridCell.emptyContentView],
            [label("Tolerance:"), slider(toleranceSlider, "tolerance", range: 0...50, format: percent), NSGridCell.emptyContentView],
            [label("Matching:"), NSTextField(labelWithString: "Perceptual (OKLab)"), helpButton("oklab")],
        ]
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 7
        grid.columnSpacing = 6
        for row in [0, 11] { grid.row(at: row).topPadding = row == 0 ? 0 : 10 }
        let container = FlippedView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -6),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func buildToolbar() -> NSView {
        viewControl.target = self
        viewControl.action = #selector(viewModeChanged(_:))
        viewControl.selectedSegment = 0
        viewControl.toolTip = ImageImportHelp.tooltips["view"]
        func small(_ title: String, _ id: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.toolTip = ImageImportHelp.tooltips[id]
            b.bezelStyle = .rounded
            return b
        }
        cropButton.setButtonType(.pushOnPushOff)
        cropButton.bezelStyle = .rounded
        cropButton.target = self
        cropButton.action = #selector(toggleCrop(_:))
        cropButton.toolTip = ImageImportHelp.tooltips["crop"]
        resetCropButton.bezelStyle = .rounded
        resetCropButton.target = self
        resetCropButton.action = #selector(resetCrop(_:))
        resetCropButton.toolTip = ImageImportHelp.tooltips["resetCrop"]
        let bar = NSStackView(views: [viewControl, small("-", "zoomOut", #selector(zoomOut(_:))), small("+", "zoomIn", #selector(zoomIn(_:))),
                                      small("Fit", "zoomFit", #selector(zoomFit(_:))), cropButton, resetCropButton])
        bar.orientation = .horizontal
        return bar
    }

    // MARK: Controls

    /// Puts `options` and `preset` into the controls.
    private func showControls() {
        presetPopup.selectItem(at: ImagePreset.allCases.firstIndex(of: preset) ?? 0)
        methodPopup.selectItem(at: ImageToAnsi.Mode.allCases.firstIndex(of: options.mode) ?? 0)
        palettePopup.selectItem(at: ImageToAnsi.PaletteChoice.allCases.firstIndex(of: options.palette) ?? 0)
        ditherPopup.selectItem(at: ImageToAnsi.Dither.allCases.firstIndex(of: options.dither) ?? 0)
        widthField.integerValue = options.columns
        widthStepper.integerValue = options.columns
        strengthSlider.doubleValue = Double(options.ditherStrength * 100)
        iceBox.state = options.iceColors ? .on : .off
        aspectBox.state = options.aspectCorrection ? .on : .off
        extendedBox.state = options.extendedGlyphs ? .on : .off
        nearestBox.state = options.nearestNeighbour ? .on : .off
        let a = options.adjustments
        levelsBox.state = a.autoLevels ? .on : .off
        brightnessSlider.doubleValue = Double(a.brightness * 100)
        contrastSlider.doubleValue = Double(a.contrast * 100)
        saturationSlider.doubleValue = Double(a.saturation * 100)
        gammaSlider.doubleValue = Double(a.gamma)
        sharpenSlider.doubleValue = Double(a.sharpen * 100)
        backgroundBox.state = a.removeBackground ? .on : .off
        toleranceSlider.doubleValue = Double(a.backgroundTolerance * 100)
        updateEnabled()
        updateValueLabels()
    }

    private func updateValueLabels() {
        for (slider, entry) in valueLabels { entry.0.stringValue = entry.1(slider.doubleValue) }
    }

    /// Auto chooses the method itself, so its method controls only show what it picked.
    private func updateEnabled() {
        let auto = preset == .auto
        for control in [methodPopup, ditherPopup, extendedBox, nearestBox] as [NSControl] { control.isEnabled = !auto }
        strengthSlider.isEnabled = !auto && options.dither != .none
        toleranceSlider.isEnabled = options.adjustments.removeBackground
        resetCropButton.isEnabled = options.crop != nil
        candidateBox.isHidden = !auto
    }

    /// Reads the controls back into `options`.
    private func readControls() {
        options.mode = ImageToAnsi.Mode.allCases[max(0, methodPopup.indexOfSelectedItem)]
        options.palette = ImageToAnsi.PaletteChoice.allCases[max(0, palettePopup.indexOfSelectedItem)]
        options.dither = ImageToAnsi.Dither.allCases[max(0, ditherPopup.indexOfSelectedItem)]
        options.columns = min(EditCanvas.maxColumns, max(1, widthField.integerValue))
        options.ditherStrength = Float(strengthSlider.doubleValue / 100)
        options.iceColors = iceBox.state == .on
        options.aspectCorrection = aspectBox.state == .on
        options.extendedGlyphs = extendedBox.state == .on
        options.nearestNeighbour = nearestBox.state == .on
        options.adjustments.autoLevels = levelsBox.state == .on
        options.adjustments.brightness = Float(brightnessSlider.doubleValue / 100)
        options.adjustments.contrast = Float(contrastSlider.doubleValue / 100)
        options.adjustments.saturation = Float(saturationSlider.doubleValue / 100)
        options.adjustments.gamma = Float(gammaSlider.doubleValue)
        options.adjustments.sharpen = Float(sharpenSlider.doubleValue / 100)
        options.adjustments.removeBackground = backgroundBox.state == .on
        options.adjustments.backgroundTolerance = Float(toleranceSlider.doubleValue / 100)
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        widthField.integerValue = sender.integerValue
        controlChanged(widthField)
    }

    @objc func controlChanged(_ sender: Any?) {
        if let sender = sender as? NSPopUpButton, sender === presetPopup {
            setPreset(ImagePreset.allCases[max(0, presetPopup.indexOfSelectedItem)])
            return
        }
        readControls()
        widthStepper.integerValue = options.columns
        // Changing a method setting by hand turns a named preset into Custom.
        let methodControls: [AnyObject] = [methodPopup, ditherPopup, strengthSlider, extendedBox, nearestBox]
        if preset != .auto, preset != .custom, let sender = sender as AnyObject?, methodControls.contains(where: { $0 === sender }) {
            preset = .custom
            presetPopup.selectItem(at: ImagePreset.allCases.firstIndex(of: .custom) ?? 0)
        }
        comparison.smoothOriginal = !options.nearestNeighbour
        updateEnabled()
        updateValueLabels()
        refresh()
    }

    /// Applies a preset's settings to the controls and renders.
    func setPreset(_ newPreset: ImagePreset) {
        preset = newPreset
        options = newPreset.options(base: options, imageWidth: image.width, imageHeight: image.height)
        selectedCandidate = 0
        showControls()
        comparison.smoothOriginal = !options.nearestNeighbour
        refresh()
    }

    /// For tests and the harness: change settings as the controls would.
    func apply(_ change: (inout ImageToAnsi.Options) -> Void) {
        change(&options)
        showControls()
        refresh()
    }

    /// A new picture (dropped on the window): the crop resets.
    func replaceImage(_ newImage: CGImage, name newName: String) {
        image = newImage
        name = newName
        options.crop = nil
        comparison.crop = nil
        if preset == .pixelArt { options = preset.options(base: options, imageWidth: image.width, imageHeight: image.height) }
        showControls()
        refresh()
    }

    private func cropChanged(_ crop: CGRect?) {
        options.crop = crop
        if preset == .pixelArt { options = preset.options(base: options, imageWidth: image.width, imageHeight: image.height) }
        showControls()
        refresh()
    }

    // MARK: Rendering

    /// Schedules a preview for the current settings (debounced; stale renders are dropped).
    func refresh() {
        comparison.fullOriginal = image
        comparison.original = ImageToAnsi.croppedImage(image, crop: options.crop)
        comparison.crop = options.crop
        spinner.startAnimation(nil)
        let image = self.image, options = self.options, preset = self.preset
        requestedAt = Date()
        scheduler.request({ isCancelled in
            Self.render(image: image, options: options, preset: preset, isCancelled: isCancelled)
        }, completion: { [weak self] preview in
            self?.show(preview)
        })
    }

    static func render(image: CGImage, options: ImageToAnsi.Options, preset: ImagePreset,
                       isCancelled: @escaping () -> Bool) -> ImagePreview? {
        let start = Date()
        func candidate(_ name: String, _ options: ImageToAnsi.Options, _ canvas: EditCanvas,
                       _ score: ImageScore.Result) -> ImagePreview.Candidate? {
            guard let rendered = AnsiRenderer.render(canvas.screen(trimmed: false), options: RenderOptions(font: canvas.font, scale: 1)) else { return nil }
            let bytes = (try? ArtWriter.data(canvas, format: options.palette.saveFormat))?.count ?? 0
            return ImagePreview.Candidate(name: name, options: options, canvas: canvas, image: rendered.image, score: score, bytes: bytes)
        }
        var candidates: [ImagePreview.Candidate] = []
        if preset == .auto {
            guard let ranked = ImageToAnsi.autoCandidates(image, base: options, cancel: isCancelled) else { return nil }
            for c in ranked.prefix(3) {
                if let made = candidate(c.name, c.options, c.canvas, c.score) { candidates.append(made) }
            }
        } else {
            guard let canvas = ImageToAnsi.convert(image, options: options, cancel: isCancelled), !isCancelled() else { return nil }
            let score = ImageScore.score(canvas, source: image, options: options)
            if let made = candidate(preset.label, options, canvas, score) { candidates.append(made) }
        }
        if isCancelled() { return nil }
        return ImagePreview(candidates: candidates, workMilliseconds: Date().timeIntervalSince(start) * 1000)
    }

    private func show(_ preview: ImagePreview) {
        self.preview = preview
        lastLatencyMilliseconds = Date().timeIntervalSince(requestedAt) * 1000
        spinner.stopAnimation(nil)
        selectedCandidate = min(selectedCandidate, max(0, preview.candidates.count - 1))
        for (index, button) in candidateButtons.enumerated() {
            if index < preview.candidates.count {
                let c = preview.candidates[index]
                button.isHidden = false
                button.image = NSImage(cgImage: c.image, size: NSSize(width: c.image.width, height: c.image.height))
                button.title = String(format: "%d. %@ (%.1f)", index + 1, c.name, c.score.deltaE)
                button.state = index == selectedCandidate ? .on : .off
            } else {
                button.isHidden = true
            }
        }
        showSelected()
        onPreview?()
    }

    private func showSelected() {
        guard let c = currentCandidate else { return }
        comparison.result = c.image
        if preset == .auto {
            // Show what Auto chose in the (disabled) method controls.
            var shown = options
            shown.mode = c.options.mode
            shown.dither = c.options.dither
            shown.ditherStrength = c.options.ditherStrength
            shown.extendedGlyphs = c.options.extendedGlyphs
            let kept = options
            options = shown
            showControls()
            options = kept
        }
        let format = c.options.palette.saveFormat
        status.stringValue = String(format: "%d x %d characters, %@ bytes (.%@)  |  difference %.1f  |  preview %.0f ms",
                                    c.canvas.columns, c.canvas.height,
                                    NumberFormatter.localizedString(from: NSNumber(value: c.bytes), number: .decimal),
                                    format.fileExtension, c.score.deltaE, lastLatencyMilliseconds)
    }

    @objc private func pickCandidate(_ sender: NSButton) {
        selectedCandidate = sender.tag
        for (index, button) in candidateButtons.enumerated() { button.state = index == selectedCandidate ? .on : .off }
        showSelected()
    }

    // MARK: Actions

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) {
        comparison.mode = ImageComparisonView.Mode(rawValue: sender.selectedSegment) ?? .split
    }

    func setViewMode(_ mode: ImageComparisonView.Mode) {
        viewControl.selectedSegment = mode.rawValue
        comparison.mode = mode
    }

    @objc private func zoomIn(_ sender: Any?) { comparison.zoom(by: 1.5) }
    @objc private func zoomOut(_ sender: Any?) { comparison.zoom(by: 1 / 1.5) }
    @objc private func zoomFit(_ sender: Any?) { comparison.zoomToFit() }

    @objc private func toggleCrop(_ sender: NSButton) {
        comparison.cropping = sender.state == .on
    }

    func setCropping(_ on: Bool) {
        cropButton.state = on ? .on : .off
        comparison.cropping = on
    }

    @objc private func resetCrop(_ sender: Any?) {
        cropChanged(nil)
    }

    @objc private func showHelp(_ sender: NSButton) {
        guard let topic = sender.identifier?.rawValue, let entry = ImageImportHelp.explanations[topic] else { return }
        let title = NSTextField(labelWithString: entry.title)
        title.font = .boldSystemFont(ofSize: 13)
        let text = NSTextField(wrappingLabelWithString: entry.text)
        text.preferredMaxLayoutWidth = 320
        let stack = NSStackView(views: [title, text])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    @objc private func cancel(_ sender: Any?) {
        scheduler.cancel()
        onClose?()
    }

    private var finalCanvas: (EditCanvas, SaveFormat)? {
        guard let c = currentCandidate else { NSSound.beep(); return nil }
        var canvas = c.canvas
        canvas.title = String(name.prefix(35))
        return (canvas, c.options.palette.saveFormat)
    }

    private func remember() {
        var kept = options
        if preset == .auto, let c = currentCandidate { kept.palette = c.options.palette }
        ImageImportSettings.options = kept
        ImageImportSettings.preset = preset
    }

    @objc private func saveAs(_ sender: Any?) {
        guard let (canvas, format) = finalCanvas, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = name + "." + format.fileExtension
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ArtWriter.data(canvas, format: format).write(to: url)
                self?.remember()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func openInEditor(_ sender: Any?) {
        guard let (canvas, format) = finalCanvas else { return }
        remember()
        scheduler.cancel()
        onOpenInEditor?(canvas, "\(name) (imported)", format)
        onClose?()
    }
}

/// Top aligned content for the settings scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The import window's root view: accepts image files dropped on it.
final class ImageImportRootView: NSView {
    var onDrop: ((URL) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    static func imageURL(from info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first(where: ImageBatch.isImage)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.imageURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = Self.imageURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }
}
