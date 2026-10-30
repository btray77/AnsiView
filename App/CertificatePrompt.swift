import AnsiCore
import AppKit

/// Trust on first use for telnet over TLS certificates that macOS does not trust (most BBSes use
/// self signed ones), with the same alerts as SSH host keys: a new certificate shows its details
/// once; a changed one is refused with a warning whose second button forgets the saved one.
final class CertificatePrompt: CertificateVerifying {
    enum Question: Equatable {
        case new(host: String, certificate: CertificateInfo)
        case changed(host: String, saved: String, offered: CertificateInfo)
    }

    enum Answer { case accept, cancel }

    var file: KnownCertificatesFile
    var window: () -> NSWindow?
    /// Answers without an alert (the test harness); questions are recorded in `asked`.
    var autoAnswer: ((Question) -> Answer)?
    private(set) var asked: [Question] = []

    init(file: KnownCertificatesFile = .standard, window: @escaping () -> NSWindow? = { nil }) {
        self.file = file
        self.window = window
    }

    func verify(host: String, port: Int, certificate: CertificateInfo, done: @escaping (BBSConnectionError?) -> Void) {
        let address = "\(host):\(port)"
        switch file.load().check(host: host, port: port, certificate: certificate) {
        case .trusted:
            done(nil)
        case .unknown:
            ask(.new(host: address, certificate: certificate)) { answer in
                guard answer == .accept else { done(.certificateNotTrusted(host)); return }
                var current = self.file.load()
                current.trust(host: host, port: port, certificate: certificate)
                try? self.file.save(current)
                done(nil)
            }
        case .changed(let saved):
            ask(.changed(host: address, saved: saved, offered: certificate)) { answer in
                if answer == .accept {
                    var current = self.file.load()
                    current.forget(host: host, port: port)
                    try? self.file.save(current)
                }
                done(.certificateChanged(host, saved, certificate.fingerprint))
            }
        }
    }

    /// Forgets the saved certificate for one address (the entry editor's Saved certificate: Forget).
    func forget(host: String, port: Int) -> Bool {
        var known = file.load()
        let had = known.check(host: host, port: port, certificate: CertificateInfo(fingerprint: "", subject: "", systemTrusted: false)) != .unknown
        known.forget(host: host, port: port)
        try? file.save(known)
        return had
    }

    static func alert(for question: Question) -> NSAlert {
        let alert = NSAlert()
        switch question {
        case .new(let host, let c):
            alert.messageText = "Trust the TLS certificate of \(host)?"
            alert.informativeText = "macOS does not trust this certificate (BBSes often make their own). It was issued to \(c.subject) by \(c.issuer.isEmpty ? c.subject : c.issuer).\n\nSHA-256 fingerprint:\n\(c.fingerprint)\n\nIf the BBS publishes its fingerprint, check that they match. AnsiView remembers the certificate and warns you if it ever changes."
            alert.addButton(withTitle: "Trust and Connect")
            alert.addButton(withTitle: "Cancel")
        case .changed(let host, let saved, let offered):
            alert.alertStyle = .critical
            alert.messageText = "WARNING: the TLS certificate of \(host) has changed"
            alert.informativeText = "AnsiView did not connect. The certificate saved for this BBS is\n\(saved)\nbut the server offered\n\(offered.fingerprint)\n(issued to \(offered.subject)).\n\nSomeone may be pretending to be this BBS, or its sysop replaced the certificate. Only forget the saved certificate if the sysop confirms the change; the next connection then asks again."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Forget the Saved Certificate")
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
            handle(isNew ? (first ? .accept : .cancel) : (first ? .cancel : .accept))
        }
        if let window = window(), window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
