# Fonts

## Bundled

| SAUCE name | File | Source | License |
| --- | --- | --- | --- |
| IBM VGA | Px437_IBM_VGA_8x16.ttf | Oldschool PC Font Pack v2.2 by VileR, https://int10h.org/oldschool-pc-fonts/ | CC BY-SA 4.0 |
| IBM EGA | Px437_IBM_EGA_8x14.ttf | same pack | CC BY-SA 4.0 |
| IBM VGA50, IBM EGA43 | Px437_IBM_EGA_8x8.ttf | same pack (it has no VGA 8x8; the VGA 8x8 ROM glyphs are the same set) | CC BY-SA 4.0 |

Pack download: `oldschool_pc_font_pack_v2.2_FULL.zip`, SHA-256
`21b3c0a3770ef0afc46564760613d7b078f4fcc9ed93db4b829a440b68822e08`. The pack's full license text
ships beside the fonts as `LICENSE-OldschoolPCFontPack.txt`.

File SHA-256:

```
c16cf00ae5f0d3b206bdf9d2b4fb360248f768aee4ddb3ef3106a7d5bcd06f00  Px437_IBM_EGA_8x14.ttf
09c8e0a4bc82507dec55bbcc215ec7dc0388f565432ac81cab079cd0345cb6d0  Px437_IBM_EGA_8x8.ttf
56ccd98628e0539e4d8086d3ff4ecd6dbf513635558ceef0692e4277169ec2cc  Px437_IBM_VGA_8x16.ttf
```

Code page suffixes in SAUCE names ("IBM VGA 437") are accepted. Any other name renders with IBM VGA.

## Not bundled (owner decision needed)

| Faces | Candidate | License found | Why not bundled |
| --- | --- | --- | --- |
| Amiga Topaz 1, Topaz 1+, Topaz 2, Topaz 2+, P0T-NOoDLE, MicroKnight, MicroKnight+, mO'sOul | github.com/rewtnull/amigafonts (dMG/t!s^dS!) | GPL with font exception; README states "Topaz is (c) AmigaInc." | GPL is outside the accepted set (CC BY, CC BY-SA, OFL, public domain) and conflicts with App Store terms |
| C64 PETSCII shifted and unshifted, Atari ATASCII | Kreative Software PetMe / Atari fonts (kreativekorp.com) | Kreative "Free Use License": redistribution allowed free of charge with the licence included, no modification, no selling copies, Kreative may change it at any time; whether a paid app bundle counts as selling is not stated | Unclear for a paid app; replaced by original fonts (below) |

Until a decision is made these SAUCE names render with IBM VGA.

## Terminal platform fonts (original, bundled)

The BBS terminal's home computer types draw with fonts made for AnsiView in code
(`PlatformFonts.swift`, `GlyphsBase.swift`): an original 5x8 alphabet drawn for AnsiView, placed in
8x8 cells (strokes doubled for the thick looks), with block, line and card suit graphics built from
geometry. No ROM dump or third party font was copied or traced. MIT like the rest of AnsiView.

| Font | Coverage | Used by |
|---|---|---|
| AnsiView PETSCII | 512 glyphs: C64 screen codes 0-127 of the upper case/graphics set and of the lower/upper case set (reverse video is drawn by swapping colours), then the same 256 with the bottom row lit for the C128's underline | PETSCII (C64), PETSCII (C128 80 col) |
| AnsiView ATASCII | 128 glyphs: ATASCII 0-127 with its graphics (inverse by colour swap) | ATASCII |
| AnsiView Teletext | 672 glyphs in 12x20 cells: the UK teletext set as 5x9 characters doubled with SAA5050 style diagonal rounding (an algorithm, implemented here), 64 contiguous and 64 separated mosaics, and top and bottom halves of every glyph for double height | Viewdata, Mode 7 |
| AnsiView Apple II | 160 glyphs: 128 single stroke characters and 32 MouseText pictures drawn from their descriptions (`MouseText.swift`) | Apple II, RIPscrip font 0 |
| AnsiView Topaz | 256 glyphs, ISO 8859-1 with generated accents | Amiga ANSI |

### Candidates researched for the terminal (2026-10-30) and why none was bundled

