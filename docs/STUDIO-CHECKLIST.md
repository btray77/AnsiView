# AnsiView Studio checklist

The owner's brief (2026-10-30): bring a TheDraw-class art editor, an ANSI music composer, ANSI animation, a screen designer and genuine BBS file transfer protocols into AnsiView. Decisions: the target is AnsiView (the caller side: viewer, editor, terminal), not a BBS server; the terminal supports telnet, SSH and WebSocket.

This file is the persistent record. Status values: **done** (merged to main, tested), **running** (an agent is building it now), **planned** (scheduled, not started), **partial** (merged but incomplete, see note), **not possible** (with the reason and the closest alternative).

Each row is updated when work merges. Nothing is marked done without a test or observed evidence named in the plan file it came from.

## 0. What already exists (inspected 2026-10-30, main at ee1763b, 366 tests)

| Area | Where | Notes |
|---|---|---|
| CP437 mapping, all 256 | `CP437.swift` | tested |
| VGA/EGA bitmap fonts | `BitmapFont.swift`, `Resources/Fonts` | Px437 fonts, CC BY-SA 4.0 |
| ANSI parser (file playback) | `AnsiTerminal.swift`, `TextAttributes.swift` | SGR, 256/24-bit, PabloDraw t, cursor, clear |
| Interactive terminal emulator | `TerminalEmulator.swift` | scroll regions, DSR replies, scrollback |
| Renderer | `AnsiRenderer.swift` | 8/9 px, aspect, iCE, blink, budgeted memory |
| Formats | `ArtFile.swift`, `BinaryFormats.swift`, `BBSCodes.swift`, `Sauce.swift`, `ArtWriter.swift` | .ans .asc .txt .nfo .diz .ice .bin .xb .adf .idf, PCBoard/Wildcat/Avatar, SAUCE read and write |
| Editor (basic) | `EditCanvas.swift`, `CanvasEditor.swift`, `App/AnsiEditor.swift` | typing, F-key block sets, half-block mouse paint, select, fill, undo, iCE, save .ans/.bin/.xb |
| Image to ANSI | `ImageToAnsi.swift`, `App/ImageImport*.swift` | v2 merged (item 61): live preview, OKLab, best character per cell, presets, Auto top 3, XBin fitted palette, batch, image drops |
| Telnet client | `Telnet.swift`, `BBSClient.swift`, `App/BBSTerminal.swift` | negotiation, NAWS, TTYPE, raw TCP |
| Playback speed / baud | `Playback.swift` | 300 to 115200 and unlimited |
| Export | PNG, JPEG, WebP, GIF, APNG, MP4, HTML, text, modern ANSI | |
| File transfers | XMODEM, YMODEM, ZMODEM, Kermit engines and terminal UI (`App/TerminalTransfers.swift`) | |
| ANSI music | `AnsiMusic.swift`, `PlayString.swift`, `MusicScheduler.swift`, synth, `App/Music*`, `App/ViewerMusic.swift`, `App/TerminalMusic.swift` | engine and editor merged; playback in viewer, terminal and MP4 export on branch `ansiview-2.0-music-playback` |
| TDF fonts | `TheDrawFont.swift`, `FIGletFont.swift`, `TextArt.swift`, `FontLibrary.swift`, `App/TextToASCII.swift`, `App/FontManager.swift` | TDF read/write, FIGlet, Text to ASCII, Font Manager |
| Screen designer / templates | none | |

## 1. Art editor

