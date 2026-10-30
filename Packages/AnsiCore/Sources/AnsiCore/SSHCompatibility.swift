import Foundation

/// The parts of SSH compatibility with classic BBS servers that need no SSH code: the status note
/// for weak algorithms, plain text for a failed negotiation, which keyboard-interactive prompts are
/// answered from the Keychain, and the password change message (ssh-compat plan rulings 11 to 13).
public enum SSHCompatibility {
    /// The short status bar note shown while a weak algorithm is in use, or nil.
    public static func legacyNote(weakAlgorithms: [String]) -> String? {
        weakAlgorithms.isEmpty ? nil : "Legacy SSH encryption"
    }

    /// The longer explanation (the status bar's tooltip and the log).
    public static func legacyExplanation(weakAlgorithms: [String]) -> String {
        "This BBS only offers older SSH methods (\(weakAlgorithms.joined(separator: ", "))), so AnsiView used them. "
            + "The connection is still encrypted, but less strongly than with modern SSH. Avoid reusing an important password here."
    }

    /// The library's negotiation failure detail ("key exchange: a,b") in plain words.
    public static func mismatchDetail(_ diagnostic: String?) -> String {
        let categories = [
            ("key exchange", "key exchange method"), ("host key", "host key type"), ("cipher", "cipher"), ("MAC", "MAC"),
        ]
        guard let diagnostic, let colon = diagnostic.firstIndex(of: ":") else {
            return "no key exchange method, host key type or cipher in common"
        }
        let category = String(diagnostic[..<colon])
        let offer = diagnostic[diagnostic.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            .split(separator: ",").joined(separator: ", ")
        guard let name = categories.first(where: { $0.0 == category })?.1 else {
            return "no key exchange method, host key type or cipher in common"
        }
        return "no \(name) in common; the server offers \(offer)"
    }

    /// One keyboard-interactive question.
    public struct Prompt: Equatable, Sendable {
        public var text: String
        public var echo: Bool

        public init(text: String, echo: Bool) {
            self.text = text
            self.echo = echo
        }
    }

    /// What to do with one keyboard-interactive request.
    public enum Plan: Equatable, Sendable {
        /// Send these answers without asking.
        case answer([String])
        /// Show the prompts to the user.
        case ask
    }

    /// A request with no prompts is answered at once; a single hidden prompt that asks for the
    /// password (not a new one) is answered with the saved password, once per connection; anything
    /// else is asked.
    public static func plan(prompts: [Prompt], savedPassword: String?, passwordAlreadySent: Bool) -> Plan {
        if prompts.isEmpty { return .answer([]) }
        guard prompts.count == 1, let prompt = prompts.first, !prompt.echo, let savedPassword, !passwordAlreadySent else {
            return .ask
        }
        let text = prompt.text.lowercased()
        guard text.contains("password"), !text.contains("new"), !text.contains("again"), !text.contains("retype") else {
            return .ask
        }
        return .answer([savedPassword])
    }

    /// The server asked for a password change in the password method (RFC 4252 section 8).
    public static func passwordChangeMessage(prompt: String) -> String {
        "The BBS asks you to change your password (\"\(prompt)\"). AnsiView can do that when the BBS asks with "
            + "keyboard-interactive prompts; this one asked in a way AnsiView cannot answer, so log in once with the BBS's "
            + "telnet port or another SSH program to change it."
    }
}
