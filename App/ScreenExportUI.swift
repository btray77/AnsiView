import AnsiCore
import AppKit
import UniformTypeIdentifiers

// Export profiles, Export to BBS, the screen set and Upload via Terminal (screen designer
// rulings 6, 7 and 11).

// MARK: - Export profiles

/// Screen > Export Profiles...: one profile per BBS install.
final class ExportProfilesWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var current: ExportProfilesWindowController?
    let viewController = ExportProfilesViewController()

    static func show(selecting id: UUID? = nil) {
        let controller = current ?? ExportProfilesWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if let id { controller.viewController.select(id) }
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Export Profiles"
        window.contentMinSize = NSSize(width: 760, height: 480)
        super.init(window: window)
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 900, height: 560))
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}

final class ExportProfilesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let settings = ScreenDesignerSettings.shared
    let table = NSTableView()
    let nameField = NSTextField(string: "")
    lazy var packagePopup = ScreenDesigner.packagePopup(selected: .synchronet, tooltip: "The BBS package this install runs")
    let folderLabel = ScreenDesigner.label("No folder chosen", secondary: true)
    let themeField = NSTextField(string: "")
    let encodingPopup = NSPopUpButton()
    let coloursPopup = NSPopUpButton()
    let lineEndingPopup = NSPopUpButton()
    let sauceBox = NSButton(checkboxWithTitle: "Add a SAUCE record", target: nil, action: nil)
    let widthBox = NSButton(checkboxWithTitle: "Wide screens get the wide file name", target: nil, action: nil)
    let notesLabel = ScreenDesigner.label("", size: 11, secondary: true)
    let namesLabel = ScreenDesigner.label("", size: 11)
    private(set) var profiles: [ExportProfile] = []
    private var editing: ExportProfile?

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Profiles"
        column.width = 200
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let add = NSButton(title: "New", target: self, action: #selector(addProfile))
        add.toolTip = "A profile for another BBS install"
        let remove = NSButton(title: "Delete", target: self, action: #selector(deleteProfile))
        remove.toolTip = "Deletes the profile and its screen set (exported files stay in the BBS folder)"
        let left = ScreenDesigner.column([scroll, ScreenDesigner.row([add, remove])])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true

        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        themeField.placeholderString = "theme folder name"
        themeField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        themeField.toolTip = "Mystic and ENiGMA keep display files per theme; the folder of your theme"
        encodingPopup.addItems(withTitles: ["CP437 (DOS)", "UTF-8"])
        encodingPopup.toolTip = "CP437 is what DOS era packages read; UTF-8 only where the package documents it"
        lineEndingPopup.addItems(withTitles: LineEnding.allCases.map(\.label))
        lineEndingPopup.toolTip = "No BBS package documents its line ends; CR LF is what DOS era files use"
        coloursPopup.toolTip = String(localized: "ANSI escapes work on every package; the package's own codes keep files editable in its own tools")
        sauceBox.toolTip = "SAUCE records title, author and width. Synchronet and ENiGMA are documented to stop at it; others may show its bytes"
        widthBox.toolTip = "Synchronet main.132col.ans, Mystic main.c132.ans: the BBS shows them to callers with that width"
        let choose = NSButton(title: "Choose Folder...", target: self, action: #selector(chooseFolder))
        choose.toolTip = "The BBS install folder (or a mounted share of it). AnsiView keeps permission to write there."
        for control in [nameField, themeField] as [NSControl] { control.target = self; control.action = #selector(formChanged) }
        for control in [packagePopup, encodingPopup, coloursPopup, lineEndingPopup, sauceBox, widthBox] as [NSControl] {
            control.target = self
            control.action = #selector(formChanged)
        }
        let help = TextArtImages.helpButton(
            "A profile says how screens are written for one BBS install: the package (which decides the file names and codes), the install folder, the theme folder for packages with themes, the character set, whether colours are ANSI escapes or the package's own codes, line ends and SAUCE. Names marked \"suggested\" are not documented by the package; set the same name in your BBS's menu configuration.",
            term: .bbsPackage)
        let grid = NSGridView(views: [
            [ScreenDesigner.label("Name:"), nameField],
            [ScreenDesigner.label("BBS package:"), packagePopup],
            [ScreenDesigner.label("BBS folder:"), ScreenDesigner.row([choose, folderLabel])],
            [ScreenDesigner.label("Theme:"), themeField],
            [ScreenDesigner.label("Characters:"), encodingPopup],
            [ScreenDesigner.label("Colours:"), coloursPopup],
            [ScreenDesigner.label("Line ends:"), lineEndingPopup],
            [NSView(), sauceBox],
            [NSView(), widthBox],
        ])
        grid.rowSpacing = 8
        notesLabel.preferredMaxLayoutWidth = 560
        namesLabel.preferredMaxLayoutWidth = 560
        namesLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let right = ScreenDesigner.column([ScreenDesigner.row([ScreenDesigner.label("Profile", size: 14), NSView(), help]), grid, notesLabel, namesLabel], spacing: 10)
        let split = ScreenDesigner.row([left, right], spacing: 16)
        split.alignment = .top
        split.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view = ScreenDesigner.container(split)
        reload()
    }

    func reload() {
        profiles = settings.profiles
        table.reloadData()
        if let editing, let i = profiles.firstIndex(where: { $0.id == editing.id }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        } else if !profiles.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        load()
    }

    func select(_ id: UUID) {
        if let i = profiles.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }
        load()
    }

    /// Fills the form from the selected profile.
    func load() {
        let selected = table.selectedRow >= 0 && table.selectedRow < profiles.count ? profiles[table.selectedRow] : nil
        editing = selected
        for control in [nameField, packagePopup, themeField, encodingPopup, coloursPopup, lineEndingPopup, sauceBox, widthBox] as [NSControl] {
            control.isEnabled = selected != nil
        }
        guard let p = selected else { notesLabel.stringValue = "Click New to make a profile for your BBS."; namesLabel.stringValue = ""; return }
        nameField.stringValue = p.name
        packagePopup.selectItem(at: BBSPackage.allCases.firstIndex(of: p.package) ?? 0)
        folderLabel.stringValue = p.folderPath ?? "No folder chosen"
        themeField.stringValue = p.themeName
        themeField.isEnabled = p.package.definition.files.themeFolder != nil
        encodingPopup.selectItem(at: p.encoding == .utf8 ? 1 : 0)
        coloursPopup.removeAllItems()
        // Only packages with colour codes of their own offer them (review fix).
        coloursPopup.addItems(withTitles: ColourCodeMode.modes(for: p.package).map { $0.label(p.package) })
        coloursPopup.selectItem(at: p.colourCodes == .native && ColourCodeMode.modes(for: p.package).contains(.native) ? 1 : 0)
        coloursPopup.toolTip = "ANSI escapes work on every package; the package's own codes keep files editable in its own tools"
        lineEndingPopup.selectItem(at: p.lineEnding == .lf ? 1 : 0)
        sauceBox.state = p.sauce ? .on : .off
        widthBox.state = p.widthNames ? .on : .off
        let rules = p.package.definition.files
        notesLabel.stringValue = rules.notes + "\nSources: " + p.package.source
        namesLabel.stringValue = ScreenSlot.allCases.filter { $0 != .custom }.map { slot in
            let path = p.relativePath(slot: slot, columns: 80)
            return "\(slot.label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(path)\(p.isDocumented(slot) ? "" : "   (suggested)")"
        }.joined(separator: "\n")
    }

    @objc func formChanged() {
        guard var p = editing else { return }
        let package = ScreenDesigner.package(of: packagePopup)
        let typedName = nameField.stringValue
        if package != p.package {
            // A new package starts from its defaults (SAUCE, colour codes), keeping the user's own name.
            let fresh = ExportProfile(id: p.id, package: package)
            let renamed = !BBSPackage.allCases.map(\.displayName).contains(typedName) && !typedName.isEmpty
            p.package = package
            p.sauce = fresh.sauce
            p.colourCodes = fresh.colourCodes
            p.name = renamed ? typedName : package.displayName
        } else {
            p.name = typedName.isEmpty ? package.displayName : typedName
            p.sauce = sauceBox.state == .on
            p.colourCodes = coloursPopup.indexOfSelectedItem == 1 ? .native : .ansi
        }
        p.themeName = themeField.stringValue
        p.encoding = encodingPopup.indexOfSelectedItem == 1 ? .utf8 : .cp437
        p.lineEnding = lineEndingPopup.indexOfSelectedItem == 1 ? .lf : .crlf
        p.widthNames = widthBox.state == .on
        settings.saveProfile(p)
        editing = p
        reload()
    }

    @objc func addProfile() {
        let p = ExportProfile(package: settings.package)
        settings.saveProfile(p)
        editing = p
        reload()
    }

    @objc func deleteProfile() {
        guard let p = editing else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the profile \"\(p.name)\"?"
        alert.informativeText = "Its screen set is deleted too. Files already exported stay in the BBS folder."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.deleteProfile(p.id)
        editing = nil
        reload()
    }

    @objc func chooseFolder() {
        guard var p = editing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the \(p.package.displayName) install folder (the one holding \(p.package.definition.files.folder.isEmpty ? "its display files" : p.package.definition.files.folder.split(separator: "/").first.map(String.init) ?? "")). Screens are written below it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        p.folderBookmark = TransferFolders.bookmark(url)
        p.folderPath = url.path
        settings.saveProfile(p)
        editing = p
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = profiles[row]
        let label = ScreenDesigner.label("\(p.name)\n\(p.package.displayName)", size: 12)
        return label
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 36 }

    func tableViewSelectionDidChange(_ notification: Notification) { load() }
}

// MARK: - Export to BBS

enum ScreenExportController {
    /// Screen > Export to BBS...
    static func exportFocusedEditor() {
        guard let editor = ScreenDesigner.requireEditor("export") else { return }
        let settings = ScreenDesignerSettings.shared
        guard !settings.profiles.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Make an export profile first"
            alert.informativeText = "A profile names your BBS package and its install folder. Screen > Export Profiles... opens with a new one."
            alert.runModal()
            ExportProfilesWindowController.show()
            ExportProfilesWindowController.current?.viewController.addProfile()
            return
        }
        guard let choice = ExportChooser.run(editor: editor) else { return }
        export(project: editor.editor.project, profile: choice.profile, slot: choice.slot, customName: choice.customName,
               source: editor.projectURL ?? editor.fileURL, window: editor.window)
    }

    /// Writes the screen into the profile's folder, asking before replacing; records it in the screen set.
    @discardableResult
    static func export(project: ArtProject, profile: ExportProfile, slot: ScreenSlot, customName: String?, source: URL?,
                       window: NSWindow?, quiet: Bool = false, entryID: UUID? = nil, exactPath: String? = nil) -> URL? {
        guard let folder = TransferFolders.resolve(profile.folderBookmark) else {
            let alert = NSAlert()
            alert.messageText = "Choose the BBS folder for \"\(profile.name)\""
            alert.informativeText = "Screen > Export Profiles..., then Choose Folder."
            alert.runModal()
            ExportProfilesWindowController.show(selecting: profile.id)
            return nil
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let exported = ScreenExporter.export(project, profile: profile, slot: slot, customName: customName, exactPath: exactPath)
        guard let relative = ScreenExportWriter.safeRelativePath(exported.relativePath) else {
            NSAlert(error: ScreenExportWriter.WriteError.unsafePath(exported.relativePath)).runModal()
            return nil
        }
        let target = folder.appendingPathComponent(relative)
        var replacing = false
        if let existing = ScreenExportWriter.conflict(at: target) {
            let alert = NSAlert()
            alert.messageText = "Replace \(relative)?"
            alert.informativeText = "The BBS folder already has this file (\(existing.size) bytes"
                + (existing.modified.map { ", changed " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "")
                + "). The old file is kept as \(target.lastPathComponent).bak."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            replacing = true
        }
        do {
            let result = try ScreenExportWriter.write(exported.data, to: target, replacing: replacing)
            var set = ScreenDesignerSettings.shared.screenSet(for: profile.id)
            var entry = set.entries.first { $0.id == entryID || $0.fileName.lowercased() == relative.lowercased() }
                ?? ScreenSetEntry(slot: slot, fileName: relative)
            entry.slot = slot
            entry.fileName = relative
            if let source {
                entry.sourcePath = source.path
                entry.sourceBookmark = TransferFolders.bookmark(source) ?? entry.sourceBookmark
            }
            entry.recordExport(file: exported.data, body: Data(exported.body), at: Date())
            set.upsert(entry)
            ScreenDesignerSettings.shared.saveScreenSet(set)
            ScreenDesignerSettings.shared.lastProfileID = profile.id
            if !quiet { showResult(result, relative: relative, exported: exported, profile: profile, documented: profile.isDocumented(slot) && customName == nil) }
            return target
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    private static func showResult(_ result: ScreenExportWriter.Result, relative: String, exported: ExportedScreen, profile: ExportProfile,
                                   documented: Bool) {
        let alert = NSAlert()
        alert.messageText = "Exported \(relative)"
        var lines = ["\(result.bytesWritten) bytes written to \(profile.name)" + (result.backupURL.map { "; the old file is \($0.lastPathComponent)" } ?? "") + "."]
        if !documented { lines.append("This name is AnsiView's suggestion: set it in your BBS's menu configuration.") }
        lines += exported.warnings.map { "\u{2022} " + $0.message }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Upload via Terminal...")
        if alert.runModal() == .alertSecondButtonReturn {
            ScreenUploader.upload(data: exported.data, fileName: (relative as NSString).lastPathComponent)
        }
    }

    /// Screen > Open with BBS Codes...: a file using a package's colour codes, as editable art.
    static func openWithCodes() {
        let panel = NSOpenPanel()
        panel.message = "Choose a display file that uses a BBS package's colour codes (pipe codes, Ctrl-A, @X ...)."
        let popup = ScreenDesigner.packagePopup(selected: ScreenDesignerSettings.shared.package, tooltip: "Whose codes the file uses")
        popup.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        panel.accessoryView = popup
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let package = ScreenDesigner.package(of: popup)
        let raw = [UInt8](data)
        let (sauce, length) = Sauce.read(raw)
        let ansi = BBSDisplay.render(Array(raw.prefix(length)), package: package, samples: nil)
        let screen = BBSDisplay.screen(ansi, columns: sauce?.columns ?? 80, iceColors: sauce?.iceColors ?? false)
        EditorWindowController.open(canvas: EditCanvas(screen: screen, iceColors: sauce?.iceColors ?? false),
                                    name: url.deletingPathExtension().lastPathComponent + " (\(package.displayName) codes)")
    }
}

/// The Export to BBS dialog: profile, slot and the resulting path.
final class ExportChooser: NSObject {
    struct Choice { var profile: ExportProfile; var slot: ScreenSlot; var customName: String? }

    let profiles = ScreenDesignerSettings.shared.profiles
    let profilePopup = NSPopUpButton()
    let slotPopup = NSPopUpButton()
    let nameField = NSTextField(string: "")
    let pathLabel = ScreenDesigner.label("", size: 11)
    let columns: Int

    init(columns: Int, slot: ScreenSlot?) {
        self.columns = columns
        super.init()
        for p in profiles { profilePopup.addItem(withTitle: "\(p.name) (\(p.package.displayName))") }
        if let last = ScreenDesignerSettings.shared.lastProfileID, let i = profiles.firstIndex(where: { $0.id == last }) { profilePopup.selectItem(at: i) }
        for s in ScreenSlot.allCases { slotPopup.addItem(withTitle: s.label) }
        slotPopup.selectItem(at: ScreenSlot.allCases.firstIndex(of: slot ?? .mainMenu) ?? 0)
        nameField.placeholderString = "file name (only for other screens)"
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        for control in [profilePopup, slotPopup, nameField] as [NSControl] { control.target = self; control.action = #selector(update) }
        pathLabel.preferredMaxLayoutWidth = 380
        update()
    }

    var profile: ExportProfile { profiles[max(0, profilePopup.indexOfSelectedItem)] }
    var slot: ScreenSlot { ScreenSlot.allCases[max(0, slotPopup.indexOfSelectedItem)] }

    @objc func update() {
        let p = profile
        let custom = nameField.stringValue.isEmpty ? nil : nameField.stringValue
        let path = p.relativePath(slot: slot, customName: custom, columns: columns)
        pathLabel.stringValue = "Writes \(path)\n" + (p.isDocumented(slot) && custom == nil
            ? "Documented name: \(p.nameSource(slot) ?? "")" : "Suggested name (not documented by \(p.package.displayName)).")
            + "\nInto: " + (p.folderPath ?? "no folder chosen yet")
    }

    static func run(editor: EditorWindowController) -> Choice? {
        let chooser = ExportChooser(columns: editor.editor.canvas.columns, slot: editor.screenSlot)
        let alert = NSAlert()
        alert.messageText = "Export to BBS"
        alert.informativeText = "Writes the screen into the BBS folder with the name the package shows for that screen."
        let grid = NSGridView(views: [[ScreenDesigner.label("Profile:"), chooser.profilePopup],
                                      [ScreenDesigner.label("Screen:"), chooser.slotPopup],
                                      [ScreenDesigner.label("Name:"), chooser.nameField],
                                      [NSView(), chooser.pathLabel]])
        grid.frame = NSRect(x: 0, y: 0, width: 480, height: 150)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        editor.screenSlot = chooser.slot
        return Choice(profile: chooser.profile, slot: chooser.slot, customName: chooser.nameField.stringValue.isEmpty ? nil : chooser.nameField.stringValue)
    }
}

// MARK: - Screen set

/// Screen > Screen Set...: every screen exported with a profile, with its status.
final class ScreenSetWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private(set) static var current: ScreenSetWindowController?
    let profilePopup = NSPopUpButton()
    let table = NSTableView()
    let summary = ScreenDesigner.label("", size: 11, secondary: true)
    private(set) var profiles: [ExportProfile] = []
    private(set) var rows: [(entry: ScreenSetEntry, status: ScreenSetStatus)] = []
    private var observer: NSObjectProtocol?

    static func show() {
        let controller = current ?? ScreenSetWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.reload()
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 460),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Screen Set"
        super.init(window: window)
        window.delegate = self
        profilePopup.target = self
        profilePopup.action = #selector(reloadNow)
        profilePopup.toolTip = "The BBS install whose screens are listed"
        for (id, title, width) in [("slot", "Screen", 180.0), ("file", "File in the BBS folder", 260.0), ("status", "Status", 300.0), ("source", "Source", 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let again = NSButton(title: "Export Again", target: self, action: #selector(exportAgain))
        again.toolTip = "Exports the selected screen from its source again (asks before replacing)"
        let upload = NSButton(title: "Upload via Terminal...", target: self, action: #selector(upload))
        upload.toolTip = "Sends the exported file to the BBS with the dialing directory entry's protocol"
        let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(reveal))
        reveal.toolTip = String(localized: "Shows the exported file in the BBS folder")
        let remove = NSButton(title: "Remove", target: self, action: #selector(remove))
        remove.toolTip = "Removes the screen from the set (the file stays in the BBS folder)"
        let help = TextArtImages.helpButton(
            "The screen set lists which screen went to which BBS slot for this profile. Modified since export: the screen (its source file or open editor) changed. Changed in the BBS folder: the file there is not the one AnsiView wrote. Export Again rewrites it; the previous file is kept as .bak.",
            tooltip: "About the screen set")
        let top = ScreenDesigner.row([ScreenDesigner.label("Profile:"), profilePopup, NSView(), help])
        let bottom = ScreenDesigner.row([summary, NSView(), remove, reveal, upload, again])
        let stack = ScreenDesigner.column([top, scroll, bottom], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [top, scroll, bottom] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        window.contentView = ScreenDesigner.container(stack)
        window.center()
        observer = NotificationCenter.default.addObserver(forName: ScreenDesignerSettings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func windowWillClose(_ notification: Notification) { Self.current = nil }

    var profile: ExportProfile? { profiles.indices.contains(profilePopup.indexOfSelectedItem) ? profiles[profilePopup.indexOfSelectedItem] : nil }

    @objc func reloadNow() { reload() }

    func reload() {
        let settings = ScreenDesignerSettings.shared
        let selected = profile?.id ?? settings.lastProfileID
        profiles = settings.profiles
        profilePopup.removeAllItems()
        for p in profiles { profilePopup.addItem(withTitle: "\(p.name) (\(p.package.displayName))") }
        if let selected, let i = profiles.firstIndex(where: { $0.id == selected }) { profilePopup.selectItem(at: i) }
        guard let profile else { rows = []; table.reloadData(); summary.stringValue = "No export profiles yet."; return }
        let folder = TransferFolders.resolve(profile.folderBookmark)
        let scoped = folder?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { folder?.stopAccessingSecurityScopedResource() } }
        rows = settings.screenSet(for: profile.id).entries.map { entry in
            let inFolder = folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent(entry.fileName)) }
            let current = Self.source(of: entry).map { project in
                Data(ScreenExporter.export(project, profile: profile, slot: entry.slot, customName: nil).body)
            }
            return (entry, ScreenSet.status(entry, current: current, inFolder: inFolder))
        }
        let pending = rows.filter { $0.status.needsExport }.count
        summary.stringValue = "\(rows.count) screens, \(pending) need exporting. Folder: \(profile.folderPath ?? "not chosen")"
        table.reloadData()
    }

    /// The screen's source: an open editor showing that file, else the file itself.
    static func source(of entry: ScreenSetEntry) -> ArtProject? {
        guard let path = entry.sourcePath else { return nil }
        for window in NSApp.windows {
            if let editor = window.windowController as? EditorWindowController,
               editor.projectURL?.path == path || editor.fileURL?.path == path {
                return editor.editor.project
            }
        }
        let url = TransferFolders.resolve(entry.sourceBookmark) ?? URL(fileURLWithPath: path)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == ArtProject.fileExtension { return try? ArtProject(data: data) }
        let canvas = EditCanvas(file: ArtFile(data: data, fileExtension: url.pathExtension))
        return ArtProject(layers: [CanvasLayer(name: "Background", canvas: canvas)])
    }

    private var selected: ScreenSetEntry? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].entry : nil }

    @objc func exportAgain() {
        guard let entry = selected, let profile else { NSSound.beep(); return }
        guard let project = Self.source(of: entry) else {
            let alert = NSAlert()
            alert.messageText = "The source of \(entry.fileName) cannot be read"
            alert.informativeText = "Open the screen in the editor and use Screen > Export to BBS... again."
            alert.runModal()
            return
        }
        let source = entry.sourcePath.map { URL(fileURLWithPath: $0) }
        // Exactly the file the set names, not a name rebuilt from it (review fix).
        ScreenExportController.export(project: project, profile: profile, slot: entry.slot, customName: nil, source: source,
                                      window: window, entryID: entry.id, exactPath: entry.fileName)
        reload()
    }

    @objc func upload() {
        guard let entry = selected, let profile, let folder = TransferFolders.resolve(profile.folderBookmark) else { NSSound.beep(); return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(entry.fileName)) else { NSSound.beep(); return }
        ScreenUploader.upload(data: data, fileName: (entry.fileName as NSString).lastPathComponent)
    }

    @objc func reveal() {
        guard let entry = selected, let profile, let folder = TransferFolders.resolve(profile.folderBookmark) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(entry.fileName)])
    }

    @objc func remove() {
        guard let entry = selected, let profile else { return }
        var set = ScreenDesignerSettings.shared.screenSet(for: profile.id)
        set.entries.removeAll { $0.id == entry.id }
        ScreenDesignerSettings.shared.saveScreenSet(set)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let (entry, status) = rows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "slot": text = entry.slot.label
        case "file": text = entry.fileName
        case "status": text = (status.needsExport ? "\u{25CF} " : "\u{2713} ") + status.label
        default: text = entry.sourcePath.map { ($0 as NSString).lastPathComponent } ?? "(unsaved screen)"
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        if tableColumn?.identifier.rawValue == "status" { label.textColor = status.needsExport ? .systemOrange : .labelColor }
        return label
    }
}

// MARK: - Upload via Terminal

/// Sends an exported screen to the BBS through the terminal's file transfers (ruling 11).
enum ScreenUploader {
    static func upload(data: Data, fileName: String) {
        let entries = DialingDirectoryStore.shared.directory.entries
        guard !entries.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Add your BBS to the dialing directory first"
            alert.informativeText = "Upload via Terminal connects with a dialing directory entry and uses its file transfer protocol."
            alert.runModal()
            DialingDirectoryWindowController.show()
            return
        }
        let popup = NSPopUpButton()
        for entry in entries { popup.addItem(withTitle: "\(entry.name)  (\(entry.transferProtocol.displayName))") }
        popup.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        let alert = NSAlert()
        alert.messageText = "Upload \(fileName) to which BBS?"
        alert.informativeText = "AnsiView connects (or uses the open terminal), then waits for you to start the upload on the BBS."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entry = entries[popup.indexOfSelectedItem]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Screen Uploads/\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let terminal = TerminalWindowController.existing(for: entry.id) ?? TerminalWindowController.open(entry: entry)
        terminal.present()
        ScreenUploadPanel.show(file: file, terminal: terminal)
    }
}

/// "Start the upload on the BBS, then click Send": a small panel by the terminal.
final class ScreenUploadPanel: NSWindowController, NSWindowDelegate {
    private static var open: Set<ScreenUploadPanel> = []
    let file: URL
    weak var terminal: TerminalWindowController?
    let sendButton = NSButton(title: "Send", target: nil, action: nil)
    let status = ScreenDesigner.label("", size: 11, secondary: true)
    private var timer: Timer?

    static func show(file: URL, terminal: TerminalWindowController) {
        let panel = ScreenUploadPanel(file: file, terminal: terminal)
        open.insert(panel)
        panel.showWindow(nil)
    }

    init(file: URL, terminal: TerminalWindowController) {
        self.file = file
        self.terminal = terminal
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150), styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        window.title = "Upload Screen"
        window.isFloatingPanel = true
        super.init(window: window)
        let entry = terminal.terminal.entry
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let text = ScreenDesigner.label("Send \(file.lastPathComponent) (\(size) bytes) to \(entry.name) with \(entry.transferProtocol.displayName). Start the upload on the BBS first (for example the file area's Upload command or the SysOp's file editor), then click Send.")
        text.preferredMaxLayoutWidth = 420
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let stack = ScreenDesigner.column([text, ScreenDesigner.row([status, NSView(), cancel, sendButton])], spacing: 12)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        window.contentView = ScreenDesigner.container(stack)
        window.delegate = self
        if let frame = terminal.window?.frame { window.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 470, y: frame.maxY - 30)) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update() {
        let connected = terminal?.terminal.client?.state == .connected
        sendButton.isEnabled = connected
        status.stringValue = connected ? "Connected" : "Waiting for the connection..."
    }

    @objc func send() {
        guard let terminal else { cancel(); return }
        terminal.terminal.transfers.startUpload(files: [file], kind: terminal.terminal.entry.transferProtocol)
        finish()
    }

    @objc func cancel() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        finish()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        Self.open.remove(self)
    }

    private func finish() {
        timer?.invalidate()
        window?.close()
        Self.open.remove(self)
    }
}
