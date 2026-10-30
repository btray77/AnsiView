import AnsiCore
import AppKit
import SwiftUI

// The BBS screen designer (screen designer plan): the Screen menu, the settings it keeps and the
// helpers its windows share. The windows are in ScreenTemplateGallery.swift,
// DisplayCodePicker.swift, ScreenComponentLibrary.swift, CallerPreview.swift and ScreenExportUI.swift.

/// Profiles, sample values and the picker's package, kept in UserDefaults; screen sets and user
/// components live in Application Support.
final class ScreenDesignerSettings {
    static let shared = ScreenDesignerSettings()
    static let changed = Notification.Name("ScreenDesignerSettingsChanged")

    var defaults: UserDefaults
    var supportDirectory: URL

    init(defaults: UserDefaults = .standard, supportDirectory: URL? = nil) {
        self.defaults = defaults
        self.supportDirectory = supportDirectory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("AnsiView", isDirectory: true)
    }

    private func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    var profiles: [ExportProfile] {
        get { load("screenDesigner.profiles", as: [ExportProfile].self) ?? [] }
        set { store(newValue, "screenDesigner.profiles") }
    }

    var samples: SampleValues {
        get { load("screenDesigner.samples", as: SampleValues.self) ?? SampleValues() }
        set { store(newValue, "screenDesigner.samples") }
    }

    /// The package the picker, templates and previews use when no profile says otherwise.
    var package: BBSPackage {
        get { defaults.string(forKey: "screenDesigner.package").map(BBSPackage.init(rawValue:)) ?? .synchronet }
        set { defaults.set(newValue.rawValue, forKey: "screenDesigner.package"); NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    var lastProfileID: UUID? {
        get { defaults.string(forKey: "screenDesigner.lastProfile").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "screenDesigner.lastProfile") }
    }

    func saveProfile(_ profile: ExportProfile) {
        var list = profiles
        if let i = list.firstIndex(where: { $0.id == profile.id }) { list[i] = profile } else { list.append(profile) }
        profiles = list
    }

    func deleteProfile(_ id: UUID) {
        profiles = profiles.filter { $0.id != id }
        try? FileManager.default.removeItem(at: screenSetURL(id))
    }

    var components: ComponentStore { ComponentStore(directory: supportDirectory.appendingPathComponent("Components", isDirectory: true)) }

    func screenSetURL(_ profileID: UUID) -> URL {
        supportDirectory.appendingPathComponent("Screen Sets", isDirectory: true).appendingPathComponent("\(profileID.uuidString).json")
    }

    func screenSet(for profileID: UUID) -> ScreenSet {
        (try? Data(contentsOf: screenSetURL(profileID))).flatMap { try? ScreenSet(data: $0) } ?? ScreenSet(profileID: profileID)
    }

    func saveScreenSet(_ set: ScreenSet) {
        let url = screenSetURL(set.profileID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? set.data().write(to: url, options: .atomic)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

enum ScreenDesigner {
    /// The editor the screen designer windows act on: the key or main editor window, else the
    /// frontmost one.
    static var focusedEditor: EditorWindowController? {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        for window in windows where window.isVisible {
            if let controller = window.windowController as? EditorWindowController { return controller }
        }
        return nil
    }

    static func requireEditor(_ action: String) -> EditorWindowController? {
        if let editor = focusedEditor { return editor }
        let alert = NSAlert()
        alert.messageText = "No screen to \(action)"
        alert.informativeText = "Open or create a screen first (File > New from Template... or File > New ANSI Art), then try again."
        alert.runModal()
        return nil
    }

    /// Types `token` at the editor's cursor as one undo step (control bytes such as Ctrl-A go in
    /// as their CP437 glyph, which the editor stores as the same byte).
    static func insert(_ token: String, into editor: CanvasEditor) {
        let glyphs = String(String.UnicodeScalarView(token.utf8.map { CP437.unicode[Int($0)] }))
        editor.type(glyphs)
    }

    /// A popup of every registered package.
    static func packagePopup(selected: BBSPackage, tooltip: String) -> NSPopUpButton {
        let popup = NSPopUpButton()
        for package in BBSPackage.allCases {
            popup.addItem(withTitle: package.displayName)
            popup.lastItem?.representedObject = package.rawValue
        }
        popup.selectItem(at: BBSPackage.allCases.firstIndex(of: selected) ?? 0)
        popup.toolTip = tooltip
        return popup
    }

    static func package(of popup: NSPopUpButton) -> BBSPackage {
        let all = BBSPackage.allCases
        return all.indices.contains(popup.indexOfSelectedItem) ? all[popup.indexOfSelectedItem] : .synchronet
    }

    static func image(_ canvas: EditCanvas, scale: Int = 1) -> NSImage? {
        var screen = canvas.screen(trimmed: false)
        screen.sauce = nil
        guard let rendered = AnsiRenderer.render(screen, options: RenderOptions(font: canvas.font, scale: scale)) else { return nil }
        return NSImage(cgImage: rendered.image, size: NSSize(width: rendered.image.width, height: rendered.image.height))
    }

    static func label(_ text: String, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: size)
        if secondary { label.textColor = .secondaryLabelColor }
        return label
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .centerY
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        stack.setClippingResistancePriority(.required, for: .vertical)
        return stack
    }

    static func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        // The view with the lowest hugging priority (a scroll view or an image) takes the spare height.
        stack.distribution = .fill
        // A root stack must not pull its window down to the stack's fitting size.
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    /// A plain root view holding `stack` pinned to its edges, so the window decides the size.
    static func container(_ stack: NSView, minimum: NSSize = NSSize(width: 400, height: 300)) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: minimum))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum.width),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: minimum.height),
        ])
        return root
    }

    static let help = """
    The Screen menu designs BBS screens: start from a template, insert your BBS's display codes from the picker, \
    see them with sample values, check what a caller sees at their speed and screen size, then export straight into \
    your BBS folder with the file name your BBS looks for. AnsiView is the caller side: it does not run a BBS.
    """
}

/// The Screen menu.
struct ScreenDesignerCommands: Commands {
    var body: some Commands {
        CommandMenu("Screen") {
            Button("New from Template...") { ScreenTemplateGalleryWindowController.show() }
            Divider()
            Button("Insert Display Code...") { DisplayCodePickerWindowController.show() }
                .keyboardShortcut("k", modifiers: [.command, .option])
            Button("Sample Values...") { SampleValuesWindowController.show() }
            Button("Sample Values Preview") { SampleValuesPreviewWindowController.show() }
            Divider()
            Button("Component Library...") { ComponentLibraryWindowController.show() }
            Button("Save Selection as Component...") { ComponentLibraryWindowController.saveSelection() }
            Divider()
            Button("Preview as Caller...") { CallerPreviewWindowController.showForFocusedEditor() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Export to BBS...") { ScreenExportController.exportFocusedEditor() }
            Button("Export Profiles...") { ExportProfilesWindowController.show() }
            Button("Screen Set...") { ScreenSetWindowController.show() }
            Divider()
            Button("Open with BBS Codes...") { ScreenExportController.openWithCodes() }
        }
    }
}
