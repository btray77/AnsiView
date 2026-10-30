import Foundation
import Testing
@testable import AnsiCore

// `bytes(_:)` comes from TerminalTests.swift.
private let esc = "\u{1B}"

/// Feeds text (or bytes) and returns whether a pattern matched (keeps #expect free of mutation).
private func see(_ m: inout PromptMatcher, _ s: String) -> Bool { m.feed(bytes(s)) }
private func see(_ m: inout PromptMatcher, _ b: [UInt8]) -> Bool { m.feed(b) }

@Test func matchesThroughColourCodes() {
    var m = PromptMatcher(patterns: ["login:"], encoding: .cp437)
    let first = see(&m, "Welcome!\r\n\(esc)[1;33mL\(esc)[0;36mog")
    let second = see(&m, "in\(esc)[37m : ")
    #expect(!first)
    #expect(second)
}

@Test func matchIgnoresCaseAndSpaces() {
    var m = PromptMatcher(patterns: ["User Name:"], encoding: .cp437)
    let matched = see(&m, "USER\(esc)[1CNAME :")
    #expect(matched)
}

@Test func alternatives() {
    var m = PromptMatcher(patterns: LoginStep.patterns(in: "login:|nn:"), encoding: .cp437)
    let matched = see(&m, "\r\nNN: ")
    #expect(matched)
    #expect(LoginStep.patterns(in: " a | |b ") == ["a", "b"])
    #expect(LoginStep.patterns(in: "").isEmpty)
}

@Test func matchSurvivesEverySplit() {
    let stream = bytes("\(esc)[2J\(esc)]0;title\u{07}\(esc)_SyncTERM:Q\(esc)\\Hello\r\n\(esc)[1;32mPass\(esc)[0mword: ")
    for split in 0...stream.count {
        var m = PromptMatcher(patterns: ["password:"], encoding: .cp437)
        let first = see(&m, Array(stream[..<split]))
        let second = see(&m, Array(stream[split...]))
        #expect(first == (split >= stream.count - 1), "split \(split)")  // the match ends at the colon
        #expect(first || second, "split \(split)")
    }
}

@Test func oscAndApcStringsAreIgnored() {
    // "login:" inside a title string, a SyncTERM probe or a DCS string is not a prompt.
    var m = PromptMatcher(patterns: ["login:"], encoding: .cp437)
    let hidden = see(&m, "\(esc)]2;login:\u{07}\(esc)_login:\(esc)\\\(esc)Plogin:\(esc)\\ok")
    let shown = see(&m, "login:")
    #expect(!hidden)
    #expect(shown)
}

@Test func matcherIsBounded() {
    var m = PromptMatcher(patterns: ["login:"], encoding: .cp437)
    // An endless CSI and an endless OSC string do not grow memory or hide what follows forever.
    _ = see(&m, bytes("\(esc)[") + Array(repeating: 0x31, count: 100_000))
    #expect(m.bufferedCount <= PromptMatcher.maxBuffer)
    _ = see(&m, bytes("\(esc)]") + Array(repeating: 0x41, count: 100_000) + [7])
    #expect(m.bufferedCount <= PromptMatcher.maxBuffer)
    _ = see(&m, Array(repeating: 0x42, count: 100_000))
    #expect(m.bufferedCount <= PromptMatcher.maxBuffer)
    let matched = see(&m, "Login:")
    #expect(matched)
}

@Test func cp437PatternBytes() {
    // A pattern with a CP437 character matches the CP437 byte, not its UTF-8 form.
    var m = PromptMatcher(patterns: ["Café:"], encoding: .cp437)
    let matched = see(&m, [0x43, 0x61, 0x66, 130, 0x3A])
    #expect(matched)
}

@Test func runnerSendsUsernameThenPassword() {
    var r = LoginScriptRunner(steps: LoginScript.defaultSteps, username: "guest", password: "secret", encoding: .cp437)
    let started = r.start(now: 0)
    #expect(started.isEmpty)
    #expect(r.isRunning && r.stepIndex == 0)
    let one = r.feed(bytes("Synchronet\r\n\r\nLogin: "), now: 1)
    #expect(one == [.send(bytes("guest\r"))])
    #expect(r.stepIndex == 1)
    let two = r.feed(bytes("guest\r\nPassword: "), now: 2)
    #expect(two == [.send(bytes("secret\r")), .finished])
    #expect(!r.isRunning)
    let after = r.feed(bytes("Login: "), now: 3)
    #expect(after.isEmpty)
}

@Test func textAfterMatchCarriesOver() {
    var r = LoginScriptRunner(steps: LoginScript.defaultSteps, username: "u", password: "p", encoding: .cp437)
    _ = r.start(now: 0)
    let actions = r.feed(bytes("Login: \r\nPassword: "), now: 1)
    #expect(actions == [.send(bytes("u\r")), .send(bytes("p\r")), .finished])
}

