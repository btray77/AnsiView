# Copy As Discord and Slack: colour mapping

Edit > Copy As > Discord (and the viewer's and editor's context menus) puts the selection on the
clipboard as a ` ```ansi ` code block. Discord shows only a small part of ANSI in those blocks, in
its own colours, so the art is mapped as below. Code: `Packages/AnsiCore/Sources/AnsiCore/ChatCodeBlock.swift`.

## What Discord understands

Source: the community guide "Discord ANSI colour codes" (gist kkrypt0nn/a02506f3712ff2d1c8ca7c9e0aed7c06,
read 2026-10-30). Discord documents none of this itself.

- SGR 0 (reset), 1 (bold), 4 (underline), 30 to 37 (text), 40 to 47 (background). Nothing else:
  no 24 bit or 256 colour codes, no blink, no "bold off" (AnsiView resets with 0 and sets the rest again).
- The escape must be the real ESC character (AnsiView writes it).
- Discord's phone apps show the block without any colour.
- One message holds 2,000 characters (4,000 with Nitro). Colour codes count. AnsiView warns after
  copying when the block is longer.

## Mapping

Each cell's colour is first taken to the nearest of the 16 VGA colours (24 bit and 256 colour art
included). Then:

| VGA colour (index) | Text code | Background code | Discord text colour (guide) | Discord background (guide) |
|---|---|---|---|---|
| Black (0), Dark grey (8) | 30, bold 30 | none (Discord's own) | grey #4e5058 | none |
| Blue (1), Light blue (9) | 34, bold 34 | 44 | blue #268bd2 | #839496 |
| Green (2), Light green (10) | 32, bold 32 | 42 | green #859900 | #586e75 |
| Cyan (3), Light cyan (11) | 36, bold 36 | 46 | cyan #2aa198 | #93a1a1 |
| Red (4), Light red (12) | 31, bold 31 | 41 | red #dc322f | #cb4b16 |
| Magenta (5), Light magenta (13) | 35, bold 35 | 45 | pink #d33682 | #6c71c4 |
| Brown (6), Yellow (14) | 33, bold 33 | 43 | yellow #b58900 | #657b83 |
| Light grey (7) | none (Discord's own text colour) | 47 | Discord's text colour | #fdf6e3 |
| White (15) | bold 37 | 47 | white #ffffff | #fdf6e3 |

Bright VGA colours (8 to 15) are sent as bold: Discord has no bright colours. Bright (iCE)
backgrounds use the same code as their dark half. Spaces carry only a background. Codes are written
only where the colour changes, each line ends with a reset, and trailing blanks and blank lines are
dropped. A backtick in the art becomes U+02CB so the art cannot end the code block early.

Discord's background colours are a Solarized style set, not VGA, so backgrounds look quite
different from the art (red is orange, blue is grey blue). That is Discord's palette; no mapping
can do better with 8 codes.

## Slack

Slack's formatting help (slack.com/help/articles/202288908) documents code blocks with no colour
or ANSI support (inferred from the documentation: nothing there mentions colour, and escape codes
show as text). Copy As > Slack therefore writes a plain ` ``` ` block of the art's characters
(CP437 mapped to Unicode) with no escape codes.
