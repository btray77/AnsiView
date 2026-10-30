import Foundation

/// How screens are written for one BBS install (screen designer ruling 6): the package, the
/// install folder (a security scoped bookmark the app keeps), encoding, colour codes, line ends
/// and SAUCE. Saved as JSON with the app's settings.
public struct ExportProfile: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var package: BBSPackage
    /// App scoped security bookmark of the BBS folder (chosen in the open panel).
    public var folderBookmark: Data?
    /// The folder's path when it was chosen, shown in the sheet.
    public var folderPath: String?
    /// Replaces the package's theme folder ("default" for Mystic, "mytheme" for ENiGMA).
    public var themeName: String
    public var encoding: TextEncoding
    public var colourCodes: ColourCodeMode
    public var lineEnding: LineEnding
    public var sauce: Bool
    /// Wide screens get the package's terminal width file name ("main.132col.ans").
    public var widthNames: Bool
    /// Baud the delays of animated screens are padded for.
    public var animationBaud: Int

    public init(id: UUID = UUID(), package: BBSPackage, name: String? = nil) {
        self.id = id
        self.package = package
        self.name = name ?? package.displayName
        themeName = ""
        encoding = .cp437
        // MECCA source cannot hold escape sequences ("[" starts a token), so Maximus writes its own tokens.
        colourCodes = package.definition.colours == .mecca ? .native : .ansi
        // Line ends are not documented by any package; CR LF is what DOS era files use (ruling 8).
        lineEnding = .crlf
        sauce = package.definition.files.readsSauce
        widthNames = true
        animationBaud = 2400
    }

    var rules: ScreenFileRules { package.definition.files }

    public func isDocumented(_ slot: ScreenSlot) -> Bool { rules.slots[slot]?.source != nil }

    /// Where the documented name comes from, or nil for AnsiView's suggestion.
    public func nameSource(_ slot: ScreenSlot) -> String? { rules.slots[slot]?.source }

    static func slug(_ slot: ScreenSlot) -> String {
        switch slot {
        case .matrix: return "matrix"
        case .welcome: return "welcome"
        case .newUser: return "newuser"
        case .mainMenu: return "mainmenu"
        case .goodbye: return "goodbye"
        case .bulletinList: return "bulletin"
        case .messageHeader: return "msghdr"
        case .fileHeader: return "filehdr"
        case .doorMenu: return "doors"
        case .ad: return "bbsad"
        case .loading: return "loading"
        case .custom: return "screen"
        }
    }

    public var fileExtension: String {
        if encoding == .utf8, let utf8 = rules.utf8Extension { return utf8 }
        return colourCodes == .native ? rules.nativeExtension : rules.ansiExtension
    }

    /// The path inside the BBS folder for `slot` (or `customName` for a slot with no documented name).
    public func relativePath(slot: ScreenSlot, customName: String? = nil, columns: Int) -> String {
        var path: String
        if let documented = rules.slots[slot], customName?.isEmpty ?? true {
            path = documented.path
        } else {
            var base = (customName?.isEmpty ?? true) ? Self.slug(slot) : customName!
            base = String(base.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
            if base.isEmpty { base = Self.slug(slot) }
            if rules.eightDotThree { base = String(base.prefix(8)) }
            path = rules.folder.isEmpty ? base : rules.folder + "/" + base
        }
        if let theme = rules.themeFolder, !themeName.isEmpty {
            let clean = themeName.replacingOccurrences(of: "/", with: "")
            path = path.split(separator: "/").map { $0 == theme ? clean : String($0) }.joined(separator: "/")
        }
        let parts = path.split(separator: "/").map(String.init)
        var name = parts.last ?? "screen"
        if widthNames, columns != 80 {
            switch rules.widthSuffix {
            case .columnsCol: name += ".\(columns)col"
            case .cColumns: name += ".c\(columns)"
            case .none: break
            }
        }
        name += "." + fileExtension
        name = rules.nameCase == .upper ? name.uppercased() : name.lowercased()
        return (parts.dropLast() + [name]).joined(separator: "/")
    }
}

/// An exported screen: the bytes for the BBS folder and what the caller may see differently.
public struct ExportedScreen {
    public let data: Data
    public let relativePath: String
    public let warnings: [PreviewWarning]
    /// The bytes without SAUCE, as the BBS reads them (for the caller preview).
    public let body: [UInt8]
}

public enum ScreenExporter {
    /// Writes `project` for `profile`: one frame flattened (with the package's colour codes when
    /// asked), or an animation as ANSI with padding delays (ruling 5).
    public static func export(_ project: ArtProject, profile: ExportProfile, slot: ScreenSlot, customName: String? = nil,
                              date: Date = Date()) -> ExportedScreen {
        var warnings: [PreviewWarning] = []
        let canvas = project.frames[project.frames.count > 1 ? 0 : project.currentFrame].composite
        var body: [UInt8]
        if project.frames.count > 1 {
            if profile.colourCodes == .native {
                warnings.append(PreviewWarning(kind: .animatedAsANSI, message: "Animated: exported with ANSI colours, not \(profile.package.colourCodeName)."))
            }
            body = AnimationEncoder.encode(project.frames, options: AnimationExportOptions(baud: profile.animationBaud, date: date)).body
        } else if profile.colourCodes == .native {
            let native = BBSDisplay.nativeBody(canvas, package: profile.package)
            body = native.bytes
            if native.lossy {
                warnings.append(PreviewWarning(kind: .notRepresentable, message:
                    "Some colours cannot be sent with \(profile.package.colourCodeName); the nearest ones are used."))
            }
        } else {
            body = ArtWriter.ansiBody(canvas)
        }
        let foreign = BBSDisplay.foreignCodes(in: body, package: profile.package)
        for token in foreign {
            warnings.append(PreviewWarning(kind: .unsupportedCode, message: "\(token) is not a \(profile.package.displayName) code; callers see it as text."))
        }
        if canvas.iceColors {
            warnings.append(PreviewWarning(kind: .needsIce, message: "Uses bright backgrounds (iCE colours)."))
        }
        body = ScreenEncoding.lineEndings(body, profile.lineEnding)
        if profile.encoding == .utf8 {
            body = ScreenEncoding.utf8(fromCP437: body)
            if profile.package.definition.files.utf8Extension == nil {
                warnings.append(PreviewWarning(kind: .encodingUndocumented, message:
                    "UTF-8 display files are not documented for \(profile.package.displayName); CP437 is the safe choice."))
            }
        }
        var data = body
        if profile.sauce, let full = try? ArtWriter.data(canvas, format: .ansi, date: date) {
            let ansiCount = ArtWriter.ansiBody(canvas).count
            data += full[ansiCount...]
        }
        return ExportedScreen(data: Data(data), relativePath: profile.relativePath(slot: slot, customName: customName, columns: canvas.columns),
                              warnings: warnings, body: body)
    }
}
