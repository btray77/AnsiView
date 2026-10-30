import Foundation

/// The dialing directory's entry editor as a `TextForm` (ruling 14): every field with a hint,
/// built from an entry and applied back to it. The password is a separate value because it
/// lives in the Keychain, never in the entry.
public enum EntryForm {
    static let backspaceOptions = ["BS (8)", "DEL (127)"]

    /// `passphrase` is the SSH key file's passphrase (from the Keychain, like the password).
    public static func make(entry e: BBSEntry, password: String, passphrase: String = "", fonts: [String],
                            speeds: [Int]) -> TextForm {
        var fields: [FormField] = []
        let connection = "Connection"
        fields.append(.text("name", section: connection, label: "Name", hint: "Only a label for this BBS in the directory list. It is never sent to the BBS and need not match the host.", value: e.name, maxLength: 60))
        fields.append(.text("host", section: connection, label: "Host", hint: "The BBS's internet address, such as bbs.example.com or an IP address. You may also type host:port here.", value: e.host, maxLength: 255))
        fields.append(.number("port", section: connection, label: "Port", hint: "The TCP port the BBS listens on. Telnet BBSes usually use 23; some use 2323 or another number their sysop publishes.", value: e.port, range: 1...65535))
        fields.append(.choice("mode", section: connection, label: "Protocol", hint: "Telnet suits nearly every BBS. SSH and wss WebSocket are encrypted. RLogin logs in by name. Raw TCP sends bytes unchanged.", options: ConnectionMode.allCases.map(\.label), index: ConnectionMode.allCases.firstIndex(of: e.mode) ?? 0))
        fields.append(.text("tags", section: connection, label: "Tags", hint: "Groups for the directory's tag filter (press T there), separated by commas, for example: Favourites, Trade Wars games.", value: e.tags.joined(separator: ", "), maxLength: 200))
        fields.append(.text("notes", section: connection, label: "Notes", hint: "Anything you want to remember about this BBS. It shows under the directory list and the / search looks in it.", value: e.notes, maxLength: 300))
        fields += transportFields(e, passphrase: passphrase)

        let terminal = "Terminal"
        fields.append(.choice("emulation", section: terminal, label: "Terminal type", hint: "What the BBS expects: ANSI-BBS suits PC boards. Pick PETSCII, ATASCII, Viewdata, Apple II or Amiga for boards made for those computers. Size and font follow.", options: TerminalEmulation.allCases.map(\.label), index: TerminalEmulation.allCases.firstIndex(of: e.emulation) ?? 0))
        var types = e.emulation.terminalNames
        for name in BBSEntry.standardTerminalTypes where !types.contains(name) { types.append(name) }
        if !types.contains(e.terminalType) { types.append(e.terminalType) }
        fields.append(.choice("terminalType", section: terminal, label: "Terminal name sent", hint: "The name AnsiView gives first when the BBS asks what terminal you have (telnet TERMINAL-TYPE). It follows the terminal type; the others are offered if the BBS asks again.", options: types, index: types.firstIndex(of: e.terminalType) ?? 0))
        fields.append(.number("columns", section: terminal, label: "Columns", hint: "Screen width in characters. BBSes expect 80, a few support 132. The BBS is told the size when it asks (telnet NAWS).", value: e.columns, range: TerminalEmulator.sizeRange))
        fields.append(.number("rows", section: terminal, label: "Rows", hint: "Screen height in lines. 25 is the DOS standard; some BBSes use more lines when you offer them.", value: e.rows, range: TerminalEmulator.sizeRange))
        var fontNames = fonts
        if !fontNames.contains(e.fontName) { fontNames.append(e.fontName) }
        fields.append(.choice("font", section: terminal, label: "Font", hint: "The bitmap font the screen is drawn with. IBM VGA is the classic DOS look; the Amiga fonts suit Amiga boards.", options: fontNames, index: fontNames.firstIndex(of: e.fontName) ?? 0))
        fields.append(.choice("encoding", section: terminal, label: "Character set", hint: "CP437 is the DOS character set nearly every BBS uses for ANSI art. Choose UTF-8 only for a BBS that sends Unicode text.", options: TextEncoding.allCases.map(\.label), index: TextEncoding.allCases.firstIndex(of: e.encoding) ?? 0))
        fields.append(.toggle("iceColors", section: terminal, label: "iCE colours", hint: "When on, the blink attribute shows as a bright background colour instead of blinking text, as iCE colour art expects.", isOn: e.iceColors))
        var speedList = speeds
        if !speedList.contains(e.baud) { speedList.append(e.baud) }
        fields.append(.choice("baud", section: terminal, label: "Simulated speed", hint: "Shows incoming text at a modem speed, such as 2400 baud, for the classic feel. Unlimited shows it at once. Typing is never slowed.", options: speedList.map(speedLabel), index: speedList.firstIndex(of: e.baud) ?? 0))
        fields.append(.choice("backspace", section: terminal, label: "Backspace sends", hint: "The code the Backspace key sends. Most BBSes want BS; choose DEL if Backspace prints odd characters instead of erasing.", options: backspaceOptions, index: e.backspaceSendsDelete ? 1 : 0))
        fields.append(.choice("musicMode", section: terminal, label: "ANSI music", hint: MusicMode.entryHint, options: MusicMode.allCases.map(\.entryLabel), index: MusicMode.allCases.firstIndex(of: e.musicMode) ?? 2))
        fields.append(.choice("modemSound", section: terminal, label: "Modem sound", hint: "Plays the synthesized dial tones and handshake while connecting. The first choice follows Playback > Modem Sounds.", options: ModemSoundChoice.allCases.map(\.label), index: ModemSoundChoice.allCases.firstIndex(of: e.modemSound) ?? 0))

        let transfers = "File transfers"
        fields.append(.choice("transferProtocol", section: transfers, label: "Protocol", hint: "Preselected in Terminal > Upload and Download. Pick ZMODEM if the BBS offers it; it is fast, sends names and resumes.", options: TransferProtocolKind.allCases.map(\.displayName), index: TransferProtocolKind.allCases.firstIndex(of: e.transferProtocol) ?? 5))
        fields.append(.action("chooseDownloadFolder", section: transfers, label: "Download folder", hint: "Where files from this BBS are saved. Enter chooses one; without one the default folder (first asked, Downloads) is used.", caption: e.downloadFolderName ?? "Choose..."))
        fields.append(.action("clearDownloadFolder", section: transfers, label: "Forget folder", hint: "Forgets this BBS's download folder, so its files go to the default folder again.", caption: "Forget"))
        fields.append(.toggle("zmodemAutoAccept", section: transfers, label: "Auto-accept ZMODEM", hint: "When on, a ZMODEM download the BBS starts begins at once. When off, a bar asks first, in case it was a false alarm.", isOn: e.zmodemAutoAccept))

        let login = "Login"
        fields.append(.text("username", section: login, label: "Username", hint: "Your name or handle on this BBS. The login script and Terminal > Send Username type it.", value: e.username ?? "", maxLength: 80))
        fields.append(.secret("password", section: login, label: "Password", hint: "Saved only in your Mac's Keychain, never in the directory or an export. Needs a username. Terminal > Send Password types it.", value: password, maxLength: 120))
        fields.append(.toggle("showPassword", section: login, label: "Show password", hint: "Shows the password on screen while you check it. It is hidden again the next time the editor opens.", isOn: false, revealsSecrets: true))
        fields.append(.toggle("iemsi", section: login, label: "IEMSI login", hint: "Answers a BBS that asks for IEMSI (an automatic login some RemoteAccess, Maximus and Mystic boards offer) with your username and saved password.", isOn: e.iemsi))
        fields.append(.toggle("autoLogin", section: login, label: "Log in automatically", hint: "Runs the login script below as soon as the BBS answers. Terminal > Log In runs it again at any time.", isOn: e.autoLogin))
        fields.append(.text("busyText", section: login, label: "Busy text", hint: "Text that means the BBS is full, such as: all nodes are busy. Seen in the first 30 seconds, it hangs up and dials the next BBS. Separate choices with |.", value: e.busyText, maxLength: 200))

        let script = "Login script (expect, then send)"
        for (i, step) in e.loginScript.enumerated() {
            let n = i + 1
            fields.append(.text("step.\(i).expect", section: script, label: "Step \(n) waits for", hint: "The prompt to wait for, such as login: or name. Case, spaces and colour codes are ignored; separate choices with |. Empty sends at once.", value: step.expect, maxLength: 120))
            fields.append(.choice("step.\(i).send", section: script, label: "Step \(n) sends", hint: "What to type when the prompt appears: your username or password (each followed by Return), the text below, or just Return.", options: LoginSend.allCases.map(\.label), index: LoginSend.allCases.firstIndex(of: step.send) ?? 0))
            fields.append(.text("step.\(i).text", section: script, label: "Step \(n) text", hint: "Typed when the step sends Text. \\r is Return, \\e is Escape, \\t is Tab and \\xHH is any byte, for example Y\\r.", value: step.text, maxLength: 120))
            fields.append(.number("step.\(i).timeout", section: script, label: "Step \(n) timeout", hint: "Seconds to wait for this prompt. If it never comes, the script stops and leaves the login to you.", value: Int(step.timeout), range: 1...600))
        }
        fields.append(.action("addStep", section: script, label: "Add a step", hint: "Adds an empty step at the end of the script. Fill in what it waits for and what it sends.", caption: "Add"))
        fields.append(.action("removeStep", section: script, label: "Remove last step", hint: "Removes the last step of the script. A script with no steps does nothing.", caption: "Remove"))
        fields.append(.action("resetScript", section: script, label: "Reset script", hint: "Puts back the default script, which answers the usual login and password prompts of common BBS packages.", caption: "Reset"))

        let capture = "Capture"
        fields.append(.toggle("captureOnConnect", section: capture, label: "Capture on connect", hint: "Saves everything the BBS sends to a .ans file in the folder below from the moment it answers, so you can replay it in AnsiView later.", isOn: e.captureOnConnect))
        fields.append(.action("chooseFolder", section: capture, label: "Capture folder", hint: "The folder for automatic captures. Press Enter to choose one; AnsiView remembers your permission to write there.", caption: e.captureFolderName ?? "Choose..."))
        fields.append(.action("clearFolder", section: capture, label: "Forget folder", hint: "Forgets the capture folder. Captures on connect stop until you choose another one.", caption: "Forget"))

        let macros = "Macros (Option-1 to Option-0 in the terminal)"
        for slot in 0..<MacroSet.slotCount {
            let value = slot < e.macros.count ? e.macros[slot] : ""
            fields.append(.text("macro.\(slot)", section: macros, label: MacroSet.label(slot: slot), hint: "Typed when you press \(MacroSet.label(slot: slot)) in this BBS's terminal. \\r is Return, for example /who\\r. Empty uses the global macro (G in the directory).", value: value, maxLength: 200))
        }
        let title = e.name.isEmpty ? "New BBS" : "Edit \(e.name)"
        return TextForm(title: title, fields: fields, info: info(for: e))
    }

