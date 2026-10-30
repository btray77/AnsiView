# BBS compatibility

Which BBS families AnsiView works with, what each needs, and the evidence. Sections are kept by
the area that owns them (Terminal, SSH, and the screen designer's packages).

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
