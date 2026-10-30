import AnsiCore
import AppKit

/// Keyboard-interactive SSH questions the Keychain password cannot answer (ssh-compat plan ruling
/// 11): a sheet with the server's name and instruction and one field per prompt (secure fields for
/// hidden answers). Answers are sent once and never stored.
final class SSHPromptSheet {
    struct Question: Equatable {
        var host: String
        var name: String
        var instruction: String
        var prompts: [SSHCompatibility.Prompt]
    }

    /// The window the sheet is on (nil runs it as a modal alert).
    var window: () -> NSWindow?
    /// Answers without a sheet (the test harness): nil cancels. The question is recorded in `asked`.
    var autoAnswer: ((Question) -> [String]?)?
    private(set) var asked: [Question] = []

    init(window: @escaping () -> NSWindow? = { nil }) {
        self.window = window
    }

    /// Calls `done` with one answer per prompt, or nil when the user cancels.
    func ask(_ question: Question, done: @escaping ([String]?) -> Void) {
        asked.append(question)
        if let autoAnswer {
            done(autoAnswer(question))
            return
        }
        let (alert, fields) = Self.alert(for: question)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            done(response == .alertFirstButtonReturn ? fields.map(\.stringValue) : nil)
        }
        if let window = window(), window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
        alert.window.initialFirstResponder = fields.first
    }

    static func alert(for question: Question) -> (NSAlert, [NSTextField]) {
        let alert = NSAlert()
        let name = question.name.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.messageText = name.isEmpty ? "\(question.host) asks you to log in" : "\(question.host): \(name)"
        let instruction = question.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = (instruction.isEmpty ? "" : instruction + "\n\n")
            + "AnsiView sends these answers to the BBS once and does not save them."
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var fields: [NSTextField] = []
        for prompt in question.prompts {
            let label = NSTextField(labelWithString: prompt.text.trimmingCharacters(in: .whitespaces))
            let field: NSTextField = prompt.echo ? NSTextField() : NSSecureTextField()
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            field.setAccessibilityLabel(label.stringValue)
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(field)
            fields.append(field)
        }
        for (index, field) in fields.enumerated() where index + 1 < fields.count {
            field.nextKeyView = fields[index + 1]
        }
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: max(1, CGFloat(question.prompts.count) * 50))
        alert.accessoryView = stack
        return (alert, fields)
    }
}