@Test func promptSplitAcrossFeeds() {
    var r = LoginScriptRunner(steps: LoginScript.defaultSteps, username: "u", password: "p", encoding: .cp437)
    _ = r.start(now: 0)
    let one = r.feed(bytes("Lo"), now: 1)
    let two = r.feed(bytes("gin: "), now: 1)
    #expect(one.isEmpty)
    #expect(two == [.send(bytes("u\r"))])
}

@Test func emptyExpectSendsAtOnce() {
    let steps = [LoginStep(expect: "", send: .returnKey), LoginStep(expect: "", send: .text, text: "x"),
                 LoginStep(expect: "go", send: .returnKey)]
    var r = LoginScriptRunner(steps: steps, username: nil, password: nil, encoding: .cp437)
    let started = r.start(now: 0)
    #expect(started == [.send([13]), .send(bytes("x"))])
    let fed = r.feed(bytes("GO"), now: 1)
    #expect(fed == [.send([13]), .finished])
}

@Test func textStepUsesEscapes() {
    let steps = [LoginStep(expect: "", send: .text, text: "Y\\r\\e[A\\x41")]
    var r = LoginScriptRunner(steps: steps, username: nil, password: nil, encoding: .cp437)
    let started = r.start(now: 0)
    #expect(started == [.send([0x59, 13, 27, 0x5B, 0x41, 0x41]), .finished])
}

@Test func timeoutStopsWithMessage() {
    var r = LoginScriptRunner(steps: [LoginStep(expect: "login:", send: .username, timeout: 5)],
                              username: "u", password: nil, encoding: .cp437)
    _ = r.start(now: 10)
    let early = r.tick(now: 14.9)
    #expect(early.isEmpty)
    let actions = r.tick(now: 15.1)
    #expect(actions.count == 1)
    if case .failed(let message) = actions.first { #expect(message.contains("login:")) } else { Issue.record("no failure") }
    #expect(!r.isRunning)
    // The timer restarts per step.
    var two = LoginScriptRunner(steps: LoginScript.defaultSteps, username: "u", password: "p", encoding: .cp437)
    _ = two.start(now: 0)
    _ = two.feed(bytes("login:"), now: 25)
    let later = two.tick(now: 50)
    #expect(later.isEmpty)
}

@Test func missingPasswordStops() {
    var r = LoginScriptRunner(steps: LoginScript.defaultSteps, username: "u", password: nil, encoding: .cp437)
    _ = r.start(now: 0)
    _ = r.feed(bytes("login:"), now: 1)
    let actions = r.feed(bytes("Password:"), now: 2)
    #expect(actions.count == 1)
    if case .failed(let message) = actions.first { #expect(message.lowercased().contains("password")) } else { Issue.record("no failure") }
    var noUser = LoginScriptRunner(steps: LoginScript.defaultSteps, username: "", password: "p", encoding: .cp437)
    _ = noUser.start(now: 0)
    let empty = noUser.feed(bytes("login:"), now: 1)
    if case .failed = empty.first {} else { Issue.record("empty username sent") }
}

/// Byte fixtures in the style of the default login screens of common BBS packages (written for this
/// test; the wording is what the plan infers the packages print by default, not captured from them).
@Test func defaultScriptMatchesCommonPrompts() {
    let fixtures: [(String, String, String)] = [
        ("Synchronet", "\(esc)[0m\(esc)[2J\(esc)[1;37mExample BBS\r\n\r\n\(esc)[0;36mLogin: \(esc)[1;37m", "\r\n\(esc)[0;36mPassword: "),
        ("Mystic", "\(esc)[2J\(esc)[0;1;34mExample\r\n\(esc)[0;37mLogin: ", "\r\n\(esc)[0;37mPassword: "),
        ("WWIV", "\r\nEnter number, name, or NEW\r\n\(esc)[0;1mNN: ", "\r\n\(esc)[0;1mPW: "),
        ("ENiGMA", "\(esc)[0m\(esc)[2J\(esc)[38;5;45mUsername:\(esc)[0m \(esc)[s", "\(esc)[u\r\n\(esc)[38;5;45mPassword:\(esc)[0m "),
    ]
    for (name, userPrompt, passPrompt) in fixtures {
        var r = LoginScriptRunner(steps: LoginScript.defaultSteps, username: "guest", password: "pw", encoding: .cp437)
        _ = r.start(now: 0)
        let one = r.feed(bytes(userPrompt), now: 1)
        let two = r.feed(bytes(passPrompt), now: 2)
        #expect(one == [.send(bytes("guest\r"))], "\(name) username")
        #expect(two == [.send(bytes("pw\r")), .finished], "\(name) password")
    }
}

@Test func busyDetection() {
    var m = PromptMatcher(patterns: LoginStep.patterns(in: BBSEntry.defaultBusyText), encoding: .cp437)
    let busy = see(&m, "\r\n\(esc)[1;31mSorry, ALL NODES ARE BUSY.\r\n")
    #expect(busy)
    var none = PromptMatcher(patterns: [], encoding: .cp437)
    let never = see(&none, "anything")
    #expect(!never)
}
