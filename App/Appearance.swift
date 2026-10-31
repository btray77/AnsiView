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
    /// Labels recoloured for Retro, with the colour they had.
    private let recoloured = NSMapTable<NSTextField, NSColor>.weakToStrongObjects()
    private let styledWindows = NSHashTable<NSWindow>.weakObjects()
    private var observing = false

    var current: AppAppearance { AppAppearance.current(in: defaults) }

    func choose(_ appearance: AppAppearance) {
        AppAppearance.set(appearance, in: defaults)
        apply()
    }

    /// Sets the app appearance and restyles every open window.
    func apply() {
        let appearance = current
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark, .retro: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        if !observing {
            observing = true
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
            }
        }
        for window in NSApp.windows { style(window) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    @objc private func windowChanged(_ note: Notification) {
        if let window = note.object as? NSWindow { style(window) }
    }

    /// Retro colours for a window, or the system ones back.
    func style(_ window: NSWindow) {
        guard !(window is NSPanel) || window.contentView?.subviews.isEmpty == false else { return }
        if current == .retro {
            window.backgroundColor = NSColor(RetroTheme.background)
            styledWindows.add(window)
            if let content = window.contentView { recolour(content) }
        } else if styledWindows.contains(window) {
            window.backgroundColor = .windowBackgroundColor
            styledWindows.remove(window)
            restore()
        }
    }

    /// Plain labels (not editable, no background of their own) get the Retro text colours.
    private func recolour(_ view: NSView) {
        // Only labels in system colours: a label given its own colour (the editor's yellow status
        // line, warning text) keeps it.
        if let label = view as? NSTextField, !label.isEditable, !label.drawsBackground, !label.isBezeled,
           recoloured.object(forKey: label) != nil || (label.textColor ?? .labelColor).type == .catalog {
            if recoloured.object(forKey: label) == nil { recoloured.setObject(label.textColor ?? .labelColor, forKey: label) }
            let original = recoloured.object(forKey: label) ?? .labelColor
            label.textColor = original == .secondaryLabelColor || original == .tertiaryLabelColor
                ? NSColor(RetroTheme.secondaryText) : NSColor(RetroTheme.text)
        }
        // Tables, text views and the art keep their own backgrounds.
        if view is NSTableView || view is NSTextView || view is NSScrollView && (view as? NSScrollView)?.documentView is NSTableView { return }
        for sub in view.subviews { recolour(sub) }
    }

    private func restore() {
        let enumerator = recoloured.keyEnumerator()
        var labels: [NSTextField] = []
        while let label = enumerator.nextObject() as? NSTextField { labels.append(label) }
        for label in labels where !(label.window.map(styledWindows.contains) ?? false) {
            label.textColor = recoloured.object(forKey: label)
            recoloured.removeObject(forKey: label)
        }
    }

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
