import Foundation

/// What a login step types once its prompt appears.
public enum LoginSend: String, Codable, CaseIterable {
    /// The entry's username, then Return.
    case username
    /// The entry's password from the Keychain, then Return.
    case password
    /// The step's text, with macro escapes (`\r` for Return).
    case text
    /// Just Return.
    case returnKey

    public var label: String {
        switch self {
        case .username: return "Username + Return"
        case .password: return "Password + Return"
        case .text: return "Text"
        case .returnKey: return "Return"
        }
    }
}

/// One expect/send step of a login script.
public struct LoginStep: Codable, Equatable, Identifiable {
    public static let defaultTimeout: Double = 30

    public var id: UUID
    /// Text to wait for, `|` between alternatives; empty sends at once. Case, spaces, control
    /// codes and ANSI escape sequences are ignored when matching.
    public var expect: String
    public var send: LoginSend
    /// Typed when `send` is `.text`.
    public var text: String
    /// Seconds to wait for `expect` before the script gives up.
    public var timeout: Double

    public init(expect: String, send: LoginSend, text: String = "", timeout: Double = LoginStep.defaultTimeout) {
        id = UUID()
        self.expect = expect
        self.send = send
        self.text = text
        self.timeout = timeout
    }

    private enum CodingKeys: String, CodingKey { case id, expect, send, text, timeout }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(expect: (try? c.decode(String.self, forKey: .expect)) ?? "",
                  send: (try? c.decode(LoginSend.self, forKey: .send)) ?? .returnKey,
                  text: (try? c.decode(String.self, forKey: .text)) ?? "")
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        if let value = try? c.decode(Double.self, forKey: .timeout), value > 0 { timeout = min(600, value) }
    }

    /// The alternatives in an expect text, trimmed, empty ones dropped.
    public static func patterns(in expect: String) -> [String] {
        expect.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public enum LoginScript {
    /// Prompts printed by common BBS packages by default (Synchronet and Mystic `Login:`,
    /// WWIV `NN:` / `PW:`, ENiGMA 1/2 `Username:`), then the password prompt.
    public static let defaultSteps: [LoginStep] = [
        LoginStep(expect: "login:|name:|nn:|handle:|user id:", send: .username),
        LoginStep(expect: "password:|pw:", send: .password),
    ]
}

/// Watches a BBS byte stream for prompt text, ignoring ANSI escape sequences (CSI, ESC with
/// intermediates, and OSC, DCS, APC, PM and SOS strings), control bytes, spaces and ASCII case.
/// Memory is bounded whatever the server sends.
public struct PromptMatcher {
    public static let maxBuffer = 256
    private static let maxSequence = 64
    private static let maxString = 4096

    private enum State { case ground, escape, intermediate, csi, string, stringEscape }

    private let needles: [[UInt8]]
    private var buffer: [UInt8] = []
    private var state = State.ground
    private var sequenceLength = 0

    public init(patterns: [String], encoding: TextEncoding) {
        needles = patterns.map { Self.normalize(TerminalInput.text($0, encoding: encoding)) }.filter { !$0.isEmpty }
    }

    public var bufferedCount: Int { buffer.count }

    /// True when any pattern has appeared (the rest of `bytes` is not examined).
    public mutating func feed(_ bytes: [UInt8]) -> Bool {
        scan(bytes[...]) != nil
    }

    /// The number of bytes of `bytes` read up to and including the end of a match, or nil.
    /// After a match the matcher starts afresh.
    public mutating func scan(_ bytes: ArraySlice<UInt8>) -> Int? {
        var consumed = 0
        for byte in bytes {
            consumed += 1
            guard let text = filter(byte) else { continue }
            buffer.append(text)
            if buffer.count > Self.maxBuffer * 2 { buffer.removeFirst(buffer.count - Self.maxBuffer) }
            if needles.contains(where: { buffer.count >= $0.count && buffer.suffix($0.count).elementsEqual($0) }) {
                buffer.removeAll()
                return consumed
            }
        }
        if buffer.count > Self.maxBuffer { buffer.removeFirst(buffer.count - Self.maxBuffer) }
        return nil
    }

    /// The text byte this input byte adds, if any.
    private mutating func filter(_ byte: UInt8) -> UInt8? {
        switch state {
        case .ground:
            if byte == 0x1B { state = .escape; return nil }
            return Self.normalize(byte)
        case .escape:
            sequenceLength = 0
            switch byte {
            case 0x5B: state = .csi
            case 0x5D, 0x50, 0x5F, 0x5E, 0x58: state = .string
            case 0x20...0x2F: state = .intermediate
            case 0x1B: state = .escape
            default: state = .ground
            }
            return nil
        case .intermediate:
            sequenceLength += 1
            if byte == 0x1B { state = .escape } else if (0x30...0x7E).contains(byte) || sequenceLength > Self.maxSequence { state = .ground }
            return nil
        case .csi:
            sequenceLength += 1
            if byte == 0x1B { state = .escape } else if (0x40...0x7E).contains(byte) || sequenceLength > Self.maxSequence { state = .ground }
            return nil
        case .string:
            sequenceLength += 1
            if byte == 0x07 || sequenceLength > Self.maxString { state = .ground } else if byte == 0x1B { state = .stringEscape }
            return nil
        case .stringEscape:
            if byte == 0x5C { state = .ground; return nil }
            state = .escape
            return filter(byte)
        }
    }

    private static func normalize(_ byte: UInt8) -> UInt8? {
        if byte <= 0x20 || byte == 0x7F { return nil }
        if (0x41...0x5A).contains(byte) { return byte + 0x20 }
        return byte
    }

    private static func normalize(_ bytes: [UInt8]) -> [UInt8] {
        bytes.compactMap { normalize($0) }
    }
}

public enum LoginAction: Equatable {
    case send([UInt8])
    case finished
    /// The script stopped; the message says why, for the status line.
    case failed(String)
}

/// Runs a login script against the BBS stream. Pure: the caller passes the time and sends the bytes.
public struct LoginScriptRunner {
    public let steps: [LoginStep]
    private let username: String?
    private let password: String?
    private let encoding: TextEncoding
    public private(set) var stepIndex = 0
    public private(set) var isRunning = false
    private var matcher: PromptMatcher?
    private var deadline: TimeInterval = .infinity

    public init(steps: [LoginStep], username: String?, password: String?, encoding: TextEncoding) {
        self.steps = steps
        self.username = username
        self.password = password
        self.encoding = encoding
    }

    /// Starts at the first step; steps with no prompt send at once.
    public mutating func start(now: TimeInterval) -> [LoginAction] {
        stepIndex = 0
        isRunning = true
        return enter(now: now)
    }

    public mutating func feed(_ bytes: [UInt8], now: TimeInterval) -> [LoginAction] {
        var actions: [LoginAction] = []
        var rest = bytes[...]
        while isRunning, matcher != nil {
            // Scans in place, so a prompt split across packets is still found.
            guard let used = matcher?.scan(rest) ?? nil else { break }
            rest = rest.dropFirst(used)
            actions += perform(steps[stepIndex])
            guard isRunning else { break }
            stepIndex += 1
            actions += enter(now: now)
        }
        return actions
    }

    public mutating func tick(now: TimeInterval) -> [LoginAction] {
        guard isRunning, now >= deadline else { return [] }
        let step = steps[stepIndex]
        return stop("The login script waited \(Int(step.timeout)) seconds for \"\(step.expect)\" (step \(stepIndex + 1)) and stopped. Log in by hand, or edit the script.")
    }

    /// Sends the steps that need no prompt, then waits on the next one.
    private mutating func enter(now: TimeInterval) -> [LoginAction] {
        var actions: [LoginAction] = []
        while isRunning, stepIndex < steps.count {
            let step = steps[stepIndex]
            let patterns = LoginStep.patterns(in: step.expect)
            if patterns.isEmpty {
                actions += perform(step)
                stepIndex += 1
                continue
            }
            matcher = PromptMatcher(patterns: patterns, encoding: encoding)
            deadline = now + step.timeout
            return actions
        }
        if isRunning {
            isRunning = false
            matcher = nil
            actions.append(.finished)
        }
        return actions
    }

    private mutating func perform(_ step: LoginStep) -> [LoginAction] {
        switch step.send {
        case .username:
            guard let username, !username.isEmpty else {
                return stop("No username is saved for this BBS, so the login script stopped at step \(stepIndex + 1).")
            }
            return [.send(TerminalInput.text(username, encoding: encoding) + [13])]
        case .password:
            guard let password, !password.isEmpty else {
                return stop("No password is saved for this BBS, so the login script stopped at step \(stepIndex + 1). Type it, or save it in the dialing directory.")
            }
            return [.send(TerminalInput.text(password, encoding: encoding) + [13])]
        case .text:
            let bytes = MacroText.bytes(step.text, encoding: encoding)
            return bytes.isEmpty ? [] : [.send(bytes)]
        case .returnKey:
            return [.send([13])]
        }
    }

    private mutating func stop(_ message: String) -> [LoginAction] {
        isRunning = false
        matcher = nil
        return [.failed(message)]
    }
}