| Requirement | Status | Item / plan |
|---|---|---|
| CP437 full set, VGA fonts, 80 col default, configurable size | done | plan 6 |
| 16 colours, iCE | done | plan 6 |
| Character editing, keyboard and mouse | done (harness verified; live keyboard check needs owner) | plan 6 |
| Insert / overwrite / delete modes | done (harness; live check needs owner), item 60 |
| Palette management, fg/bg swap | done (harness; live check needs owner), item 60 |
| CP437 character picker | done (harness; live check needs owner), item 60 |
| Configurable drawing characters / brushes | done (harness; live check needs owner), item 60 |
| Freehand drawing | done (half blocks) | plan 6; character brush in editor v2 |
| Lines, rectangles, filled rectangles | done (harness; live check needs owner), item 60 |
| Box drawing, single/double, auto-joining | done (harness; live check needs owner), item 60 |
| Flood fill, colour replace, character replace | done (harness; live check needs owner), item 60 |
| Text insertion | done | plan 6 |
| Select, copy, cut, paste (cells, text, ANSI, image; editor and viewer; Copy As; floating and transparent paste; paste images) | done (harness verified; live check needs owner) | copy and paste, merged 39ef769 |
| Move and resize selection | done (harness; live check needs owner), item 60 |
| Mirror, flip, rotate (with box-character remapping) | done (harness; live check needs owner), item 60 |
| Block operations | done (harness; live check needs owner), item 60 |
| Undo / redo | done | plan 6 |
| Layers (flattened on save, kept in a sidecar project file) | done (harness; live check needs owner), item 60 |
| TDF font import, preview, insert, manage collection | done (harness; live check needs owner): parser and writer (8,634 collection fonts round trip), 19 outline styles, Text Art insert as a floating paste, Font Manager | fonts |
| Other font formats (FIGlet .flf) | done (harness; live check needs owner): figlet 2.2.5 layouts matching its reference output, vertical layouts, 18 bundled distribution fonts (New BSD); Text to ASCII gallery (owner request) | fonts |

## 2. ANSI music

| Requirement | Status | Item / plan |
|---|---|---|
| Research historical syntax (BASIC PLAY strings after `ESC[M`, `ESC[MF`/`MB`, `ESC[N`, SyncTERM `ESC[\|`, terminated by 0x0E) | done (harness; live sound check needs owner) | music core |
| Parser and playback (square-wave PC speaker style synth) | done (harness; live sound check needs owner) | music core |
| Playback during viewing and in the terminal | done (harness: viewer at 2400 baud holds during MF and draws during MB, terminal in split chunks, MP4 sound track measured; Quick Look silent; live sound check needs owner) | music playback (`2026-10-30-ansiview-2.0-music-playback.md`) |
| Visual piano roll / timeline editor, keyboard entry | done (harness; live sound check needs owner) | music core |
| Text command editing, two-way conversion | done (harness; live sound check needs owner) | music core |
| Import from and embed into ANSI files, extract | done (harness; live sound check needs owner) | music core |
| Reusable sequence library | done (harness; live sound check needs owner) | music core |
| MIDI export as an extra (not a replacement) | done (harness; live sound check needs owner) | music core |

## 3. File transfers

| Requirement | Status | Item / plan |
|---|---|---|
| XMODEM (checksum), XMODEM-CRC, XMODEM-1K | done: engine both directions vs lrzsz lsx/lrx; terminal UI both directions vs lsx/lrx over telnet, SSH, WebSocket (harness, SHA-256 match; live app check needs owner) | transfers core |
| YMODEM, YMODEM batch | done: engine and terminal UI both directions vs lrzsz lsb/lrb (telnet, raw, WebSocket); YMODEM-G download vs lsb, upload only vs our own `ansixfer` receiver (lrb never asks for G) | transfers core |
| ZMODEM (with resume and auto-start detection) | done: terminal UI both directions vs lsz/lrz over telnet, raw TCP, SSH, WebSocket (and telnet inside WebSocket, and a BBS refusing BINARY), ask bar on auto-start (download and upload), cancel keeps the .part and the next download resumes (harness) | transfers core |
| Kermit | done: terminal UI both directions vs C-Kermit 9.0.302 over telnet (also with BINARY refused), raw TCP, SSH; ask bar on its S packet and receiver NAK; no text mode/RESEND/server mode | transfers core |
| Progress, speed, ETA, logging, errors, cancel and cleanup | done (harness): panel with file N of M, bytes, total, bar, speed, ETA, protocol, block size, errors and retries, resume offset, BINARY warning; summary with SHA-256, folder, Reveal in Finder, log; per entry transfer log (Terminal > Transfer Log); Escape or Cancel sends CAN, ZMODEM keeps its .part, others remove it | transfers UI (`2026-10-30-ansiview-2.0-transfers-ui.md`) |
| Path traversal protection, size limits, downloads folder in sandbox | done in engine (sanitizer, limits, marked .part resume); download folder per entry or a default, kept as a security scoped bookmark with a write check (sandboxed write after picking needs an owner check in the real app) | transfers core + transfers UI |
| Interop proof against independent implementations (lrzsz `sz`/`rz`, C-Kermit) | done: `Scripts/transfer-interop.sh`, 347/347 on the coordinator's run | transfers core |
| Over telnet (with IAC escaping), raw TCP, SSH, WebSocket | done (harness, local servers): telnet with BINARY asked both ways and IAC escaping, raw TCP, SSH, WebSocket; pull mode with write completions (backpressure); RLogin uses the same path but was not run | transports + transfers |
| Others: YMODEM-G and ZMODEM-8k done; Hydra recommended if bidirectional is wanted; SEAlink low priority; BiModem and Puma have no public spec | researched | transfers core |

