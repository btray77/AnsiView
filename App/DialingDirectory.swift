import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// The dialing directory in the app's own user defaults (not the suite shared with Quick Look),
/// with passwords in the Keychain (ruling 3).
final class DialingDirectoryStore {
    static let shared = DialingDirectoryStore()
    static let changed = Notification.Name("DialingDirectoryChanged")

    let defaults: UserDefaults
    let passwords: PasswordStore
    private(set) var directory: DialingDirectory

    init(defaults: UserDefaults = .standard, passwords: PasswordStore = KeychainPasswordStore()) {
        self.defaults = defaults
        self.passwords = passwords
        let stored = defaults.data(forKey: DialingDirectory.defaultsKey)
        let loaded = DialingDirectory.load(stored: stored, legacy: defaults.data(forKey: BBSAddressBook.defaultsKey))
        directory = loaded.directory
        // Data this build cannot read is kept aside before anything is saved over it.
        if loaded.unreadable, let stored, defaults.data(forKey: Self.unreadableKey) == nil {
            defaults.set(stored, forKey: Self.unreadableKey)
        }
    }

    static let unreadableKey = DialingDirectory.defaultsKey + ".unreadable"

    func update(_ change: (inout DialingDirectory) -> Void) {
        change(&directory)
        defaults.set(directory.encoded(), forKey: DialingDirectory.defaultsKey)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func entry(_ id: UUID) -> BBSEntry? { directory.entries.first { $0.id == id } }

    func password(for entry: BBSEntry) -> String {
        entry.credentialKey.flatMap { passwords.password(for: $0) } ?? ""
    }

    /// The SSH key file passphrase (Keychain), or "".
    func passphrase(for entry: BBSEntry) -> String {
        entry.sshPassphraseKey.flatMap { passwords.password(for: $0) } ?? ""
    }

    enum SaveProblem: LocalizedError {
        case badAddress
        case passwordNeedsUsername
        case keychain(Error)

        var errorDescription: String? {
            switch self {
            case .badAddress: return "Enter a host name or address, and a port from 1 to 65535."
            case .passwordNeedsUsername: return "A password needs a username. Type the username first."
            case .keychain(let error): return error.localizedDescription
            }
        }
    }

    /// Checks an edited entry: the host parsed (host:port typed in Host is split), size clamped,
    /// a name given.
    func validated(_ draft: BBSEntry, password: String) throws -> BBSEntry {
        var entry = draft
        guard let parsed = BBSAddress.parse(entry.host, defaultPort: entry.port) else { throw SaveProblem.badAddress }
        entry.host = parsed.host
        entry.port = parsed.port
        if entry.name.trimmingCharacters(in: .whitespaces).isEmpty { entry.name = entry.host }
        if !password.isEmpty, entry.credentialKey == nil { throw SaveProblem.passwordNeedsUsername }
        return entry
    }

    /// Saves an entry (new or edited) and its password. The Keychain item follows a change of
    /// host, port or username; an empty password removes it.
    func save(_ draft: BBSEntry, password: String, passphrase: String = "", original: BBSEntry?) throws {
        // Calls recorded while the editor was open are kept.
        let entry = directory.keepingHistory(try validated(draft, password: password))
        if !passphrase.isEmpty, entry.sshPassphraseKey == nil { throw SaveProblem.passwordNeedsUsername }
        do {
            try DialingDirectory.saveCredential(password: password, for: entry, original: original, in: directory, store: passwords)
            try savePassphrase(passphrase, for: entry, original: original)
        } catch {
            throw SaveProblem.keychain(error)
        }
        update { d in
            if let index = d.entries.firstIndex(where: { $0.id == entry.id }) { d.entries[index] = entry } else { d.entries.append(entry) }
        }
    }

    /// The SSH key passphrase follows the entry's host, port and username like the password; it is
    /// written to the new key before the old one is removed. One per entry (not shared).
    private func savePassphrase(_ passphrase: String, for entry: BBSEntry, original: BBSEntry?) throws {
        let key = entry.sshPassphraseKey
        if let key {
            if passphrase.isEmpty {
                if passwords.password(for: key) != nil, original?.sshPassphraseKey == key { try passwords.removePassword(for: key) }
            } else if passwords.password(for: key) != passphrase {
                try passwords.setPassword(passphrase, for: key, label: "AnsiView SSH key: \(entry.name)")
            }
        }
        if let old = original?.sshPassphraseKey, old != key, passwords.password(for: old) != nil {
            try passwords.removePassword(for: old)
        }
    }

    /// Deletes entries and their Keychain items (unless another entry uses the same account).
    func delete(_ ids: [UUID]) {
        let gone = Set(ids)
        let removed = directory.entries.filter { gone.contains($0.id) }
        update { d in d.entries.removeAll { gone.contains($0.id) } }
        for entry in removed {
            if let key = entry.credentialKey, !directory.sharesCredential(key, excluding: entry.id) {
                try? passwords.removePassword(for: key)
            }
            if let key = entry.sshPassphraseKey, passwords.password(for: key) != nil,
               !directory.entries.contains(where: { $0.sshPassphraseKey == key }) {
                try? passwords.removePassword(for: key)
            }
        }
    }

    func recordCall(_ id: UUID) {
        update { $0.recordCall(id, at: Date()) }
    }

    /// Imports an AnsiView export, a plan 7 address book, or a SyncTERM `syncterm.lst`.
    /// SyncTERM passwords go into the Keychain. Returns a summary for the user.
    func importFile(_ data: Data) throws -> String {
        if let entries = try? DialingDirectory.importEntries(from: data) {
            var result: (added: [BBSEntry], skipped: Int) = ([], 0)
            update { result = $0.merge(entries) }
            return "Imported \(result.added.count) BBSes" + (result.skipped > 0 ? "; \(result.skipped) were already in the directory." : ".")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.contains("[") else { throw DialingDirectory.ImportError.unreadable }
        let parsed = SyncTermImport.parse(text)
        guard !parsed.entries.isEmpty || !parsed.skipped.isEmpty else { throw DialingDirectory.ImportError.unreadable }
        var added = 0, duplicates = 0
        var unsaved: [String] = []
        for item in parsed.entries {
            var result: (added: [BBSEntry], skipped: Int) = ([], 0)
            update { result = $0.merge([item.entry]) }
            duplicates += result.skipped
            guard let entry = result.added.first else { continue }
            added += 1
            guard let password = item.password else { continue }
            if let key = entry.credentialKey,
               (try? passwords.setPassword(password, for: key, label: "AnsiView BBS: \(entry.name)")) != nil {
                continue
            }
            unsaved.append(entry.name)
        }
        var summary = "Imported \(added) BBSes from the SyncTERM directory."
        if duplicates > 0 { summary += " \(duplicates) were already here." }
        if !unsaved.isEmpty {
            summary += " Passwords not saved (no username, or the Keychain refused): " + unsaved.joined(separator: ", ") + "."
        }
        if !parsed.skipped.isEmpty {
            summary += " Not imported (AnsiView speaks telnet and raw TCP only): " + parsed.skipped.joined(separator: ", ") + "."
        }
        return summary
    }
}

/// The dialing directory window: the retro list, the retro entry editor and the settings screen,
/// under a native toolbar with tooltips (ruling 14).
final class DialingDirectoryViewController: NSViewController {
    enum Mode {
        case browse
        case edit(form: TextForm, draft: BBSEntry, original: BBSEntry?)
        case settings(TextForm)
    }

    let store: DialingDirectoryStore
    let retro = RetroScreenView()
    private(set) var browser = DirectoryBrowser()
    private(set) var mode = Mode.browse
    /// Dials entries (the app starts a `DialSession`; the harness may replace it).
    var dial: ([BBSEntry]) -> Void
    /// Asks before deleting (off in the harness).
    var confirmsDeletes = true
    private var rowMap: [Int: Int] = [:]
    private let toolbar = NSStackView()
    private let quickField = NSTextField()
    private var browseButtons: [NSView] = []
    private var editButtons: [NSView] = []
    private var observer: NSObjectProtocol?

    init(store: DialingDirectoryStore, dial: (([BBSEntry]) -> Void)? = nil) {
        self.store = store
        self.dial = dial ?? { entries in DialSession.start(entries: entries, store: store) }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 660))
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        retro.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        container.addSubview(retro)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            retro.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            retro.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            retro.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            retro.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        buildToolbar()
        retro.onKey = { [weak self] key in self?.key(key) }
        retro.onClick = { [weak self] row, column, count in self?.click(row: row, column: column, count: count) }
        retro.onDrag = { [weak self] from, to in self?.drag(fromRow: from, toRow: to) }
        retro.onScroll = { [weak self] lines in self?.key(lines > 0 ? .up : .down) }
        retro.setAccessibilityLabel("Dialing directory")
        view = container
        observer = NotificationCenter.default.addObserver(forName: DialingDirectoryStore.changed, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func button(_ title: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = tip
        return button
    }

    private func buildToolbar() {
        browseButtons = [
            button("Dial", "Dial the marked BBSes (Space marks), or the selected one. Same as Enter.", #selector(dialSelected(_:))),
            button("New", "Add a BBS to the directory (N).", #selector(newEntry(_:))),
            button("Edit", "Edit the selected BBS: address, login, terminal settings and macros (E).", #selector(editSelected(_:))),
            button("Copy", "Duplicate the selected BBS, for a second account on the same board (C).", #selector(duplicateSelected(_:))),
            button("Delete", "Delete the marked or selected BBSes and their saved passwords (D).", #selector(deleteSelected(_:))),
            button("Sort", "Cycle the sort order: manual, name, address, last called, calls (S).", #selector(cycleSort(_:))),
            button("Tag", "Show only BBSes with a tag, one tag after another, then all (T).", #selector(cycleTag(_:))),
            button("Settings", "Global macros, redial passes and delay, and showing the directory at launch (G).", #selector(openSettings(_:))),
            button("Import...", "Import an AnsiView directory export or a SyncTERM syncterm.lst file (I).", #selector(importDirectory(_:))),
            button("Export...", "Save the directory to a JSON file. Passwords are never exported (X).", #selector(exportDirectory(_:))),
        ]
        quickField.placeholderString = "Quick connect: host or host:port"
        quickField.toolTip = "Type an address and press Return to call it without saving it, for example bbs.example.com:23."
        quickField.target = self
        quickField.action = #selector(quickConnect(_:))
        quickField.controlSize = .small
        quickField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        browseButtons.append(quickField)
        editButtons = [
            button("Save and Back", "Save this BBS and go back to the list. Same as Esc.", #selector(saveAndBack(_:))),
            button("Cancel", "Go back to the list without saving the changes.", #selector(cancelEdit(_:))),
        ]
        let help = NSButton(title: "?", target: self, action: #selector(showHelp(_:)))
        help.bezelStyle = .helpButton
        help.title = ""
        help.toolTip = "How login scripts and keyboard macros work."
        for view in browseButtons + editButtons { toolbar.addArrangedSubview(view) }
        toolbar.addArrangedSubview(help)
    }

    // MARK: Drawing

    func refresh() {
        let isBrowsing: Bool
        switch mode {
        case .browse:
            let rendered = browser.screen(in: store.directory)
            rowMap = rendered.entryAtRow
            retro.show(rendered.screen)
            isBrowsing = true
            view.window?.title = "Dialing Directory"
        case .edit(let form, _, _):
            let rendered = form.screen()
            rowMap = rendered.fieldAtRow
            retro.show(rendered.screen)
            isBrowsing = false
            view.window?.title = form.title
        case .settings(let form):
            let rendered = form.screen()
            rowMap = rendered.fieldAtRow
            retro.show(rendered.screen)
            isBrowsing = false
            view.window?.title = "Directory Settings"
        }
        for view in browseButtons { view.isHidden = !isBrowsing }
        for view in editButtons { view.isHidden = isBrowsing }
    }

    /// The text currently on the retro screen, for the harness.
    var screenText: [String] {
        let screen: AnsiScreen
        switch mode {
        case .browse: screen = browser.screen(in: store.directory).screen
        case .edit(let form, _, _), .settings(let form): screen = form.screen().screen
        }
        return screen.rows.map { String($0.map { Character(CP437.unicode[Int($0.code)]) }) }
    }

    // MARK: Keys and mouse

    func key(_ key: FormKey) {
        switch mode {
        case .browse:
            perform(browser.handle(key, in: store.directory))
        case .edit(var form, let draft, let original):
            let event = form.handle(key)
            mode = .edit(form: form, draft: draft, original: original)
            formEvent(event)
        case .settings(var form):
            let event = form.handle(key)
            mode = .settings(form)
            if event == .done { finishSettings() }
        }
        refresh()
    }

    private func click(row: Int, column: Int, count: Int) {
        switch mode {
        case .browse:
            perform(browser.click(row: row, count: count, map: rowMap, in: store.directory))
        case .edit(var form, let draft, let original):
            let event = form.click(row: row, map: rowMap)
            mode = .edit(form: form, draft: draft, original: original)
            formEvent(event)
        case .settings(var form):
            _ = form.click(row: row, map: rowMap)
            mode = .settings(form)
        }
        refresh()
    }

    private func drag(fromRow: Int, toRow: Int) {
        guard case .browse = mode, let from = rowMap[fromRow], let to = rowMap[toRow] else { return }
        perform(browser.drag(from: from, to: to, in: store.directory))
        refresh()
    }

    private func perform(_ event: DirectoryBrowser.Event) {
        switch event {
        case .none: break
        case .dial(let ids):
            let entries = ids.compactMap(store.entry)
            if !entries.isEmpty { dial(entries) }
        case .edit(let id): if let entry = store.entry(id) { beginEdit(entry, original: entry) }
        case .new: beginEdit(BBSEntry(name: "", host: ""), original: nil)
        case .duplicate(let id):
            var copy: BBSEntry?
            store.update { copy = $0.duplicate(id) }
            browser.select(copy?.id)
        case .delete(let ids): confirmDelete(ids)
        case .reorder(let ids, let before): store.update { $0.move(ids, before: before) }
        case .settings: mode = .settings(EntryForm.settings(store.directory))
        case .importFile: importDirectory(nil)
        case .exportFile: exportDirectory(nil)
        case .close: view.window?.performClose(nil)
        }
    }

    // MARK: Editing

    func beginEdit(_ entry: BBSEntry, original: BBSEntry?) {
        let form = EntryForm.make(entry: entry, password: store.password(for: entry), passphrase: store.passphrase(for: entry),
                                  fonts: BitmapFont.supportedNames, speeds: PlaybackSpeed.choices)
        mode = .edit(form: form, draft: entry, original: original)
        refresh()
    }

    private func formEvent(_ event: FormEvent) {
        guard case .edit(let form, let draft, let original) = mode else { return }
        switch event {
        case .done: save(form: form, draft: draft, original: original)
        case .changed(let id) where id == "emulation":
            // Size and the name sent follow the terminal type.
            rebuild(entry: EntryForm.changingEmulation(form, draft: draft), password: EntryForm.apply(form, to: draft).password,
                    original: original, selecting: id, from: form)
        case .changed(let id) where id == "mode" || id == "wsSecure" || id == "telnetSecure":
            // The protocol's own fields appear at once, and a default port follows the protocol.
            rebuild(entry: EntryForm.changingProtocol(form, draft: draft), password: EntryForm.apply(form, to: draft).password,
                    original: original, selecting: id, from: form)
        case .activated(let action):
            let applied = EntryForm.apply(form, to: draft)
            if action == "chooseKey" {
                chooseKeyFile(applied.entry, password: applied.password, form: form, original: original)
                return
            }
            if action == "forgetCertificate" {
                let entry = applied.entry
                let had = CertificatePrompt().forget(host: entry.host, port: entry.port)
                var shown = form
                shown.info = had ? "Forgot the saved certificate of \(entry.host):\(entry.port). The next call asks about it."
                    : "No certificate is saved for \(entry.host):\(entry.port)."
                mode = .edit(form: shown, draft: draft, original: original)
                refresh()
                return
            }
            if action == "forgetHostKey" {
                let entry = applied.entry
                let had = HostKeyPrompt().forget(host: entry.host, port: entry.port)
                var shown = form
                let address = KnownHosts.hostPattern(host: entry.host, port: entry.port)
                shown.info = had ? "Forgot the saved host key of \(address). The next call asks about its key."
                    : "No host key is saved for \(address)."
                mode = .edit(form: shown, draft: draft, original: original)
                refresh()
                return
            }
            if action == "chooseDownloadFolder" {
                guard let url = TransferFolders.ask(message: "Choose the download folder for this BBS. AnsiView remembers your permission to save there.") else { return }
                let (applied, password) = EntryForm.apply(form, to: draft)
                var entry = applied
                guard let bookmark = TransferFolders.bookmark(url), TransferFolders.writeCheck(url) == nil else {
                    var shown = form
                    shown.info = "AnsiView cannot save files in \(url.lastPathComponent). Choose another folder."
                    mode = .edit(form: shown, draft: draft, original: original)
                    refresh()
                    return
                }
                entry.downloadFolderBookmark = bookmark
                entry.downloadFolderName = (url.path as NSString).abbreviatingWithTildeInPath
                rebuild(entry: entry, password: password, original: original, selecting: "chooseDownloadFolder", from: form)
                return
            }
            if action == "chooseFolder" {
                chooseCaptureFolder { url in
                    guard let url, case .edit(let current, let draft, let original) = self.mode else { return }
                    let (applied, password) = EntryForm.apply(current, to: draft)
                    var entry = applied
                    guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                               relativeTo: nil) else {
                        var shown = current
                        shown.info = "AnsiView could not keep permission for \(url.lastPathComponent). Choose another folder."
                        self.mode = .edit(form: shown, draft: draft, original: original)
                        self.refresh()
                        return
                    }
                    entry.captureFolderBookmark = bookmark
                    entry.captureFolderName = (url.path as NSString).abbreviatingWithTildeInPath
                    self.rebuild(entry: entry, password: password, original: original, selecting: "chooseFolder", from: current)
                }
                return
            }
            rebuild(entry: EntryForm.perform(action, on: applied.entry), password: applied.password, original: original,
                    selecting: action, from: form)
        default: break
        }
    }

    private func rebuild(entry: BBSEntry, password: String, original: BBSEntry?, selecting id: String, from old: TextForm) {
        let passphrase = old.field("keyPassphrase") == nil ? store.passphrase(for: entry) : EntryForm.passphrase(old)
        var form = EntryForm.make(entry: entry, password: password, passphrase: passphrase, fonts: BitmapFont.supportedNames,
                                  speeds: PlaybackSpeed.choices)
        if let show = old.field("showPassword"), show.isOn, let index = form.fields.firstIndex(where: { $0.id == "showPassword" }) {
            form.fields[index].isOn = true
        }
        form.select(id: id)
        mode = .edit(form: form, draft: entry, original: original)
        refresh()
    }

    @objc func saveAndBack(_ sender: Any?) {
        guard case .edit(let form, let draft, let original) = mode else { return }
        save(form: form, draft: draft, original: original)
        refresh()
    }

    @objc func cancelEdit(_ sender: Any?) {
        mode = .browse
        refresh()
    }

    private func save(form: TextForm, draft: BBSEntry, original: BBSEntry?) {
        let (entry, password) = EntryForm.apply(form, to: draft)
        do {
            try store.save(entry, password: password, passphrase: EntryForm.passphrase(form), original: original)
            browser.select(entry.id)
            mode = .browse
        } catch {
            var shown = form
            shown.info = "Not saved: " + error.localizedDescription
            mode = .edit(form: shown, draft: draft, original: original)
        }
    }

    private func finishSettings() {
        guard case .settings(let form) = mode else { return }
        store.update { $0 = EntryForm.applySettings(form, to: $0) }
        mode = .browse
    }

    /// SSH key file: an open panel, an app scoped bookmark, and a check that AnsiView can use the key.
    private func chooseKeyFile(_ entry: BBSEntry, password: String, form: TextForm, original: BBSEntry?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose your SSH private key file (for example ~/.ssh/id_ed25519, not the .pub file)."
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url, case .edit(let current, let draft, let original) = self.mode else { return }
            var entry = EntryForm.apply(current, to: draft).entry
            let typedPassphrase = EntryForm.passphrase(current)
            guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) else {
                var shown = current
                shown.info = "AnsiView could not keep permission for \(url.lastPathComponent). Choose another file."
                self.mode = .edit(form: shown, draft: draft, original: original)
                self.refresh()
                return
            }
            entry.sshKeyBookmark = bookmark
            entry.sshKeyName = url.lastPathComponent
            self.rebuild(entry: entry, password: EntryForm.apply(current, to: draft).password, original: original,
                         selecting: "chooseKey", from: current)
            // Say soon when the key cannot be used (RSA, not a key, damaged); checked off the main thread.
            guard let data = try? Data(contentsOf: url) else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                var problem: SSHKeyFileError?
                do {
                    _ = try SSHKeyFile.parse(data, passphrase: typedPassphrase.isEmpty ? nil : typedPassphrase)
                } catch let error as SSHKeyFileError where error != .needsPassphrase && error != .wrongPassphrase {
                    problem = error
                } catch {}
                guard let problem else { return }
                DispatchQueue.main.async {
                    if case .edit(var shown, let d, let o) = self.mode {
                        shown.info = problem.message
                        self.mode = .edit(form: shown, draft: d, original: o)
                        self.refresh()
                    }
                }
            }
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private func chooseCaptureFolder(_ done: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder for automatic session captures."
        let finish: (NSApplication.ModalResponse) -> Void = { response in done(response == .OK ? panel.url : nil) }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    // MARK: Toolbar actions

    private var selected: UUID? { browser.selectedID(in: store.directory) }

    @objc func dialSelected(_ sender: Any?) { key(.enter) }
    @objc func newEntry(_ sender: Any?) { key(.character("n")) }
    @objc func editSelected(_ sender: Any?) { key(.character("e")) }
    @objc func duplicateSelected(_ sender: Any?) { key(.character("c")) }
    @objc func deleteSelected(_ sender: Any?) { key(.character("d")) }
    @objc func cycleSort(_ sender: Any?) { key(.character("s")) }
    @objc func cycleTag(_ sender: Any?) { key(.character("t")) }
    @objc func openSettings(_ sender: Any?) { key(.character("g")) }

    @objc func quickConnect(_ sender: Any?) {
        let text = quickField.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let parsed = BBSAddress.parse(text) else {
            NSSound.beep()
            quickField.toolTip = "\"\(text)\" is not an address. Try bbs.example.com or host:port."
            return
        }
        TerminalWindowController.open(entry: BBSEntry(name: parsed.host, host: parsed.host, port: parsed.port), store: store)
    }

    private func confirmDelete(_ ids: [UUID]) {
        let names = ids.compactMap(store.entry).map(\.name)
        guard !names.isEmpty else { return }
        guard confirmsDeletes else { store.delete(ids); return }
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Delete \(names[0])?" : "Delete \(names.count) BBSes?"
        alert.informativeText = "Their saved passwords are removed from the Keychain too (unless another entry uses the same account)."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.store.delete(ids) }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    @objc func importDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "lst") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose an AnsiView directory export (.json) or a SyncTERM syncterm.lst."
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let alert = NSAlert()
            do {
                alert.messageText = "Import finished"
                alert.informativeText = try self.store.importFile(Data(contentsOf: url))
            } catch {
                alert.messageText = "Could not import \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
            }
            alert.runModal()
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    @objc func exportDirectory(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AnsiView Dialing Directory.json"
        panel.message = "Passwords are not exported; they stay in this Mac's Keychain."
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try self.store.directory.exportData(ids: nil).write(to: url) } catch { NSAlert(error: error).runModal() }
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    static let helpText = """
    Login scripts: when the BBS answers, AnsiView waits for each step's prompt (for example login: or name), \
    then types what the step sends: your username, your password (from the Keychain), some text, or Return. \
    Case, spaces and colour codes are ignored, and | separates choices (login:|name:). A step that waits too \
    long stops the script and leaves the login to you. Terminal > Log In runs it again.

    Macros: in a terminal, Option-1 to Option-0 type a macro. Each BBS can have its own; empty keys use the \
    global macros (Settings). Write \\r for Return, \\e for Escape, \\t for Tab and \\xHH for any byte, for \
    example /who\\r.

    Keys here: arrows move, Enter dials (or goes to the next field), Space marks BBSes for a dial queue, \
    Left and Right change a choice, Esc saves and goes back.
    """

    @objc func showHelp(_ sender: Any?) {
        guard let sender = sender as? NSView else { return }
        let label = NSTextField(wrappingLabelWithString: Self.helpText)
        label.preferredMaxLayoutWidth = 420
        label.frame = NSRect(x: 12, y: 12, width: 420, height: label.fittingSize.height)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 444, height: label.frame.height + 24))
        content.view.addSubview(label)
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}

final class DialingDirectoryWindowController: NSWindowController, NSWindowDelegate {
    private static var current: DialingDirectoryWindowController?

    static func show(store: DialingDirectoryStore = .shared) {
        if let current {
            current.showWindow(nil)
            return
        }
        let controller = DialingDirectoryViewController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Dialing Directory"
        window.backgroundColor = .black
        window.minSize = NSSize(width: 640, height: 380)
        let windowController = DialingDirectoryWindowController(window: window)
        controller.view.frame = window.contentView?.bounds ?? .zero
        controller.view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(controller.view)
        windowController.contentController = controller
        window.delegate = windowController
        window.center()
        window.setFrameAutosaveName("Dialing Directory")
        current = windowController
        windowController.showWindow(nil)
        window.makeFirstResponder(controller.retro)
    }

    private var contentController: DialingDirectoryViewController?

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}
