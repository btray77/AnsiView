import AnsiCore
import AppKit
import CoreText
import SwiftUI

extension NSColor {
    convenience init(_ c: RGB) {
        self.init(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}

/// Applies the chosen appearance (AnsiView > Settings > Appearance, final gaps ruling 9) to the
/// whole app. System, Light and Dark set `NSApp.appearance`; Retro is dark aqua plus deep blue
/// window backgrounds and light grey labels, recoloured back when another appearance is chosen.
final class AppearanceController: NSObject {
    static let shared = AppearanceController()
    static let changed = Notification.Name("AppAppearanceChanged")

    var defaults: UserDefaults = .standard
    /// Labels recoloured for Retro: the colour they had, and the colour Retro gave them.
    private let originalColours = NSMapTable<NSTextField, NSColor>.weakToStrongObjects()
    private let retroColours = NSMapTable<NSTextField, NSColor>.weakToStrongObjects()
    /// Windows given the Retro background, with the background they had.
    private let originalBackgrounds = NSMapTable<NSWindow, NSColor>.weakToStrongObjects()
    private var observing = false

    /// The system label colours Retro replaces; any other colour (warnings, the editor's status
    /// line) is the app's own choice and is left alone (review I1).
    static let systemLabelColours: [NSColor] = [.labelColor, .secondaryLabelColor, .tertiaryLabelColor, .controlTextColor]

    var current: AppAppearance { AppAppearance.current(in: defaults) }

    func choose(_ appearance: AppAppearance) {
        AppAppearance.set(appearance, in: defaults)
        apply()
    }

    /// Sets the app appearance and restyles every open window. Windows with their own colours
    /// (the editor) hear `changed` first, so their colours are set before the labels are looked at.
    func apply() {
        let appearance = current
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark, .retro: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        if !observing {
            observing = true
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didUpdateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
            }
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
        for window in NSApp.windows { style(window) }
    }

    @objc private func windowChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        // didUpdate fires often: only windows not styled yet are looked at then.
        if note.name == NSWindow.didUpdateNotification, current != .retro || originalBackgrounds.object(forKey: window) != nil { return }
        style(window)
    }

    /// Retro colours for a window, or its own ones back.
    func style(_ window: NSWindow) {
        if current == .retro {
            // Only windows in the standard background: black stages (terminal, slideshow,
            // presentation, dialing directory) keep their colour (review I3).
            if originalBackgrounds.object(forKey: window) == nil, window.backgroundColor == .windowBackgroundColor {
                originalBackgrounds.setObject(window.backgroundColor, forKey: window)
                window.backgroundColor = NSColor(RetroTheme.background)
            }
            if originalBackgrounds.object(forKey: window) != nil, let content = window.contentView { recolour(content) }
        } else {
            if let original = originalBackgrounds.object(forKey: window) {
                window.backgroundColor = original
                originalBackgrounds.removeObject(forKey: window)
            }
            if let content = window.contentView { restore(content) }
        }
    }

    /// Plain labels (not editable, no background of their own) in system colours get the Retro ones.
    private func recolour(_ view: NSView) {
        if let label = view as? NSTextField, !label.isEditable, !label.drawsBackground, !label.isBezeled {
            let colour = label.textColor ?? .labelColor
            if let given = retroColours.object(forKey: label) {
                // The app changed the colour since Retro set it: the label is the app's again (review I2).
                if colour != given { forget(label) }
            } else if Self.systemLabelColours.contains(colour) {
                let retro = colour == .secondaryLabelColor || colour == .tertiaryLabelColor
                    ? NSColor(RetroTheme.secondaryText) : NSColor(RetroTheme.text)
                originalColours.setObject(colour, forKey: label)
                retroColours.setObject(retro, forKey: label)
                label.textColor = retro
            }
        }
        // Tables, text views and the art keep their own backgrounds.
        if view is NSTableView || view is NSTextView || view is NSScrollView && (view as? NSScrollView)?.documentView is NSTableView { return }
        for sub in view.subviews { recolour(sub) }
    }

    private func forget(_ label: NSTextField) {
        originalColours.removeObject(forKey: label)
        retroColours.removeObject(forKey: label)
    }

    /// Labels still in the colour Retro gave them get their own colour back.
    private func restore(_ view: NSView) {
        if let label = view as? NSTextField, let given = retroColours.object(forKey: label) {
            if label.textColor == given { label.textColor = originalColours.object(forKey: label) }
            forget(label)
        }
        for sub in view.subviews { restore(sub) }
    }

    /// Whether Retro has recoloured `label` (for the harness).
    func isRecoloured(_ label: NSTextField) -> Bool { retroColours.object(forKey: label) != nil }

    /// The bundled IBM VGA font at its pixel size (16 points), registered for this process once.
    static let vgaFont: NSFont? = {
        guard let url = BitmapFont.fontFileURL("IBM VGA") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontCreateWithFontDescriptor(first, 16, nil) as NSFont
    }()
}

/// A glossary (?) hint in SwiftUI (wraps `Hint.button`).
struct HintView: NSViewRepresentable {
    let term: GlossaryTerm
    var detail: String?

    func makeNSView(context: Context) -> HintButton { Hint.button(term, detail: detail) }
    func updateNSView(_ nsView: HintButton, context: Context) {}
}

/// AnsiView > Settings: the appearance (the only app wide preference with no menu of its own).
struct SettingsView: View {
    @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Appearance:", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.rawValue) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .help("How AnsiView's own windows look. The art is always drawn in its own colours.")
                HStack(alignment: .top, spacing: 6) {
                    Text((AppAppearance(rawValue: appearance) ?? .system).summary)
                        .font(.callout)
                        .foregroundStyle(appearance == AppAppearance.retro.rawValue ? Color(nsColor: NSColor(RetroTheme.secondaryText)) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HintView(term: .appearance)
                        .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(appearance == AppAppearance.retro.rawValue ? .hidden : .automatic)
        .background(appearance == AppAppearance.retro.rawValue ? Color(nsColor: NSColor(RetroTheme.background)) : Color.clear)
        .frame(width: 460)
        .onChange(of: appearance) { _ in AppearanceController.shared.apply() }
    }
}
