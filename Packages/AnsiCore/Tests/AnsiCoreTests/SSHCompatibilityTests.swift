import Testing
@testable import AnsiCore

// SSH compatibility plan: status note for weak algorithms, plain mismatch text, the
// keyboard-interactive answer plan and the password change message.

@Test func legacyNoteOnlyForWeakAlgorithms() {
    #expect(SSHCompatibility.legacyNote(weakAlgorithms: []) == nil)
    #expect(SSHCompatibility.legacyNote(weakAlgorithms: ["aes128-cbc"]) == "Legacy SSH encryption")
    let explanation = SSHCompatibility.legacyExplanation(weakAlgorithms: ["diffie-hellman-group1-sha1", "3des-cbc"])
    #expect(explanation.contains("diffie-hellman-group1-sha1, 3des-cbc"))
    #expect(explanation.contains("still encrypted"))
    #expect(!explanation.contains("\u{2014}"))
}

@Test func mismatchDetailNamesTheCategoryAndOffer() {
    #expect(SSHCompatibility.mismatchDetail("key exchange: sntrup761x25519-sha512,diffie-hellman-group18-sha512")
            == "no key exchange method in common; the server offers sntrup761x25519-sha512, diffie-hellman-group18-sha512")
    #expect(SSHCompatibility.mismatchDetail("host key: x509v3-sign-rsa") == "no host key type in common; the server offers x509v3-sign-rsa")
    #expect(SSHCompatibility.mismatchDetail("cipher: blowfish-cbc,arcfour") == "no cipher in common; the server offers blowfish-cbc, arcfour")
    #expect(SSHCompatibility.mismatchDetail("MAC: umac-64@openssh.com") == "no MAC in common; the server offers umac-64@openssh.com")
    #expect(SSHCompatibility.mismatchDetail(nil) == "no key exchange method, host key type or cipher in common")
    let message = BBSConnectionError.algorithmMismatch("bbs.example", SSHCompatibility.mismatchDetail("cipher: arcfour")).message
    #expect(message == "bbs.example only offers SSH methods that AnsiView cannot use (no cipher in common; the server offers arcfour). Try the BBS's telnet port instead.")
}

@Test func keyboardInteractiveAnswersAPasswordPromptOnce() {
    let password = [SSHCompatibility.Prompt(text: "Password: ", echo: false)]
    #expect(SSHCompatibility.plan(prompts: password, savedPassword: "secret", passwordAlreadySent: false) == .answer(["secret"]))
    // Asked again: the saved password was wrong, so the user types it.
    #expect(SSHCompatibility.plan(prompts: password, savedPassword: "secret", passwordAlreadySent: true) == .ask)
    // Nothing saved: ask.
    #expect(SSHCompatibility.plan(prompts: password, savedPassword: nil, passwordAlreadySent: false) == .ask)
    // An instruction only round has no prompts and is answered at once.
    #expect(SSHCompatibility.plan(prompts: [], savedPassword: nil, passwordAlreadySent: false) == .answer([]))
}

@Test func keyboardInteractiveAsksForAnythingElse() {
    let cases: [[SSHCompatibility.Prompt]] = [
        [.init(text: "New password: ", echo: false)],
        [.init(text: "Password: ", echo: true)],
        [.init(text: "Password: ", echo: false), .init(text: "Handle: ", echo: true)],
        [.init(text: "Verification code: ", echo: false)],
    ]
    for prompts in cases {
        #expect(SSHCompatibility.plan(prompts: prompts, savedPassword: "secret", passwordAlreadySent: false) == .ask)
    }
}

@Test func passwordChangeRequestIsPlain() {
    let text = SSHCompatibility.passwordChangeMessage(prompt: "Password expired")
    #expect(text == "The BBS asks you to change your password (\"Password expired\"). AnsiView can do that when the BBS asks with keyboard-interactive prompts; this one asked in a way AnsiView cannot answer, so log in once with the BBS's telnet port or another SSH program to change it.")
}
