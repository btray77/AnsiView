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
| Templates: main menu, login/welcome, goodbye, bulletins, message and file headers, door menus, ads, loading screens | planned | screen designer |
| Reusable components (headers, frames, hotkey legends) | planned | screen designer |
| BBS display codes (Synchronet Ctrl-A and @-codes, Mystic pipe and MCI, PCBoard @X, Wildcat) insert, preview with sample values | planned | screen designer |
| Export to BBS packages' text/menu folders with the right file names | planned | screen designer |
| Caller preview at chosen baud with the terminal renderer | planned | screen designer |
| "Use immediately in the BBS" | not possible as stated: AnsiView is not a BBS host. Closest: export directly into a configured BBS install folder (local or mounted), and upload via the terminal's file transfers | screen designer |

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
| SSH (password and key, host key trust on first use) | done (merged) (local NIO SSH test server: password, empty password, Ed25519 key with passphrase, first use and changed key). Limit: swift-nio-ssh has no DH key exchange, RSA host keys, CTR ciphers or keyboard interactive, so Synchronet, cryptlib and RSA-only ENiGMA boards cannot connect (measured by read only probes); needs owner decision |
| WebSocket (ws and wss) | done (merged) (local server: binary and text frames, subprotocol, telnet inside, HTTP 404, self signed wss error) |
| RLogin | done (merged) (local server: handshake bytes, refusal; no window size, see README) |
| Byte clean channel for transfers | done: all 256 byte values measured end to end over SSH, WebSocket and RLogin |

## Terminal dialing directory

| Requirement | Status |
|---|---|
| Retro phonebook (list, tags, search, sort, notes, call stats), per-BBS settings, Keychain passwords, expect/send auto-login, dial queue with redial and busy detection, macros, JSON and SyncTERM import/export | done (local test server; real-BBS logins need owner), merged item 63 |
| SSH keys, RLogin users, WebSocket fields, per protocol hints, SyncTERM SSH/RLogin import | done (merged) |
| IEMSI, Sixel, iTerm2 images, TLS client certificates | planned |

## 16colo.rs browsing

| Requirement | Status |
|---|---|
| Preview pane on selection (real art via AnsiView renderer, SAUCE caption, x1 fallback), pack thumbnail grid, pack row pictures, grid/list toggle in browser and galleries, 200 MB disk cache, offline mode | done (harness and live 16colo.rs; live app check needs owner), items 35-37 |

## Running right now