    /// The entry with the form's values, and the password typed.
    public static func apply(_ form: TextForm, to entry: BBSEntry) -> (entry: BBSEntry, password: String) {
        var e = entry
        func text(_ id: String) -> String? { form.field(id)?.text }
        func choice(_ id: String) -> FormField? { form.field(id) }
        if let v = text("name") { e.name = v.trimmingCharacters(in: .whitespaces) }
        if let v = text("host") { e.host = v.trimmingCharacters(in: .whitespaces) }
        if let f = form.field("port") { e.port = f.number }
        if let f = choice("mode") { e.mode = ConnectionMode.allCases[safe: f.index] ?? .telnet }
        if let f = form.field("trustNewHostKey") { e.sshTrustNewHostKey = f.isOn }
        if let f = form.field("wsSecure") { e.webSocketSecure = f.isOn }
        if let v = text("wsPath") {
            let trimmed = v.trimmingCharacters(in: .whitespaces)
            e.webSocketPath = trimmed.isEmpty ? "/" : trimmed
        }
        if let v = text("wsSubprotocols") { e.webSocketSubprotocols = v.trimmingCharacters(in: .whitespaces) }
        if let f = form.field("wsTelnet") { e.webSocketTelnet = f.isOn }
        if let v = text("rloginClient") { e.rloginClientUser = v.trimmingCharacters(in: .whitespaces) }
        if let v = text("rloginServer") { e.rloginServerUser = v.trimmingCharacters(in: .whitespaces) }
        if let f = form.field("rloginClientIsPassword") { e.rloginClientIsPassword = f.isOn }
        if let v = text("tags") { e.tags = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let v = text("notes") { e.notes = v }
        if let f = choice("emulation") { e.emulation = TerminalEmulation.allCases[safe: f.index] ?? .ansiBBS }
        if let f = choice("terminalType") { e.terminalType = f.choiceValue }
        if let f = form.field("telnetSecure") { e.telnetSecure = f.isOn }
        if let f = form.field("columns") { e.columns = f.number }
        if let f = form.field("rows") { e.rows = f.number }
        if let f = choice("font") { e.fontName = f.choiceValue }
        if let f = choice("encoding") { e.encoding = TextEncoding.allCases[safe: f.index] ?? .cp437 }
        if let f = form.field("iceColors") { e.iceColors = f.isOn }
        if let f = choice("baud") { e.baud = speed(fromLabel: f.choiceValue) }
        if let f = choice("backspace") { e.backspaceSendsDelete = f.index == 1 }
        if let f = choice("musicMode") { e.musicMode = MusicMode.allCases[safe: f.index] ?? .bananaCom }
        if let f = choice("modemSound") { e.modemSound = ModemSoundChoice.allCases[safe: f.index] ?? .playbackSetting }
        if let v = text("username") {
            let trimmed = v.trimmingCharacters(in: .whitespaces)
            e.username = trimmed.isEmpty ? nil : trimmed
        }
        if let f = form.field("autoLogin") { e.autoLogin = f.isOn }
        if let f = form.field("iemsi") { e.iemsi = f.isOn }
        if let v = text("busyText") { e.busyText = v }
        for i in e.loginScript.indices {
            if let v = text("step.\(i).expect") { e.loginScript[i].expect = v }
            if let f = choice("step.\(i).send") { e.loginScript[i].send = LoginSend.allCases[safe: f.index] ?? .returnKey }
            if let v = text("step.\(i).text") { e.loginScript[i].text = v }
            if let f = form.field("step.\(i).timeout") { e.loginScript[i].timeout = Double(f.number) }
        }
        if let f = form.field("captureOnConnect") { e.captureOnConnect = f.isOn }
        if let f = choice("transferProtocol") { e.transferProtocol = TransferProtocolKind.allCases[safe: f.index] ?? .zmodem }
        if let f = form.field("zmodemAutoAccept") { e.zmodemAutoAccept = f.isOn }
        for slot in 0..<MacroSet.slotCount {
            guard let v = text("macro.\(slot)") else { continue }
            while e.macros.count <= slot { e.macros.append("") }
            e.macros[slot] = v
        }
        return (e, form.field("password")?.text ?? "")
    }

    /// Script and folder actions that change the entry's shape (the caller rebuilds the form).
    public static func perform(_ action: String, on entry: BBSEntry) -> BBSEntry {
        var e = entry
        switch action {
        case "addStep": e.loginScript.append(LoginStep(expect: "", send: .text))
        case "removeStep": if !e.loginScript.isEmpty { e.loginScript.removeLast() }
        case "resetScript": e.loginScript = LoginScript.defaultSteps
        case "clearFolder":
            e.captureFolderBookmark = nil
            e.captureFolderName = nil
        case "clearDownloadFolder":
            e.downloadFolderBookmark = nil
            e.downloadFolderName = nil
        case "clearKey":
            e.sshKeyBookmark = nil
            e.sshKeyName = nil
        default: break
        }
        return e
    }

    /// The SSH key passphrase typed (empty when the form has none).
    public static func passphrase(_ form: TextForm) -> String {
        form.field("keyPassphrase")?.text ?? ""
    }

    /// The draft with the form applied after the protocol (or wss) changed: a port still at the
    /// old protocol's default moves to the new one; a port the user chose stays.
    public static func changingProtocol(_ form: TextForm, draft: BBSEntry) -> BBSEntry {
        let old = draft
        var e = apply(form, to: draft).entry
        if e.port == old.mode.defaultPort(secure: old.isSecure) {
            e.port = e.mode.defaultPort(secure: e.isSecure)
        }
        return e
    }

    /// The draft with the form applied after the terminal type changed: the size and the name sent
    /// follow the new type when they still held the old type's defaults; values the user chose stay.
    public static func changingEmulation(_ form: TextForm, draft: BBSEntry) -> BBSEntry {
        let old = draft
        var e = apply(form, to: draft).entry
        if e.columns == old.emulation.defaultColumns { e.columns = e.emulation.defaultColumns }
        if e.rows == old.emulation.defaultRows { e.rows = e.emulation.defaultRows }
        if e.terminalType.caseInsensitiveCompare(old.emulation.terminalNames[0]) == .orderedSame {
            e.terminalType = e.emulation.terminalNames[0]
        }
        return e
    }

    /// The fields of the chosen protocol (ruling 9 of the transports plan).
    static func transportFields(_ e: BBSEntry, passphrase: String) -> [FormField] {
        var fields: [FormField] = []
        switch e.mode {
        case .telnet:
            let telnet = "Telnet"
            fields.append(.toggle("telnetSecure", section: telnet, label: "Secure (TLS)", hint: "Wraps telnet in TLS (telnets), which many Synchronet boards offer on port 992. Self signed certificates are shown once for you to trust.", isOn: e.telnetSecure))
            fields.append(.action("forgetCertificate", section: telnet, label: "Saved certificate", hint: "Forgets the TLS certificate saved for this address, for when the sysop says it really changed. The next call asks again.", caption: "Forget"))
        case .raw:
            break
        case .ssh:
            let ssh = "SSH"
            fields.append(.action("chooseKey", section: ssh, label: "Key file", hint: "A private key file (Ed25519 or ECDSA, from ssh-keygen), tried before the password. Enter chooses one. Most BBSes need no key.", caption: e.sshKeyName ?? "Choose..."))
            fields.append(.action("clearKey", section: ssh, label: "Forget key file", hint: "Stops using the key file. The password (or an empty one) is used instead.", caption: "Forget"))
            fields.append(.secret("keyPassphrase", section: ssh, label: "Key passphrase", hint: "The passphrase that protects the key file, if it has one. Saved only in your Mac's Keychain. Needs a username.", value: passphrase, maxLength: 200))
            fields.append(.toggle("trustNewHostKey", section: ssh, label: "Trust new host key", hint: "When on, the BBS's key is saved the first time without asking. A key that changes later is always refused.", isOn: e.sshTrustNewHostKey))
            fields.append(.action("forgetHostKey", section: ssh, label: "Saved host key", hint: "Forgets the host key saved for this address, for when the sysop says the key really changed. The next call asks again.", caption: "Forget"))
        case .webSocket:
            let ws = "WebSocket"
            fields.append(.toggle("wsSecure", section: ws, label: "Secure (wss)", hint: "Uses an encrypted wss:// connection (TLS). Turn it off for a plain ws:// address. The port follows when it is the default.", isOn: e.webSocketSecure))
            fields.append(.text("wsPath", section: ws, label: "Path", hint: "The part of the WebSocket address after the host and port, such as / or /ws. The BBS's web terminal page shows it.", value: e.webSocketPath, maxLength: 200))
            fields.append(.text("wsSubprotocols", section: ws, label: "Subprotocols", hint: "Names sent in the Sec-WebSocket-Protocol header, separated by commas, such as telnet or binary. Leave empty if the BBS names none.", value: e.webSocketSubprotocols, maxLength: 120))
            fields.append(.toggle("wsTelnet", section: ws, label: "Telnet inside", hint: "Turn on when the WebSocket carries a telnet stream (fTelnet or websockify style bridges), so telnet negotiation runs inside it.", isOn: e.webSocketTelnet))
        case .rlogin:
            let rl = "RLogin"
            fields.append(.toggle("rloginClientIsPassword", section: rl, label: "Send password", hint: "Sends your saved password (from the Keychain) as the client user, as Synchronet style RLogin servers expect. The field below is then not used.", isOn: e.rloginClientIsPassword))
            fields.append(.text("rloginClient", section: rl, label: "Client user", hint: "The client user name sent when connecting. Empty sends your username. Do not type secrets here: it is saved in the directory.", value: e.rloginClientUser, maxLength: 80))
            fields.append(.text("rloginServer", section: rl, label: "Server user", hint: "The server user name: the account to log in to on the BBS. Empty sends your username.", value: e.rloginServerUser, maxLength: 80))
        }
        return fields
    }

    public static func info(for entry: BBSEntry, timeZone: TimeZone = .current) -> String {
        var last = "Never"
        if let date = entry.lastCalled {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            last = formatter.string(from: date)
        }
        return "Last called: \(last)    Times called: \(entry.totalCalls)"
    }

    static func speedLabel(_ baud: Int) -> String { baud == 0 ? "Unlimited" : "\(baud) baud" }

    static func speed(fromLabel label: String) -> Int {
        Int(label.split(separator: " ").first ?? "") ?? 0
    }

    /// The directory settings screen: global macros, redial and launch.
    public static func settings(_ d: DialingDirectory) -> TextForm {
        var fields: [FormField] = []
        let dialing = "Dialing"
        fields.append(.number("redialAttempts", section: dialing, label: "Redial passes", hint: "How many times the dialer goes through the queue of BBSes before it gives up.", value: d.redialAttempts, range: RedialQueue.passRange))
        fields.append(.number("redialDelay", section: dialing, label: "Redial delay", hint: "Seconds to wait after a busy or failed call before dialing the next BBS. Dial Now skips the wait.", value: Int(d.redialDelay), range: Int(RedialQueue.delayRange.lowerBound)...Int(RedialQueue.delayRange.upperBound)))
        fields.append(.toggle("showAtLaunch", section: dialing, label: "Show at launch", hint: "Opens this directory every time AnsiView starts, as a terminal program would.", isOn: d.showAtLaunch))
        let macros = "Global macros (every BBS)"
        for slot in 0..<MacroSet.slotCount {
            let value = slot < d.globalMacros.count ? d.globalMacros[slot] : ""
            fields.append(.text("macro.\(slot)", section: macros, label: MacroSet.label(slot: slot), hint: "Typed when you press \(MacroSet.label(slot: slot)) in any terminal, unless that BBS has its own macro for the key. \\r is Return.", value: value, maxLength: 200))
        }
        return TextForm(title: "Directory Settings", fields: fields, info: "\(d.entries.count) BBSes in the directory")
    }

    public static func applySettings(_ form: TextForm, to d: DialingDirectory) -> DialingDirectory {
        var d = d
        if let f = form.field("redialAttempts") { d.redialAttempts = f.number }
        if let f = form.field("redialDelay") { d.redialDelay = Double(f.number) }
        if let f = form.field("showAtLaunch") { d.showAtLaunch = f.isOn }
        for slot in 0..<MacroSet.slotCount {
            guard let v = form.field("macro.\(slot)")?.text else { continue }
            while d.globalMacros.count <= slot { d.globalMacros.append("") }
            d.globalMacros[slot] = v
        }
        return d
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