## 4. Screen designer

| Requirement | Status | Item / plan |
|---|---|---|
| Templates: main menu, login/welcome, goodbye, bulletins, message and file headers, door menus, ads, loading screens | done (harness PNG of the gallery; a test exports every template for every package at 80 and 132 columns with no layout warning; live check needs owner) | screen designer (`2026-10-30-ansiview-2.0-screen-designer.md`) |
| Reusable components (headers, frames, hotkey legends) | done (19 built in plus Save Selection as Component, inserted as a floating paste; harness) | screen designer |
| BBS display codes insert, preview with sample values | done for 20 packages from cited sources (`docs/BBS-COMPAT.md`); code picker, Sample Values, Sample Values Preview (harness) | screen designer |
| Colour codes both ways (package codes vs ANSI) | done: native colour export and Open with BBS Codes, round trip tested for every package with colour codes | screen designer |
| All BBS packages (owner request) | 20 supported as registry data; packages without real sources listed as not yet supported in `docs/BBS-COMPAT.md`; retro platforms (PETSCII, ATASCII, Viewdata) left to the terminal emulation plan with a seam | screen designer |
| Export to BBS packages' text/menu folders with the right file names | done: profiles with folder bookmark, documented names per package (others marked suggested), .bak, never overwrites unasked; end to end export into scratch Synchronet and Mystic layouts (harness); sandboxed write after choosing the folder needs an owner check in the real app | screen designer |
| Screen set with status | done (harness: exported, changed in the BBS folder) | screen designer |
| Caller preview at chosen baud with the terminal renderer | done (harness PNG, substituted values; layout warnings) | screen designer |
| "Use immediately in the BBS" | not possible as stated: AnsiView is not a BBS host. Done instead: export into a configured BBS install folder, and Upload via Terminal with the dialing directory entry's protocol (upload not run against a real BBS; needs owner) | screen designer |

## 5. Animation

| Requirement | Status | Item / plan |
|---|---|---|
| Frame editor, copy previous frame, onion skin, timeline | done (harness verified; live check needs owner), item 59 |
| Record drawing sequences | done (record mode timestamps edits; As drawn export replays pauses), item 59 |
| Playback speed, baud 300 to 28800 and more | done for playback (plan 2); animation preview and export at 300 to 115200 baud, item 59 |
| Edit individual frames / commands | done: each frame is a full editor canvas with layers; per frame delay; the as drawn edit order is kept per frame, item 59 |
| Import existing animated ANSI into frames | done: 15 of 15 animated corpus files split with exact replay, item 59 |
| Export compatible sequences; timing via padding only, custom extensions labelled | done: diff export in 3 orders, CR padding delays, frame markers off by default and labelled; GIF and MP4 through the exporters, item 59 |

## 6. Formats

