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

## Screen designer

The owner asked to "work with ALL BBSes". AnsiView's screen designer keeps every BBS package as data in a registry (`Packages/AnsiCore/Sources/AnsiCore/Screen/BBSPackages.swift`): its colour code syntax, its value and screen codes, its display file folder and names, and the sources they came from. Only what a real source documents is implemented; everything else is listed below as missing rather than guessed.

Sources were read on 2026-10-30 from the packages' own documentation, their distribution archives (mirrored on discmaster.textfiles.com, item 43430 "BBS_Software"), or their source code. "Third party" marks sources that are not the package's own.

### Adding a package

1. If its colour codes and value codes use a syntax family that already exists (`ColourSyntax`, `MacroSyntax` in `BBSPackages.swift`), add a `BBSPackageDefinition` to `BBSPackageRegistry.definitions` with its code table, file rules and sources, and add a test to `BBSRegistryTests.swift`. The renderer, the colour encoder, the code picker, the foreign code check, templates and export all pick it up.
2. If it uses a new syntax, add a case to the family enum and its branch in `BBSDisplay` (`codes(from:to:syntax:ice:)` to write, `Renderer.colourCode` or `Renderer.macroCode` to read), then step 1.

### Supported (20 packages)

| Package | Colour codes | Value / screen codes | Screen files AnsiView writes | Encodings and line ends | Sources |
|---|---|---|---|---|---|
| Synchronet | Ctrl-A letters, digits, H I E N | `@ALIAS@` and 25 more @-codes with `|L20`, `|Z3`, `|U`, `#` padding; Ctrl-A L ' > P D T | `text/menu/main`, `logoff`, `logon`; `text/answer`; `.ans` / `.msg`; `main.132col.ans` | CP437, `.utf8` files; SAUCE stops display | wiki.synchro.net custom:ctrl-a_codes, custom:atcodes, custom:menu_files, config:text_files; sbbs3 con_out.cpp, prntfile.cpp |
| Mystic BBS | `|00` to `|31` | `|UH |UN |BN |SN |TI |DA |ND |TL |CS |LO |UC |SL |VR |CL |CR |PA`; `|$L## |$R## |$C##` | `themes/<theme>/text/prelogon`, `logon1`, `newuser`, `logoff`; `name.c132.ans` | CP437 | wiki.mysticbbs.com displaycodes, display_files, themes |
| WWIV | hearts (Ctrl-C digit, new user defaults), `|00` to `|23`, `|#n` | `|@N |@R |@Y |@t |@/ |@% |@C |@l |@L |@!`, `|[J |[K` | `gfiles/welcome` (before logon), `logon`, `logoff`, `newuser`; `.ans` / `.msg` | CP437 | docs.wwivbbs.org cfg/displaying_text.md; wwiv bbs/application.cpp |
| ENiGMA1/2 | `|00` to `|31` | `%BN %SN %UN %UR %LO %UC %ND %DT %CT %TR %VN`, views `%TL1` and others | `art/themes/<theme>/MATRIX`, `WELCOME`, `MMENU`, `LOGOFF`, `PRELOGAD` | CP437, `.UTF8ANS`; SAUCE sliced at EOF | enigma-bbs.github.io art/mci, art/colour-codes, art/general, art/themes; core/art.js |
| PCBoard | `@Xbf` | `@USER@ @FIRST@ @CITY@ @BOARDNAME@ @SYSDATE@ @SYSTIME@ @NODE@ @TIMELEFT@ @NUMTIMESON@ @LASTDATEON@ @SECURITY@ @CONFNAME@ @CLS@ @PAUSE@ @MORE@`; `:30C` | names not documented: AnsiView suggests 8.3 names, marked "suggested" | not documented | PPEDOC.NG PPL Norton Guide (third party) |
| Wildcat! | `@bf@` | not documented | not documented (suggestions) | not documented | wiki.synchro.net custom:colors (third party) |
| Renegade | `|00` to `|23` | `%UN %RN %FN %BN %SN %ND %TI %DA %TL %LO %TC %SL %CL %LF %VR` | `MISC/PRELOGON`, `MISC/WELCOME` | not documented | Renegade 1.19 COMMON.PAS, LOGON.PAS |
| Telegard 3 | not supported (see below) | `~UH ~UR ~UF ~UA ~US ~CM ~SA ~SS ~CN ~SD ~ST ~SC ~SP ~SM` | not documented | not documented | TELEGARD tg309sp3.zip MCI.REF |
| Iniquity | `|00` to `|23` | `%UN %RN %LO %SL %TL %UC %BN %SN %ND %TI %DT`, `|CS |LF |PA` | `PRELOGON`, `WELCOME`, `LOGOFF` | not documented | INIQUITY inq26src.zip MCICODES.PAS, SHOWFILE.PAS, CONSTANT.PAS |
| Oblivion/2 | `|00` to `|23` | `%UN %RN %LO %TL %CS %UL %BN %SN %NN %DT %TM %PA` | `PRELOGON`, `WELCOME`, `GOODBYE` | not documented | OBLIVION2 obv2-240.zip OBV.DOC |
| Impulse | `%00` to `%15`, `%B0` to `%BF` | `%UN %RN %LO %TL %BN %SN %NN %DT %CL %PA %NL` | `WELCOME` | not documented | IMPULSE imp71.zip MCI.TXT, IMP.DOC |
| Celerity | `|k`...`|W`, `|S` swap, `|X` `|x` blink | `@USER@ @REALNAME@ @BBS@ @SYSOP@ @NODE@ @DATE@ @TIME@ @TIMELEFT@ @NUMCALLS@ @CLS@ @PAUSE@` with `:R50.`; `|D |T |P |H` | `*.WEL` welcome screens (your name) | 7 bit `.WTX` noted | CELERITY cel204r.zip CELERITY.TXT; wiki.synchro.net custom:colors |
| RemoteAccess | Ctrl-K `[bf` | Ctrl-F A W B O P 3 _, Ctrl-K O I J /; dot padding | `LOGO`, `WELCOME`, `NEWUSER1`, `GOODBYE` | not documented | REMOTEACCESS radoc252.zip RA.DOC |
| ProBoard | none in text files (ANSI) | Ctrl-F / Ctrl-K as RA plus `^F1`, `^KP`; `@ # %` padding | `INTRO`, `WELCOME`, `NEWUSER`, `GOODBYE` | not documented | PROBOARD pb_216.zip PB216.DOC |
| QuickBBS | none (ANSI) | Ctrl-F / Ctrl-K as RA | `WELCOME`, `GOODBYE` | not documented | QUICKBBS qdoc_261.zip MANUAL.DOC |
| Spitfire | none (ANSI) | `@NAME@ @FNAME@ @CITYSTATE@ @LASTCALL@ @SLEVEL@ @CLS@ @BEEP@` | `NEWUSER`, `GOODBYE`, `MAIN`, `BULLET` as `.CLR` | not documented | SPITFIRE sf351-2.zip SPITFIRE.DOC |
| Searchlight BBS | `\BK`...`\WH`, `\IV`, `\BI`, `\NO` | `\%N \%K \%A \%M \%S \%O \SB \FD` | `NEWUSER`, `LOGOFF` | 8 bit IBM characters noted | SEARCHLIGHT sldoc450.zip MANUAL.TXT |
| DayDream BBS | `|00` to `|23`, also reads `@X` and hearts | `~#HA ~#RN ~#LO ~#SE ~#TC ~#CN ~#DA ~#PA` | `display/iso/<name>.gfx` (no standard names) | conversion tables, code pages not named | github.com/ryanfantus/daydream typetext.c, config.html |
| Talisman | not documented (ANSI) | `@UNAME@ @UFULLNAME@ @ULOCATION@ @TIMELEFT@ @SECLEVEL@ @MSGCONF@ @PAUSE@` with `#` padding | `gfiles/<name>.ans` (no standard names) | SAUCE ignored | Wayback captures of talismanbbs.com/docs |
| Maximus (MECCA) | `[lightgreen on blue]`, `[blink]`, `[steady]` | `[user] [first] [realname] [city] [remain] [usercall] [sys_name] [sysop_name] [node_num] [date] [time] [cls] [enter] [more] [cleol]` | `misc/logo`, `welcome`, `newuser1`, `byebye` as `.mec` source | high bit IBM option only | github.com/sdudley/maximus docs/max_mast.txt, ctl/max.ctl |

