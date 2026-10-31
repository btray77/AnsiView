import AnsiCore
import AppKit

/// Trust on first use for SSH host keys (transports plan ruling 5), with the known hosts file in
/// the app container. A new key asks once (unless the entry trusts new keys); a changed key is
/// refused with a loud warning whose second button forgets the saved key for next time.
final class HostKeyPrompt: HostKeyVerifying {
    enum Question: Equatable {
        case new(host: String, type: String, fingerprint: String)
        case changed(host: String, saved: String, offered: String)
    }

    enum Answer {
        /// New key: trust it. Changed key: forget the saved one (the connection is still refused).
        case accept
        case cancel
    }

    var file: KnownHostsFile
    /// The window the alert is a sheet on (nil runs it as a modal alert).
    var window: () -> NSWindow?
    /// Answers without an alert (the test harness); the question is recorded in `asked`.
    var autoAnswer: ((Question) -> Answer)?
    private(set) var asked: [Question] = []

    init(file: KnownHostsFile = .standard, window: @escaping () -> NSWindow? = { nil }) {
        self.file = file
        self.window = window
    }

    func verify(host: String, port: Int, key: Data, trustNew: Bool, done: @escaping (BBSConnectionError?) -> Void) {
        let hosts = file.load()
        let shownHost = KnownHosts.hostPattern(host: host, port: port)
        let fingerprint = SSHFingerprint.sha256(key)
        switch hosts.check(host: host, port: port, key: key) {
        case .trusted:
            done(nil)
        case .unknown:
            let save = {
                // Reloaded: another terminal may have saved a key while this alert was up.
                var current = self.file.load()
                current.trust(host: host, port: port, key: key)
                try? self.file.save(current)
            }
            if trustNew {
                save()
                done(nil)
                return
            }
            let question = Question.new(host: shownHost, type: SSHFingerprint.keyType(key) ?? "unknown", fingerprint: fingerprint)
            ask(question) { answer in
                if answer == .accept {
                    save()
                    done(nil)
                } else {
                    done(.hostKeyNotTrusted(host))
                }
            }
        case .changed(let saved):
            ask(.changed(host: shownHost, saved: saved, offered: fingerprint)) { answer in
                if answer == .accept {
                    var current = self.file.load()
                    current.forget(host: host, port: port)
                    try? self.file.save(current)
                }
                done(.hostKeyChanged(host, saved, fingerprint))
            }
        }
    }

    /// Forgets the saved key for one address (the entry editor's Saved host key: Forget).
    func forget(host: String, port: Int) -> Bool {
        var hosts = file.load()
        let had = hosts.check(host: host, port: port, key: Data()) != .unknown
        hosts.forget(host: host, port: port)
        try? file.save(hosts)
        return had
    }

    static func alert(for question: Question) -> NSAlert {
        let alert = NSAlert()
        GlossaryAlertHelp.attach(.hostKey, to: alert)
        switch question {
        case .new(let host, let type, let fingerprint):
            alert.messageText = "Trust the SSH host key of \(host)?"
            alert.informativeText = "This is the first connection to \(host). Its \(type) host key fingerprint is:\n\n\(fingerprint)\n\nIf the BBS publishes its fingerprint, check that they match. AnsiView remembers the key and warns you if it ever changes."
            alert.addButton(withTitle: "Trust and Connect")
            alert.addButton(withTitle: "Cancel")
        case .changed(let host, let saved, let offered):
            alert.alertStyle = .critical
            alert.messageText = "WARNING: the SSH host key of \(host) has changed"
            alert.informativeText = "AnsiView did not connect. The key saved for this BBS is\n\(saved)\nbut the server offered\n\(offered)\n\nSomeone may be pretending to be this BBS, or its sysop replaced the key. Only forget the saved key if the sysop confirms the change; the next connection then asks about the new key."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Forget the Saved Key")
        }
        return alert
    }

    private func ask(_ question: Question, _ handle: @escaping (Answer) -> Void) {
        asked.append(question)
        if let autoAnswer {
            handle(autoAnswer(question))
            return
        }
        let alert = Self.alert(for: question)
        let isNew: Bool
        if case .new = question { isNew = true } else { isNew = false }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let first = response == .alertFirstButtonReturn
            // New: first button trusts. Changed: the second button forgets.
            handle(isNew ? (first ? .accept : .cancel) : (first ? .cancel : .accept))
        }
        if let window = window(), window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
