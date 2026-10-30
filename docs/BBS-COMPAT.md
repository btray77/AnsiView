# BBS compatibility

What AnsiView's terminal can reach, per BBS package. Labels: **measured** (a connection or probe
was run and its output recorded), **from source** (read in the package's source code), **from
docs** (the package's documentation), **inferred** (reasoned from the above, not checked).

## SSH

AnsiView's SSH (the vendored `Packages/swift-nio-ssh-bbs`, see its `PATCHES.md`) offers, modern
first and weak last:

- Key exchange: curve25519-sha256 (and @libssh.org), ecdh-sha2-nistp384/256/521,
  diffie-hellman-group16-sha512, diffie-hellman-group-exchange-sha256, diffie-hellman-group14-sha256,
  diffie-hellman-group14-sha1, diffie-hellman-group-exchange-sha1, diffie-hellman-group1-sha1.
- Host keys: ssh-ed25519, ecdsa-sha2-nistp384/256/521, rsa-sha2-512, rsa-sha2-256, ssh-rsa, ssh-dss.
- Ciphers: aes256-gcm@openssh.com, aes128-gcm@openssh.com, aes256/192/128-ctr, aes256/192/128-cbc, 3des-cbc.
- MACs: hmac-sha2-256, hmac-sha2-512, hmac-sha1, hmac-sha1-96, hmac-md5, hmac-md5-96.
- Login: none, public key (Ed25519, ECDSA), password, keyboard-interactive (Keychain password for a
  plain password prompt, a sheet for anything else, including a new password on first login).

Not offered (no BBS stack below needs only these): chacha20-poly1305, the -etm MACs, umac,
blowfish-cbc, arcfour, cast128, diffie-hellman-group18-sha512, sntrup761 and mlkem hybrids, plain
`aes128-gcm` / `aes256-gcm` (non @openssh.com names), hmac-sha2-*-96, hmac-ripemd160.

### Matrix

| BBS package | SSH stack | Offered (key exchange / host key / cipher / MAC) | AnsiView result |
| --- | --- | --- | --- |
| Synchronet | cryptlib 3.4.8 bundled in `3rdp/dist/cryptlib.zip`, about 100 `3rdp/build/cl-*.patch` (from source: gitlab.synchro.net/main/sbbs) | Source (`session/ssh2_algo.c` with Synchronet's patches): ecdh-sha2-nistp256, gex-sha256, gex-sha1, group14-sha256, group14-sha1 / ecdsa-sha2-nistp256, rsa-sha2-256, ssh-rsa, ssh-dss / aes128-cbc, aes256-cbc, aes128-ctr, aes256-ctr, 3des-cbc / hmac-sha2-256, hmac-sha1 (plus -etm variants, inferred on). Measured on vert.synchro.net: gex-sha256, gex-sha1, group14-sha256, group14-sha1 / rsa-sha2-256, ssh-rsa / aes-cbc, aes-ctr, 3des / hmac-sha2-256, hmac-sha1 | **Measured:** read only handshake to the host key question: gex-sha256, rsa-sha2-256, aes256-ctr, hmac-sha2-256 (no legacy note), RSA 1024 bit key SHA256:IEmrlaJkxYtvBD/YDiPjNmx1ld3xIU9H+9l+ZRIG61Y (equal to `ssh-keyscan` + `ssh-keygen -l`). The same offer list against OpenSSH 10.2 sshd logs in and runs a shell. |
| Another cryptlib board (20forbeers.com:1338) | cryptlib (banner `SSH-2.0-cryptlib`) | Measured: gex-sha256, gex-sha1, group14-sha1 / rsa-sha2-256, ssh-rsa / aes128-cbc, 3des-cbc / hmac-sha2-256, hmac-sha1 | **Measured** once (library level): gex-sha256, rsa-sha2-256, aes128-cbc, hmac-sha2-256 (legacy note: aes128-cbc), RSA 2048 bit key SHA256:4376Eqq/I0kVxvJonir8v8Ed8HRE0QxlE/vOx8k/qXs, stopped at the host key. Later attempts timed out (the board stopped answering this address); the same offer list against sshd logs in. |
| Mystic BBS | cryptlib, supplied by the sysop (3.4.5 newest tested per the Mystic wiki) (from docs: wiki.mysticbbs.com/doku.php?id=cryptlib) | Inferred: stock cryptlib 3.4.x lists, as WWIV's copy below | Inferred: connects (every category overlaps). Not measured. |
| WWIV | cryptlib 3.4.5 in `deps/cl345`, `bbs/ssh.cpp` (from source: github.com/wwivbbs/wwiv) | Source: ecdh-sha2-nistp256, gex-sha256, gex-sha1, group14-sha256, group14-sha1 / ecdsa-sha2-nistp256, rsa-sha2-256, ssh-rsa, ssh-dss (WWIV makes an RSA key) / aes128-cbc, aes256-cbc, aes128-ctr, aes256-ctr, 3des-cbc / hmac-sha2-256, hmac-sha1 | Inferred: connects (same lists as the measured cryptlib boards). Not measured. |
| ENiGMA 1/2 | Node.js `ssh2` 1.17.0, algorithm lists from `core/config_default.js` (from source: github.com/NuSkooler/enigma-bbs) | Source and measured on xibalba.l33t.codes:44511: curve25519, ecdh, group14-sha1, group1-sha1 / RSA key: rsa-sha2-512, rsa-sha2-256, ssh-rsa / aes-ctr, aes-gcm (both name forms), aes-cbc, 3des-cbc / hmac-sha2-256/512, hmac-sha1, hmac-md5, -96 variants, ripemd160 | **Measured:** read only handshake to the host key question: curve25519-sha256, rsa-sha2-512, aes256-gcm@openssh.com (no legacy note), RSA 2048 bit key SHA256:bec46NQA1QBTzcoXXkvUIodqTW1J3iG+crjrBX7Hu8c (equal to `ssh-keyscan`). |
| Talisman | libssh (a fork at gitlab.com/robbiew/talisman uses `find_package(LibSSH)`; from source); version not found | Inferred libssh defaults: curve25519, sntrup761, ecdh, group18/16, gex-sha256, group14-sha256 / ed25519, ecdsa, rsa-sha2-512/256 / chacha20, aes-gcm, aes-ctr / -etm and plain hmac-sha2 | Inferred: connects through curve25519, Ed25519 or RSA, AES-GCM or CTR. Not measured. |
| Magicka | Not verified (release notes list an SSH server; libssh likely) | Unknown | Unknown; if libssh, as Talisman. |
| OpenSSH in front of a BBS (for example bbs.fozztexx.com) | OpenSSH 9.2p1 (measured banner) | Measured: sntrup761, curve25519, ecdh, gex-sha256, group16/18, group14-sha256 / rsa-sha2, ecdsa, ed25519 / chacha20, aes-ctr, aes-gcm / umac, hmac etm and plain | Inferred from the local OpenSSH 10.2 runs: curve25519, Ed25519, AES-GCM. |

Sources for the research rows: Synchronet `3rdp/dist` and `3rdp/build` at gitlab.synchro.net/main/sbbs;
WWIV `bbs/ssh.cpp` and `deps/cl345/session/ssh2.c`; ENiGMA `package.json`, `core/servers/login/ssh.js`,
`core/config_default.js`; `ssh2` `lib/protocol/constants.js`; libssh `src/kex.c`.

### Local proof (measured 2026-10-30, this Mac)

Every added algorithm, alone, against an unprivileged OpenSSH 10.2 `sshd` (key login, forced
shell printing a sample .ans, 8,816 bytes received with the same SHA-256 every time): all 6 key
exchanges, 3 RSA host key algorithms, 7 ciphers, 6 MACs, the key extension cases
(curve25519 + aes256-ctr + hmac-sha2-512, group14-sha1 + aes256-cbc + hmac-sha2-512), the two
cryptlib offer lists, the oldest set (group1-sha1, ssh-rsa, 3des-cbc, hmac-md5-96), and server
initiated rekeying every kilobyte (group exchange with CTR, group14-sha1 with CBC). Password, none
and keyboard-interactive logins (with a second prompt, a password change, cancel) against the
NIO test server; a 1 MiB ZMODEM download over SSH with group14-sha1, aes128-cbc, hmac-sha1, SHA-256
equal. ssh-dss is checked only against OpenSSL made signatures (OpenSSH 10 has no DSA).
