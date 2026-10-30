//===----------------------------------------------------------------------===//
//
// AnsiView patch (see PATCHES.md): RFC 4256 keyboard-interactive authentication.
//
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

import NIOCore

/// The server's questions in one SSH_MSG_USERAUTH_INFO_REQUEST.
public struct NIOSSHKeyboardInteractiveRequest: Sendable, Hashable {
    public struct Prompt: Sendable, Hashable {
        public var prompt: String
        /// Whether the answer may be shown while typed (false for passwords).
        public var echo: Bool

        public init(prompt: String, echo: Bool) {
            self.prompt = prompt
            self.echo = echo
        }
    }

    public var name: String
    public var instruction: String
    public var prompts: [Prompt]

    public init(name: String, instruction: String, prompts: [Prompt]) {
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }
}

/// A client user auth delegate that also conforms to this answers keyboard-interactive prompts.
/// Without it, every prompt is answered with an empty string.
public protocol NIOSSHClientKeyboardInteractiveDelegate {
    /// Succeed the promise with one answer per prompt, in order, or fail it to give up.
    func respond(to request: NIOSSHKeyboardInteractiveRequest, responsePromise: EventLoopPromise<[String]>)
}

/// A server user auth delegate that also conforms to this offers keyboard-interactive: it gives
/// the prompts for a user, and receives the answers as a `.keyboardInteractive` request.
public protocol NIOSSHServerKeyboardInteractiveDelegate {
    func keyboardInteractiveChallenge(username: String) -> NIOSSHKeyboardInteractiveRequest?
}

extension NIOSSHKeyboardInteractiveRequest {
    init(_ message: SSHMessage.UserAuthInfoRequestMessage) {
        self.init(
            name: message.name,
            instruction: message.instruction,
            prompts: message.prompts.map { Prompt(prompt: $0.prompt, echo: $0.echo) }
        )
    }

    var message: SSHMessage.UserAuthInfoRequestMessage {
        .init(
            name: self.name,
            instruction: self.instruction,
            languageTag: "",
            prompts: self.prompts.map { .init(prompt: $0.prompt, echo: $0.echo) }
        )
    }
}
