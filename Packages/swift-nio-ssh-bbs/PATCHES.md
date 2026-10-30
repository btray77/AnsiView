# swift-nio-ssh-bbs: patches on top of swift-nio-ssh 0.15.1

Upstream: https://github.com/apple/swift-nio-ssh, tag `0.15.1`, commit `d1985926494b624e751b379009dc83f3395fd88a`
(2026-10-26). Licence: Apache 2.0 (`LICENSE.txt`, unchanged). Upstream has no NOTICE file. Every
patched line carries an `AnsiView patch` comment; new files say so in their header.

Purpose: let AnsiView's terminal reach classic BBS SSH servers (Synchronet and other cryptlib
servers, ENiGMA 1/2 and older ones) as well as OpenSSH. Plan and evidence:
`docs/superpowers/plans/2026-10-30-ansiview-2.0-ssh-compat.md` and `docs/BBS-COMPAT.md` in the
AnsiView repository. No C code: CommonCrypto and Security are Apple system frameworks.

To rebase: copy a newer upstream `Sources/NIOSSH` and `Tests/NIOSSHTests` over this folder, copy
the new files below back unchanged, then re-apply the hunks listed for the upstream files (search
for `AnsiView patch` in this copy to see each one in place).

## Packaging

- `Package.swift`: renamed to `swift-nio-ssh-bbs`; only the `NIOSSH` library and `NIOSSHTests`
  are kept (the upstream `NIOSSHClient`, `NIOSSHServer` and `NIOSSHPerformanceTester` examples
  and `Benchmarks/` are left out); the unused `strictConcurrencyDevelopment` switch is removed.

## New files

