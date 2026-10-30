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
| Image to ANSI | `ImageToAnsi.swift` | v1; v2 running |
| Telnet client | `Telnet.swift`, `BBSClient.swift`, `App/BBSTerminal.swift` | negotiation, NAWS, TTYPE, raw TCP |
| Playback speed / baud | `Playback.swift` | 300 to 115200 and unlimited |
| Export | PNG, JPEG, WebP, GIF, APNG, MP4, HTML, text, modern ANSI | |
| File transfers | none | |
| ANSI music | none (sequences are currently ignored by the parser) | |
| TDF fonts | none | |
| Screen designer / templates | none | |

## 1. Art editor

| Requirement | Status | Item / plan |
|---|---|---|
| CP437 full set, VGA fonts, 80 col default, configurable size | done | plan 6 |
| 16 colours, iCE | done | plan 6 |
| Character editing, keyboard and mouse | done (harness verified; live keyboard check needs owner) | plan 6 |
| Insert / overwrite / delete modes | planned | editor v2 |
| Palette management, fg/bg swap | planned | editor v2 |
| CP437 character picker | planned | editor v2 |
| Configurable drawing characters / brushes | partial: F1-F10 block sets | editor v2 |
| Freehand drawing | done (half blocks) | plan 6; character brush in editor v2 |
| Lines, rectangles, filled rectangles | planned | item 60 |
| Box drawing, single/double, auto-joining | planned | item 60 |
| Flood fill, colour replace, character replace | partial: fill selection | editor v2 |
| Text insertion | done | plan 6 |
| Select, copy, cut, paste (cells, text, ANSI, image; editor and viewer; Copy As; floating and transparent paste; paste images) | done (harness verified; live check needs owner) | copy and paste, merged 39ef769 |
| Move and resize selection | partial: move via floating paste; resize planned | editor v2 |
| Mirror, flip, rotate (with box-character remapping) | planned | editor v2 |
| Block operations | partial | editor v2 |
| Undo / redo | done | plan 6 |
| Layers (flattened on save, kept in a sidecar project file) | planned | editor v2 |
| TDF font import, preview, insert, manage collection | planned | TDF fonts |
| Other font formats (FIGlet .flf) | planned | TDF fonts |

## 2. ANSI music

| Requirement | Status | Item / plan |
|---|---|---|
| Research historical syntax (BASIC PLAY strings after `ESC[M`, `ESC[MF`/`MB`, `ESC[N`, SyncTERM `ESC[\|`, terminated by 0x0E) | planned | music |
| Parser and playback (square-wave PC speaker style synth) | planned | music |
| Playback during viewing and in the terminal | planned | music |
| Visual piano roll / timeline editor, keyboard entry | planned | music |
| Text command editing, two-way conversion | planned | music |
| Import from and embed into ANSI files, extract | planned | music |
| Reusable sequence library | planned | music |
| MIDI export as an extra (not a replacement) | planned | music |

## 3. File transfers

| Requirement | Status | Item / plan |
|---|---|---|
| XMODEM (checksum), XMODEM-CRC, XMODEM-1K | planned | transfers |
| YMODEM, YMODEM batch | planned | transfers |
| ZMODEM (with resume and auto-start detection) | planned | transfers |
| Kermit | planned | transfers |
| Progress, speed, ETA, logging, errors, cancel and cleanup | planned | transfers |
| Path traversal protection, size limits, downloads folder in sandbox | planned | transfers |
| Interop proof against independent implementations (lrzsz `sz`/`rz`, C-Kermit) | planned | transfers |
| Over telnet (with IAC escaping), raw TCP, SSH, WebSocket | planned | transports + transfers |
| Others worth considering: YMODEM-G (no-ACK streaming), ZMODEM-8k, HS/Link and BiModem (bidirectional, closed specs: not planned) | research | transfers |

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
| Frame editor, copy previous frame, onion skin, timeline | planned | item 59 |
| Record drawing sequences | planned | item 59 |
| Playback speed, baud 300 to 28800 and more | done for playback | plan 2 |
| Edit individual frames / commands | planned | item 59 |
| Import existing animated ANSI into frames | planned | item 59 |
| Export compatible sequences; timing via padding only, custom extensions labelled | planned | item 59 |

## 6. Formats

| Format | Status |
|---|---|
| .ANS .ASC .TXT .BIN .XB SAUCE | done (read and write) |
| .TDF | planned (TDF fonts) |
| .ICE .ADF .IDF .PCB, Avatar, Wildcat | read done; write planned where useful |
| Unsupported data preserved, never silently dropped (SAUCE comments, unknown SAUCE fields, trailing data) | planned audit | editor v2 |

## 7. Interface

| Requirement | Status |
|---|---|
| Toolbars, palette, zoom | done (basic) |
| Pan, grid, cursor position indicator | partial (position shown) / planned |
| Full screen editing, retro DOS preview mode | planned (editor v2) |
| Configurable keyboard shortcuts | planned (editor v2) |
| Context sensitive help, tooltips, glossary | planned (item 62) |
| Light and dark themes | system appearance today; retro theme planned |
| Font browser, character picker | planned |

## 8. Rendering consistency

| Requirement | Status |
|---|---|
| Editor, preview and terminal share one renderer and font set | done (AnsiRenderer) |
| Shared SGR handling between player and terminal | done (plan 7 TextAttributes, md5-identical renders of the corpus) |

## 9. Transports

| Transport | Status |
|---|---|
| Telnet, raw TCP | done (plan 7) |
| SSH (password and key, host key trust on first use) | planned (transports) |
| WebSocket (ws and wss) | planned (transports) |
| RLogin | planned (transports, small) |

## Terminal dialing directory

| Requirement | Status |
|---|---|
| Retro phonebook (list, tags, search, sort, notes, call stats), per-BBS settings, Keychain passwords, expect/send auto-login, dial queue with redial and busy detection, macros, JSON and SyncTERM import/export | done (local test server; real-BBS logins need owner), merged item 63 |
| IEMSI, Sixel, iTerm2 images, SSH keys, TLS certs, RLogin | planned (transports) |

## Running right now

- Editor v2: TheDraw-class tools (`ansiview-2.0-editor-tools`)
- Image import v2 with live preview (`ansiview-2.0-image-import`)
- File transfer protocol engines (`ansiview-2.0-transfers-core`)
- ANSI music engine (`ansiview-2.0-music-core`)