| Format | Status |
|---|---|
| .ANS .ASC .TXT .BIN .XB SAUCE | done (read and write) |
| .TDF | done (read and write), .flf read |
| .ICE .ADF .IDF .PCB, Avatar, Wildcat | read done; write planned where useful |
| Unsupported data preserved, never silently dropped (SAUCE comments, unknown SAUCE fields, trailing data) | done: SAUCE fields kept, losses shown on open/save (item 60) |

## 7. Interface

| Requirement | Status |
|---|---|
| Toolbars, palette, zoom | done (basic) |
| Pan, grid, cursor position indicator | done (item 60) |
| Full screen editing, retro DOS preview mode | done in harness (full screen not observed), item 60 |
| Configurable keyboard shortcuts | done (item 60) |
| Context sensitive help, tooltips, glossary | planned (item 62) |
| Light and dark themes | system appearance today; retro theme planned |
| Font browser, character picker | done: Font Manager and Text to ASCII gallery (fonts); character picker (item 60) |

## 8. Rendering consistency

| Requirement | Status |
|---|---|
| Editor, preview and terminal share one renderer and font set | done (AnsiRenderer) |
| Shared SGR handling between player and terminal | done (plan 7 TextAttributes, md5-identical renders of the corpus) |

## 9. Transports

| Transport | Status |
|---|---|
| Telnet, raw TCP | done (plan 7) |
| SSH (password and key, host key trust on first use) | done (merged) (local NIO SSH test server: password, empty password, Ed25519 key with passphrase, first use and changed key). Classic BBS servers: done on branch ansiview-2.0-ssh-compat (vendored swift-nio-ssh with DH group1/14/16 and group exchange, RSA and DSA host keys, AES-CTR/CBC and 3DES with HMAC, keyboard-interactive, none first, legacy encryption note; every algorithm against OpenSSH 10.2 sshd, keyboard-interactive against the NIO test server, ZMODEM over legacy SSH, read only handshakes with Synchronet and ENiGMA boards up to the host key question; docs/BBS-COMPAT.md) |
| WebSocket (ws and wss) | done (merged) (local server: binary and text frames, subprotocol, telnet inside, HTTP 404, self signed wss error) |
| RLogin | done (merged) (local server: handshake bytes, refusal; no window size, see README) |
| Byte clean channel for transfers | done: all 256 byte values measured end to end over SSH, WebSocket and RLogin |
| Telnet over TLS (telnets, port 992) | done on branch `ansiview-2.0-terminal-compat` (local OpenSSL 3 s_server: self signed first use asks, same certificate silent, changed refused); no live TLS board answered (the two listed refused or timed out) |

## Terminal dialing directory

| Requirement | Status |
|---|---|
| Retro phonebook (list, tags, search, sort, notes, call stats), per-BBS settings, Keychain passwords, expect/send auto-login, dial queue with redial and busy detection, macros, JSON and SyncTERM import/export | done (local test server; real-BBS logins need owner), merged item 63 |
| SSH keys, RLogin users, WebSocket fields, per protocol hints, SyncTERM SSH/RLogin import | done (merged) |
| IEMSI | done on branch `ansiview-2.0-terminal-compat`, opt in per entry (unit tested handshake; a live AmiExpress board was seen sending `**EMSI_IRQ8E08`; not run against a real login) |
| TLS client certificates | done on branch `ansiview-2.0-terminal-gaps`: per entry Keychain identity (local OpenSSL s_server with -Verify 1 accepts it and refuses a connection without); Keychain access from the sandboxed app not tried with a real identity (needs owner) |
| Sixel and iTerm2 inline pictures | done on branch `ansiview-2.0-terminal-gaps` (decoders fuzzed, memory bounded, harness PNG `ansi-pictures`); no live board sending pictures was found |

## Terminal emulations (branch `ansiview-2.0-terminal-compat`, docs/BBS-COMPAT.md "Terminal")