| File | What |
| --- | --- |
| `Key Exchange/SSHBigUInt.swift` | Fixed width integers; Montgomery multiplication (CIOS) and a Montgomery ladder with masked swaps and a masked final subtraction (no branch or index on secret bits). |
| `Key Exchange/DiffieHellmanGroups.swift` | RFC 2409 group 2 (group1), RFC 3526 groups 14 and 16. |
| `Key Exchange/DiffieHellmanKeyExchange.swift` | diffie-hellman-group1-sha1, -group14-sha1, -group14-sha256, -group16-sha512 (client and server), -group-exchange-sha1/-sha256 (client only). 512 bit private exponents; 1 < f < p-1; group exchange p of 2048 to 8192 bits, odd, 1 < g < p-1. |
| `Key Exchange/SSHKeyDerivation.swift` | RFC 4253 section 7.2 keys with the key extension (K2 = HASH(K, H, K1)). |
| `Keys And Signatures/NIOSSHLegacyPublicKeys.swift` | RSA host keys (ssh-rsa, rsa-sha2-256, rsa-sha2-512) verified with the Security framework (PKCS#1 DER from the SSH blob), 1024 to 16384 bit moduli; DSA host keys (ssh-dss, 1024 to 3072 bit p, 160 bit q) verified with SSHBigUInt. Blobs are kept byte for byte. Verification only. |
| `TransportProtection/AESCBCCTRTransportProtection.swift` | aes128/192/256-ctr, aes128/192/256-cbc, 3des-cbc (CommonCrypto) with hmac-sha2-256, hmac-sha2-512, hmac-sha1, hmac-sha1-96, hmac-md5, hmac-md5-96 (encrypt-and-MAC). Length checked in the first block; MAC compared in constant time before padding or payload is read. |
| `User Authentication/KeyboardInteractive.swift` | RFC 4256 public types and delegate protocols (client answers, server challenges). |
| `NIOSSHNegotiatedAlgorithms.swift` | What a key exchange agreed on, and which names are weak. |

## Changes to upstream files

| File | Change | Why |
| --- | --- | --- |
| `Constants.swift` | `bundledTransportProtectionSchemes` = AES-GCM, then `legacyTransportProtectionSchemes` (the CTR/CBC list). | Offer the new ciphers, modern first. |
| `SSHClientConfiguration.swift` | `keyExchangeAlgorithms: [String]?`, `algorithmsNegotiated` callback. | Restrict for tests; report the negotiated set. |
| `SSHServerConfiguration.swift` | `keyExchangeAlgorithms: [String]?`. | Restrict the test server. |
| `NIOSSHError.swift` | `keyExchangeNegotiationFailure(_ diagnostics:)`, `passwordChangeRequested`, public `diagnosticMessage`. | Plain error text. |
| `SSHMessages.swift` | `KeyExchangeECDHInitMessage.kind` (30 ECDH/KEXDH, 32 GEX init, 34 GEX request); `KeyExchangeECDHReplyMessage.isGroupExchangeReply` (33); new `keyExchangeDHGroupExchangeGroup` (31 when the body is exactly two strings and the first is not a host key); `userAuthInfoRequest` (60 when the body has the RFC 4256 shape and is used up exactly), `userAuthInfoResponse` (61), `userAuthPasswordChangeRequest` (60 when two strings, the first not a key algorithm and the second a language tag); `UserAuthRequestMessage.Method.keyboardInteractive`. | Message numbers 31 and 60 mean different things in different exchanges; the shape tells them apart, and the state machines reject a message that does not fit the exchange in progress. |
| `Key Exchange/EllipticCurveKeyExchange.swift` | `receiveGroupExchangeGroup` protocol requirement with a throwing default; key derivation uses `SSHKeyDerivation.expand` (key extension). | Upstream truncated a single digest: wrong for hmac-sha2-512 after SHA-256 and for any 32 byte key after SHA-1. |
| `Key Exchange/SSHKeyExchangeStateMachine.swift` | Order: curve25519 first, NIST curves, then group16, gex-sha256, group14-sha256, group14-sha1, gex-sha1, group1; host keys add rsa-sha2-512, rsa-sha2-256, ssh-rsa, ssh-dss; per role key exchange list (servers never offer group exchange, configured list honoured); duplicate cipher and MAC names removed; AEAD ciphers accept any MAC; `handle(keyExchangeDHGroupExchangeGroup:)`; `send(keyExchangeInit:)` accepts the GEX init; the host key must have the key type of the negotiated algorithm (RFC 8332: rsa-sha2-* use ssh-rsa keys) and the signature must be made with the negotiated algorithm; negotiation failures say which category and what the peer offered; the client's `algorithmsNegotiated` is called. | Group exchange and RSA host keys; RFC 8332 binding. |
| `Connection State Machine/SSHConnectionStateMachine.swift` | Routes the GEX group in the four key exchange states; routes keyboard-interactive and password change messages in user authentication (in and out). | New messages. |
| `Connection State Machine/Operations/AcceptsKeyExchangeMessages.swift`, `AcceptsUserAuthMessages.swift`, `SendsUserAuthMessages.swift` | Receive and send helpers for the new messages. | New messages. |
| `User Authentication/UserAuthenticationMethod.swift` | `.keyboardInteractive` method bit (not in `.all`), offer and request cases, `infoRequest` response. | RFC 4256. |
| `User Authentication/UserAuthenticationStateMachine.swift` | Client: INFO_REQUEST only while a keyboard-interactive request is in flight, answered through `NIOSSHClientKeyboardInteractiveDelegate` (empty answers without it); PASSWD_CHANGEREQ ends the login with `passwordChangeRequested`. Server: challenge from `NIOSSHServerKeyboardInteractiveDelegate`, the INFO_RESPONSE counts as the next request. | RFC 4256 both ways (the server side is used by the tests and the AnsiView test server). |
| `Keys And Signatures/NIOSSHPublicKey.swift` | `BackingKey.rsa`, `.dsa`; their prefixes, equality, hashing, wire read and write (exact blob), signature checks; `keyType(forHostKeyAlgorithm:)`; `knownAlgorithms` gains ssh-rsa and ssh-dss. | RSA and DSA host keys. |
| `Keys And Signatures/NIOSSHSignature.swift` | `BackingSignature.rsa(algorithm, bytes)`, `.dsa(bytes)`; read and write; `algorithmName`. | Same. |
| `Keys And Signatures/NIOSSHCertifiedPublicKey.swift` | A `preconditionFailure` arm for RSA and DSA base keys (certificates of those types are never read). | Exhaustive switch. |

## Changes to upstream tests

- `HostKeyTests.testUnrecognisedKey` and `testUnrecognisedSignature` used `ssh-rsa` as the example
  of an unknown algorithm; they now use `ssh-unknown-type`.
- `UserAuthenticationStateMachineTests`: four `switch` statements over the server's response gain
  a failing `.infoRequest` arm; two comments had em-dash characters, replaced by commas (AnsiView's
  repository rule).

## Not done (deliberately)

- Encrypt-then-MAC (`-etm@openssh.com`) MACs, chacha20-poly1305 and strict key exchange
  (`kex-strict-*`): without -etm and chacha20 the Terrapin attack (CVE-2023-48795) does not apply.
- Signing with RSA or DSA keys (no RSA user keys, no RSA host keys for the server side).
- blowfish-cbc, arcfour, cast128, twofish, umac, diffie-hellman-group18-sha512 and the
  sntrup761/mlkem hybrids: not offered by any BBS server measured or researched.
- CBC padding oracle hardening of the "discard a random amount before disconnecting" kind
  (OpenSSH after CPNI-957037): a malformed length ends the connection at once. CTR and GCM are
  preferred over CBC; see the AnsiView plan's rulings.
