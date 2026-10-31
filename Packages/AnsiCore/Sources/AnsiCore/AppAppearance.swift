import Foundation

/// How AnsiView's own windows look (final gaps ruling 9). The art is never recoloured.
public enum AppAppearance: String, CaseIterable {
    case system, light, dark, retro

    public static let defaultsKey = "AppAppearance"

    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .retro: return "Retro"
        }
    }

    /// One line for the Settings window.
    public var summary: String {
        switch self {
        case .system: return "Follows the macOS light or dark setting."
        case .light: return "Always light, whatever macOS uses."
        case .dark: return "Always dark, whatever macOS uses."
        case .retro: return "DOS and BBS inspired: dark controls on deep blue, light grey text, yellow highlights, VGA font status lines."
        }
    }

    /// Retro is built on the dark system appearance so every control stays legible.
    public var isDarkBased: Bool { self == .dark || self == .retro }

    public static func current(in defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    public static func set(_ value: AppAppearance, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: defaultsKey)
    }
}

/// WCAG 2.x contrast ratio of two sRGB colours (1 to 21).
public enum Contrast {
    public static func luminance(_ c: RGB) -> Double {
        func channel(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// The Retro appearance's colours: an original palette after the DOS text screen (deep blue,
/// light grey, yellow, cyan), darkened or lightened so every text pair passes WCAG AA (4.5:1).
public enum RetroTheme {
    /// Window background: deep DOS blue.
    public static let background = RGB(r: 0x00, g: 0x00, b: 0x80)
    /// Status bars and toolbars: a darker blue.
    public static let chrome = RGB(r: 0x00, g: 0x00, b: 0x58)
    /// Body text: light grey.
    public static let text = RGB(r: 0xD0, g: 0xD0, b: 0xD0)
    /// Secondary text (notes, captions): a soft lavender grey.
    public static let secondaryText = RGB(r: 0xA8, g: 0xA8, b: 0xD8)
    /// Headings and the status line: bright white.
    public static let strongText = RGB(r: 0xFF, g: 0xFF, b: 0xFF)
    /// Highlights: DOS yellow.
    public static let accent = RGB(r: 0xFF, g: 0xFF, b: 0x55)
    /// Mode indicators: DOS cyan.
    public static let info = RGB(r: 0x55, g: 0xFF, b: 0xFF)
    /// Selected rows: cyan with black text.
    public static let selection = RGB(r: 0x00, g: 0xAA, b: 0xAA)
    public static let selectionText = RGB(r: 0x00, g: 0x00, b: 0x00)

    /// Every text colour with every background it is used on.
    public static let textPairs: [(text: RGB, textName: String, background: RGB, backgroundName: String)] = {
        let texts = [(text, "text"), (secondaryText, "secondary text"), (strongText, "strong text"), (accent, "accent"), (info, "info")]
        let backgrounds = [(background, "background"), (chrome, "chrome")]
        var pairs: [(RGB, String, RGB, String)] = []
        for (t, tn) in texts { for (b, bn) in backgrounds { pairs.append((t, tn, b, bn)) } }
        pairs.append((selectionText, "selection text", selection, "selection"))
        // The editor's retro chrome (VGA blue #0000AA) with its status (yellow), hint (white) and mode (cyan) labels.
        let editorBlue = RGB(r: 0x00, g: 0x00, b: 0xAA)
        for (t, tn) in [(accent, "editor status"), (strongText, "editor hint"), (info, "editor mode")] {
            pairs.append((t, tn, editorBlue, "editor chrome"))
        }
        return pairs
    }()
}

extension BitmapFont {
    /// The TrueType file of a bundled pixel font (for showing labels in it); nil when not bundled.
    public static func fontFileURL(_ name: String) -> URL? {
        guard let entry = catalog[name] else { return nil }
        return Bundle.module.url(forResource: entry.file, withExtension: "ttf", subdirectory: "Fonts")
    }
}