| Family | Status |
|---|---|
| ANSI-BBS with SyncTERM/CTerm extensions (iCE mode, status reports, DoorWay, DECRQM, speed requests) | done; plan 7 behaviour pinned byte identical (seeded streams and TWSUPP corpus digests) |
| VT100 / VT220 | done (harness) |
| Avatar AVT/0+ | done (harness) |
| PETSCII C64 | done (harness, live Synchronet port 64 and a Color 64 / Image BBS board) |
| PETSCII C128 80 column | done (live Synchronet port 128; underline and the screen editor ESC codes added on `ansiview-2.0-terminal-gaps`, harness PNG `c128-underline`) |
| ATASCII | done (harness; live boards wait for Return before art); inverse typing key (Terminal > Atari Inverse Video Key) |
| Viewdata / Prestel | done (harness, live Telstar and NXtel) |
| BBC Mode 7 | done (harness; live board showed only a bot check); VDU 22 modes 0-6 with text colours and PLOT graphics (move, line, point, filled triangle, GCOL, CLG) on `ansiview-2.0-terminal-gaps`, harness PNG `bbc-mode1`; no VDU 23 character definitions |
| Apple II | done (harness, live GBBS Pro and Warp Six); MouseText (32 original pictures) on `ansiview-2.0-terminal-gaps`, harness PNG `appleii-mousetext` |
| Amiga ANSI | done for what was seen (Topaz style font, ISO 8859-1, live AmiExpress); colour 3 is dark yellow, not VGA brown; other Amiga palette differences are terminal program settings (inferred), not done |
| RIPscrip 1.54 (roadmap 57 RIPscrip viewing) | done on `ansiview-2.0-terminal-gaps`: icons from a chosen folder, session icons (1W), scenes (1R), file queries (1F), copy region (1G), text variable queries, block transfer requests reported, original stroke fonts 1-10 sized from the spec's metric tables, button styles, radio and check box groups, hotkeys, per feed drawing budget; .RIP files in the viewer, Quick Look (harness PNG) and ansirender. No RIP seen live before login |
| First bytes detection (suggest only) | done (harness) |
| Original platform fonts (PETSCII, ATASCII, teletext, Apple II, Topaz style) | done, MIT, docs/FONTS.md |
| VT52 (Atari ST extensions) | done on `ansiview-2.0-terminal-gaps` (tests, harness PNG `vt52`); no live VT52 board found |
| Mouse reporting (CSI ? 9/1000/1006 h), CTerm loadable fonts | done on `ansiview-2.0-terminal-gaps` (unit tests; no live board asked) |

## 16colo.rs browsing

| Requirement | Status |
|---|---|
| Preview pane on selection (real art via AnsiView renderer, SAUCE caption, x1 fallback), pack thumbnail grid, pack row pictures, grid/list toggle in browser and galleries, 200 MB disk cache, offline mode | done (harness and live 16colo.rs; live app check needs owner), items 35-37 |

## Browsing, viewing and collections (plan 9, items 38 to 47)

| Requirement | Status |
|---|---|
| Search text inside art: viewer find bar, gallery search, library search (item 38) | done on branch `ansiview-2.0-plan-9` (core tests, harness; live app check needs owner) |
| Side by side compare with differing cells tinted (item 39) | done on branch (core tests, harness PNG) |
| Smooth auto scroll for tall art (item 40) | done on branch (core tests, harness) |
| Minimap strip for tall art (item 41) | done on branch (core tests, harness PNG) |
| Palette files (.pal, .gpl, .act, XBin/ADF/IDF) switched live (item 42) | done on branch (core tests, harness) |
| Library: tags, favourites, ratings, smart folders (item 43) | done on branch (core tests, harness PNGs) |
| Artist and group pages from SAUCE plus 16colo.rs (item 44) | done on branch (core tests with API shaped fixtures; live 16colo.rs lookup from the app needs owner) |
| Duplicate finder, rendered cell hash plus byte hash, Trash only after confirmation (item 45) | done on branch (core tests, harness) |
| FILE_ID.DIZ and NFO shown when a pack opens (item 46) | done on branch for galleries (harness); 16colo.rs browser FILE_ID preview built, not exercised against the network |
| Background indexing and thumbnailing of very large folders and packs (item 47) | done on branch (10,000 piece measurement in plan 9) |

## Running right now