| Candidate | Licence found | Decision |
|---|---|---|
| Kreative Pet Me family, Candy Antics (Atari), Print Char 21 / PR Number 3 (Apple II) | Kreative Free Use License (summary above; full text could not be fetched verbatim, HTTP 406) | not bundled: no modification, may change any time, paid bundle unclear |
| Style64 C64 Pro / C64 Pro Mono | "MAY include ... as part of a software package but ONLY if said software package is freely provided"; no selling; commercial licence negotiable (https://style64.org/c64-truetype/license) | not bundled: AnsiView may be sold |
| Atari Classic (Mark Simonson) | copyrighted freeware, not to be bundled with paid software without permission | not bundled |
| EightBit-Atari-Fonts (Steve Boswell) | SIL OFL 1.1, but "generated from original bitmaps from Atari 8-Bit computers" | not bundled: a ROM derived bitmap (owner rule: never copy ROM dumps) |
| Bedstead (Ben Harris) | CC0 1.0 (SPDX header on bjh21.me.uk/bedstead); includes the SAA5050 designs | not bundled: clearly redistributable, but it reproduces the SAA5050 character shapes; an original 5x9 set was drawn instead. A good owner option if exact SAA5050 shapes are wanted |
| MODE7GX (galax.xyz) | free for non-commercial use only | not bundled |
| Trueschool Topaz (dMG) | GPL with font exception; "Topaz is (c) AmigaInc." | not bundled (earlier owner ruling) |
| Topaz Unicode (Screwtape) | ISC per Debian and Arch packaging; upstream LICENSE not read | not bundled: unconfirmed and a Topaz reproduction |
| BESCII, sadiec64ex | CC0 / 0BSD per search results, repositories not read | not bundled: unverified |

RIPscrip stroke fonts (fonts 1 to 10: Triplex, Small, Sans Serif, Gothic, Script, Simplex, Triplex
Script, Complex, European, Bold): one original single stroke alphabet drawn for AnsiView as point
lists (`RIPStrokeFont.swift`), styled per font (stroke weight, slant, a doubled stroke, width) and
sized from the RIPscrip 1.54 font metric tables (top, baseline and lowest pixel per font and size).
No Borland .CHR data was read or copied. The shapes are not Borland's; boards that measure text by
pixel get the spec's heights, and widths that are close (inferred, not compared with RIPterm).

Character ROMs: Cloanto states the Commodore 8-bit and Amiga ROMs are copyrighted and licensed
(https://www.c64forever.com/kb/13-122); US regulation does not protect "typeface as typeface"
(37 CFR 202.1), but the owner's rule is to copy no ROM bitmaps, so none was used.

# Text art fonts

AnsiView draws large text with TheDraw fonts (.tdf) and FIGlet fonts (.flf, and TOIlet .tlf read the
same way). Rulings in full: `docs/superpowers/plans/2026-10-30-ansiview-2.0-fonts.md`.

## Bundled

| Font | Kind | Source | License |
| --- | --- | --- | --- |
| AV Outline, AV Block, AV Ember | TheDraw outline, block, colour | Original: generated by `OriginalFonts.swift` from a pixel alphabet drawn for AnsiView | MIT (AnsiView) |
| AV Contour | FIGlet | Original: same alphabet, traced in ASCII | MIT (AnsiView) |
| banner, big, block, bubble, digital, ivrit, lean, mini, mnemonic, script, shadow, slant, small, smscript, smshadow, smslant, standard, term | FIGlet | FIGlet 2.2.5 distribution, https://github.com/cmatsuoka/figlet (unchanged files in `Resources/FIGlet`) | New BSD; `LICENSE-FIGlet.txt` beside them. FIGlet's CHANGES: license changed to New BSD "as agreed by FIGlet authors" (2.2.3); figlet is in Debian main |

`ansirender --export-original-fonts <folder>` writes the four originals as files.

## Considered and not bundled

| Fonts | Why not |
| --- | --- |
| TheDraw font collections (Roy/SAC's collection of 1,242 files, 16colo.rs packs, tdfiglet's fonts folder) | No license stated per font; users import their own |
| figlet.org contributed font database, large GitHub FIGlet collections, the fonts behind patorjk.com TAAG | Mixed or unknown licenses, font by font |
| TOIlet fonts | License not verified |

## TheDraw format (as read and written)

20 byte signature `\x13TheDraw FONTS file\x1A`; then fonts back to back, each: `55 AA 00 FF`, name
length, 12 byte name, 4 reserved bytes, type (0 outline, 1 block, 2 colour), letter spacing, block
size (16 bit little endian), 94 offsets for `!` to `~` (0xFFFF undefined), then the glyphs: width,
height, cells, CR between rows, NUL at the end. Colour fonts store a character and an attribute
(low nibble foreground, bits 4 to 6 background, bit 7 blink or bright background) per cell.
Sources: Roy/SAC, https://www.roysac.com/blog/?p=713; tdfiglet (tat3r); retrofont 0.2.2 (Markus
Krueger, MIT or Apache 2.0) for the 19 outline styles "copied from TheDraw".

Ambiguities and decisions:

- Several fonts in a file: some files pad with NUL bytes between fonts and one ends with a SAUCE
  record; NULs are skipped and anything that is not the next font marker ends the list.
- Letter spacing is used as stored (Roy/SAC writes "stored as 0x01 to 0x29"; tdfiglet and retrofont
  use the byte directly).
- `&`: before a CR or NUL it marks a descender row (not drawn); anywhere else it is a drawn `&`.
  Measured on Roy/SAC's collection: 40 drawn `&` in colour fonts (DOLCEX.TDF) that a reader treating
  every `&` as a mark would break.
- Outline cells: `A` to `Q` go through the outline style, `R` is a blank, `@` is a gap (transparent),
  `O` a blank inside the letter. AnsiView has no opaque blank character, so with Transparent on, the
  blanks inside hollow letters also show the art underneath.
- A font has no space glyph: a space is half the average glyph width, rounded up.
- Missing letters use the other case; other missing characters leave a gap and are listed.
- Caps: 64 MB per file (Roy/SAC's all-in-one TDFONTSALL.TDF is 20.8 MB), 10,000 fonts per file,
  64 rows and 255 cells per row per glyph; blocks over 65,535 bytes cannot be written.

Measured on Roy/SAC's TheDraw collection (scratchpad only, `ANSIVIEW_FONT_CORPUS` test): 1,241 of
1,242 files read (the other is an empty 20 byte set), 8,634 fonts (8,172 colour, 449 block, 13
outline), all of them identical after write and read back.

## FIGlet

Header, comments, characters 32 to 126, the seven Deutsch characters, then code tagged characters.
Horizontal layout follows figlet 2.2.5's own code (fitting, the six smushing rules, universal
smushing, no smushing of characters narrower than two columns); its reference output for default,
kerning, full width and overlap modes is part of the tests. Vertical fitting and smushing follow the
FIGfont standard's five vertical rules (figlet itself stacks lines). Right to left fonts are drawn
by reversing the text; control files (.flc) and zipped fonts are not read.