No package documents its line ends; AnsiView writes CR LF by default (a profile can choose LF).

### Not yet supported, and what is missing

| Package | What was found | What is missing |
|---|---|---|
| Telegard colour codes | backtick plus two hex digits in shipped strings (`` `1F ``) | a value table; the nibble order is only inferred, so screens export with ANSI colours |
| Talisman colour codes | "pipe codes for colour" mentioned | the table (the source repository returns 404) |
| PCBoard file names | `GRAPH`, `SEC`, `LANG` search flags | the names and suffixes (WELCOME, NEWUSER, BULLETn, the "G" ANSI suffix) in a primary manual |
| Wildcat! macros and file names | colour codes only (third party) | Mustang's own manual |
| The Major BBS / Worldgroup | `.MSG` language blocks with raw ANSI and printf `%s` | no display codes of its own: ANSI export works, there is nothing more to map |
| Citadel-86 | banner, newuser, notice, unlog `.blb` help files | no colour or value codes |
| Dominion (WWIV family) | backtick codes, Ctrl-C and Ctrl-N colour sets | the second colour method is only partly described |
| Magicka | `@PAUSE@`, `name.<sl>.ans`, CP437 to UTF-8 conversion | colour and value codes |
| x84 | `|NN` "LORD codes" where 16 and up are 256 colour foregrounds | value codes, screen names; its pipes mean something else than Mystic's |
| Spitfire, ProBoard, QuickBBS colour codes | none in text files | (they use ANSI) |
| Synchronet `@GOTOXY@`, Mystic `|[X##`, cursor codes | documented | not in the catalogue: they move the cursor, which the preview does not simulate |

### Retro platforms

C64 PETSCII (Color 64, Image BBS), Atari ATASCII, Prestel / Viewdata Mode 7 and Apple II boards are handled by a separate terminal emulation plan. The seam for them: `TextEncoding` and the exporter's encoding step are the only places that assume CP437 bytes, and `ColourSyntax.none` lets a package carry no ANSI colour codes; a PETSCII package would add an encoding and a colour syntax family.

## Terminal

Owner's brief (2026-10-30): "I want to be able to work with ALL BBS's." Plan:
`docs/superpowers/plans/2026-10-30-ansiview-2.0-terminal-compat.md`. Every entry in the dialing
directory now has a **Terminal type**; the terminal window also has Terminal > Terminal Type to
switch during a call (what was received so far is replayed in the new type), and a bar suggests a
type when the first bytes look like another family (it never switches by itself).

### What each family needs (research)

| Family | Boards | What the caller needs | AnsiView |
|---|---|---|---|
| PC ANSI-BBS | Synchronet, Mystic, WWIV, PCBoard, Renegade, Telegard, ENiGMA | ANSI.SYS plus SyncTERM/CTerm extensions: `CSI ? 33 h` iCE colours, `CSI = n` status reports, `CSI < 0 c` capabilities, `CSI Ps1 ; Ps2 SP D` font select, DoorWay mode `CSI = 255 h`, DECRQM, speed `CSI Ps1 ; Ps2 * r`, 256 and 24 bit colour, CP437 | ANSI-BBS type (default) |
| DEC VT | Unix shells, Citadel, some door games | VT100/VT102/VT220: G0/G1 with DEC Special Graphics, SO/SI, DECCKM application cursor keys, origin and insert modes, DA replies | VT100, VT220 |
| Avatar | RemoteAccess, ProBoard, Maximus (FidoNet era) | AVT/0 (FSC-0025) and AVT/0+ (FSC-0037): ^L, ^Y repeat, ^V commands for attributes, movement, scroll areas, fills, pattern repeat | Avatar (AVT/0+) |
| RIPscrip | Telegard/Renegade era graphics, AmiExpress offers it | RIPscrip 1.54: `!|` lines, MegaNums, BGI drawing, fills, text, palette, mouse fields and buttons, `ESC[!` query answered `RIPSCRIP015400` | RIPscrip |
| Commodore 64/128 | Color 64, Image BBS, C*Base, Synchronet PETSCII ports 64 and 128 | PETSCII control and colour codes, two character sets (lower case set by default), reverse, 40x25 (C128 VDC 80x25 with its RGBI palette, flash) | PETSCII (C64), PETSCII (C128 80 col) |
| Atari 8-bit | BBS Express, Phorem XE, Carina | ATASCII: 0x9B end of line, cursor codes that wrap, inverse in bit 7, ESC prints the next code, 40x24 | ATASCII (Atari) |
| Viewdata / Prestel | Telstar, NXtel, Weather Viewdata, The Gongpit | 40x24 serial attributes (ESC 0x40-0x5F or 0x80-0x9F), set-at and set-after, mosaics contiguous and separated, hold, double height, conceal and reveal, flash, wrapping cursor, `#` key sent as 0x5F | Viewdata / Prestel |
| BBC Mode 7 | BeeBS, Premiere BBS on a BBC Master | Teletext attributes in 0x80-0x9F, VDU codes (31 x y, 12, 30, 8-11, 127), the BBC's #/_/` swap, scrolling | Mode 7 (BBC Micro) |
| Apple II | GBBS Pro, ProLine, Warp Six | ASCII with the high bit set, CR new line, inverse and the 80 column card codes (^L, ^Y, ^], ^K, ^^ x y) | Apple II (80x24 default) |
| Amiga | AmiExpress (/X), Ami-Express telnet | ANSI with ISO 8859-1 text, Topaz font, 0x9B as CSI, LF returns the carriage, `CSI 0 SP q` window report, `CSI SP p` cursor | Amiga ANSI |
| Atari ST | Some ST boards | VT52 | not done (see coverage) |
| TRS-80 | very few boards | plain ASCII, 64x16 | covered by ANSI-BBS or VT100 with a smaller size; no TRS-80 font |
| IEMSI | AmiExpress (seen live), Maximus, RemoteAccess, Mystic | `**EMSI_IRQ8E08` from the BBS, the terminal answers `**EMSI_ICI` with name, password and terminal | opt in per entry ("IEMSI login") |
| Telnet over TLS | Mystic, Wildcat and some others on port 992 (stock Synchronet has no TLS telnet) | TLS, usually a self signed certificate | Telnet "Secure (TLS)" toggle, trust on first use |

Sources (read by the research agents on 2026-10-30; copies of the spec texts are in the session scratchpad):
SyncTERM CTerm manual `cterm.adoc` (https://gitlab.synchro.net/main/sbbs/-/raw/master/src/conio/cterm.adoc, rendered at
https://syncterm.bbsdev.net/cterm.html) and `cterm.c`; RIPscrip 1.54 specification
(https://carl.gorringe.org/pub/code/javascript/RIPtermJS/docs/RIPscrip154.txt); FSC-0056 IEMSI
(http://ftsc.org/docs/fsc-0056.001); FSC-0025 and FSC-0037 (Avatar); C64 PETSCII to screen code table
(https://sta.c64.org/cbm64pettoscr.html); teletext character set (https://en.wikipedia.org/wiki/Teletext_character_set);
Telstar (https://glasstty.com/telstar/); Amiga console.device (https://wiki.amigaos.net/wiki/Console_Device);
Synchronet terminal server and PETSCII ports (https://wiki.synchro.net/server:terminal, https://wiki.synchro.net/howto:petscii);
the Telnet BBS Guide list for October 2026 (https://www.telnetbbsguide.com/bbslist/ibbs1026.zip) and the Synchronet BBS list
(https://www.synchro.net/sbbslist.html) for live boards.

### Terminal names sent (telnet TERMINAL-TYPE)

| Type | First name, then | Why |
|---|---|---|
| ANSI-BBS | ANSI, ANSI-BBS, VT100 | unchanged from plan 7 |
| VT100 / VT220 | VT100, VT102, ANSI / VT220, VT100, ANSI | |
| Avatar | AVATAR, ANSI | |
| RIPscrip | RIP, ANSI | the BBS also asks with `ESC[!` |
| PETSCII | PETSCII, then C64 or C128 | Synchronet `answer.cpp` checks for exactly `PETSCII` |
| ATASCII | ATASCII, ATARI | SyncTERM's name |
| Viewdata | PRESTEL, VIEWDATA | SyncTERM sends `Prestel` |
| Mode 7 | BBC, MODE7 | SyncTERM sends `Beeb7` (inferred acceptable; no board seen to check) |
| Apple II, Amiga | APPLE2, DUMB / AMIGA, ANSI | |

### Coverage

| Family | Status | Evidence | Not covered |
|---|---|---|---|
| ANSI-BBS (plan 7 behaviour) | done, unchanged | `TerminalRegressionTests`: seeded streams and the 61 file TWSUPP corpus digest identical to main 499f22c | |
| CTerm extensions | done | `CTermTests` (iCE mode 33, `CSI = 1/2/3 n`, `CSI 255 n`, `CSI < 0 c`, DECRQM, DoorWay keys, font select result, speed requests apply to the simulated baud); live: Synchronet 3.22 (vert) drew its ANSI logo after its probes | loadable fonts (DCS CTerm:Font), APC SyncTERM cache and JXL/PPM graphics, mouse reporting, status line, fonts other than CP437 (select answers "failed"); the DA reply stays plan 7's `CSI ? 1 ; 0 c` on purpose. New in ANSI-BBS (CTerm extensions, after review): origin mode `?6`, iCE `?33`, `CSI = n`, `CSI 255 n`, DECRQM; DECCKM `?1` stays VT only |
| VT100 / VT220 | done | `VTTerminalTests`; harness PNG `vt100` | VT52, double width lines, DECALN, keypad application mode, 132 column switching by sequence |
| Avatar | done | `AvatarTerminalTests` (split byte by byte, random 200 KB); harness PNG `avatar` | live: the RemoteAccess listed board now runs Mystic and sent ANSI only |
| PETSCII C64 | done | `PETSCIITerminalTests`; live Synchronet port 64 (Vertrauen logo, lower case set) and Color 64 / Image BBS 64 greeting | colour keys with the C= key (Control 1-8 give the CTRL colours) |
| PETSCII C128 80 col | partial | live Synchronet port 128 art drawn with the VDC palette; flash 0x0F/0x8F | underline, C128 ESC sequences |
| ATASCII | done (engine) | `ATASCIITerminalTests`; live: BBS Express Pro greeting with 0x9B EOLs | inverse typing toggle key; live boards wait for Return before art |
| Viewdata / Prestel | done | `TeletextTerminalTests`; live Telstar (raw TCP) and NXtel front pages drawn with double height, colours and mosaics | ENQ identity reply, Prestel 7E1 ports (use the 8N1 ports) |
| Mode 7 | done | tests and harness PNG; live BeeBS sent only a bot check prompt | BBC graphics modes 0-6, VDU 23 character definitions |
| Apple II | done | `AppleIIAmigaTests`; live GBBS Pro and Warp Six greetings | MouseText glyphs, 40 column ProTERM emulation |
| Amiga | partial | live AmiExpress 5.5 (Fastline) greeting in Topaz style font | Amiga palettes (the ANSI colours stay VGA), `CSI > n m` background pen |
| RIPscrip 1.54 | partial | `RIPscripTests`; harness PNG of an original RIP menu with buttons; live Serion (Synchronet) sent the `ESC[!_` probe (measured); AnsiView's `RIPSCRIP015400` answer is unit tested but was not logged on the wire (inferred sent); the board shows RIP only after login | icons (1I/1W), scene and file queries (1R/1F), block transfers (9), BGI stroke fonts (AnsiView's 8x8 font is scaled), button group/radio flags, 1G copy region |
| Detection | done | `TerminalDetectorTests`; harness PNG `detect-petscii-on-ansi` and `detect-switched` | |
| Telnet over TLS | done (local proof) | `telnetOverTLSWithASelfSignedCertificate` against OpenSSL 3.0.4 `s_server`: first use asks, same certificate silent, changed refused, declined refused | live: the two listed TLS boards refused (cfbbs.net:992) or did not answer (bbs.buema.ch:922) |
| IEMSI | done (local proof) | `IEMSITests` (CRC-16 and CRC-32 check values, ICI packet, NAK retries, double ACK); live: AmiExpress sends `**EMSI_IRQ8E08` | not run against a real BBS (it would send a password) |
| Sixel, iTerm2 images | not done | | time; would need an image layer per cell region |
| VT52 (Atari ST) | not done | | |
| TLS client certificates | not done | | |

### Live observations (read only)

On 2026-10-30 each board was called once with the real terminal code (TerminalViewController in an
offscreen harness), for 25 seconds, typing nothing: only telnet negotiation and the emulator's own
status replies were sent. The captures were saved, IPv4 addresses replaced by `x`, and rendered again
to PNG. Byte counts are what the screen received.

| Board | Address | Type | Bytes | What was seen |
|---|---|---|---|---|
| Vertrauen (Synchronet 3.22) | vert.synchro.net:64 | PETSCII (C64) | 631 | PETSCII logo, title bar, "[Hit a key]" in the lower case set |
| Vertrauen | vert.synchro.net:128 | PETSCII (C128 80 col) | 2844 | 80 column PETSCII art in VDC colours |
| Commodore 64 BBS (Image BBS 64 v3 on real hardware) | commodore64bbs.com:6464 | PETSCII (C64) | 290 | greeting in lower case set PETSCII |
| same | same | ANSI-BBS | 430 | the board probes, finds ANSI and asks "Are You in 80 Columns?" |
| Area 52 (BBS Express Pro) | area52.tk:5200 | ATASCII | 21 | "ATA", 0x9B, "Press Return", 0x9B |
| Atari BBS Gateway | ataribbs.ddns.net:6502 | ATASCII | 31 | ASCII "Press RETURN to continue..." |
| TELSTAR | glasstty.com:6502 (raw TCP) | Viewdata | 553 | front page: double height title, coloured "TELSTAR", date and time |
| NXtel | nx.nxtel.org:23280 | Viewdata | 523 | front page: mosaic "nxtel" logo, double height |
| BeeBS II | beebs.ddns.net:6502 | Mode 7 | 47 | plain text bot check |
| Sanctum II (GBBS Pro 1.3j) | sanctumbbs.com:6502 | Apple II | 1449 | welcome text and account prompt (laid out for 80 columns) |
| Captain's Quarters (Warp Six) | cqbbs.ddns.net:6502 | Apple II | 1125 | welcome text |
| Fastline (AmiExpress 5.5.0) | fastline.nu:1541 | Amiga ANSI | 523 | `**EMSI_IRQ8E08`, node list, "ANSI, RIP or No graphics (A/r/n)?" |
| Federation Apocalypse | fedapoc.tel:2301 | Avatar | 2699 | Mystic 1.12 bot check in ANSI (no Avatar codes) |
| Z80 (Citadel) | bbs.probosci.de:3339 | VT100 | 67 | "Press any key to enter BBS..." |
| Vertrauen | vert.synchro.net:23 | ANSI-BBS | 6239 | full ANSI logo after Synchronet's terminal probes |
| The Realm of Serion (Synchronet 3.18) | connect.serionbbs.com:23 | RIPscrip | 1191 | `ESC[!_` RIP probe, ANSI skull, character name prompt |
| Cold Fusion | cfbbs.net:992 | Telnet over TLS | 0 | connection refused |
| Buema BBS | bbs.buema.ch:922 | Telnet over TLS | 0 | no answer (timed out) |

### Found along the way

- The bundled EGA 8x14 font rasterizes with a blank first row and last column (the full block 0xDB
  comes out 7x13), so SAUCE "IBM EGA" art shows thin gaps. Measured with `BitmapFont.named("IBM EGA").pixels(for: 0xDB)`.
  Not changed here (it would change existing renders); the RIPscrip text layer uses the entry's font instead.
