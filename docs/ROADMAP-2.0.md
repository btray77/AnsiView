# AnsiView 2.0 Specification

AnsiView 2.0 ships all 34 items below in a single release. Decided with the owner on 2026-10-30:
one big 2.0 release (no intermediate public releases); authentic fonts are bundled from CC BY-SA
licensed packs with credit, while AnsiView's own code stays MIT.

## Project-wide requirements

- macOS 14.0 or later (universal arm64 + x86_64). The iOS/iPadOS app targets iOS 17.0 or later.
- App and every extension stay sandboxed. Network access is added only for items 31 and 32.
- No em-dash characters anywhere in code, UI text, docs or commit messages.
- Every bundled third party asset is credited in README "Credits", the About window, and
  `Credits.md`, with its license. Font files keep their own license (CC BY-SA 4.0 for the
  Oldschool PC Font Pack); AnsiView code stays MIT.
- Nothing from Trade Wars 2002 or other copyrighted art ships in the app or repo; bundled
  samples are original.
- MARKETING_VERSION is 2.0.0 for the release; CURRENT_PROJECT_VERSION increments with every merged task.
- The Quick Look extension must keep working after every task (`./install.sh` then space in Finder).

## Items

### Rendering accuracy (plan 1)
1. Real IBM VGA 8x16 bitmap font instead of Menlo.
2. Amiga (Topaz, MicroKnight, P0T-NOoDLE, mOsOul), C64 PETSCII and Atari ATASCII fonts, selected
   from the SAUCE font name.
3. 9 pixel wide character mode (SAUCE letter spacing flag) and legacy CRT pixel aspect.
4. 256 color (xterm 38;5 / 48;5) and 24 bit color (38;2 / 48;2 and PabloDraw `ESC[...t`).
5. UTF-8 art detection and rendering.
6. Binary formats: BIN, XBin, ADF, IDF, PCBoard @X codes, Wildcat @XX@ codes, Avatar.
7. Optional CRT look: scanlines, phosphor glow, curvature.

### Playback (plan 2)
8. Timeline scrub bar with frame stepping.
9. Remember playback speed per file.
10. Optional synthesized modem sounds (dial and handshake, line noise), off by default.
11. Terminal style scrolling during playback for tall art.
12. Hold on the final frame of an animation until clicked (setting).

### Viewing and Finder (plan 3)
13. Zoom presets: Fit, 1x, 2x, 3x, and integer only scaling.
14. Full screen presentation mode, menus and cursor hidden.
15. SAUCE info panel: title, author, group, date, comments, font, flags.
16. Folder slideshow with arrow keys.
17. Gallery window of thumbnails for a folder or art pack.
18. Finder thumbnails (Quick Look thumbnail extension).
19. Spotlight indexing of SAUCE fields and the art's text.

### Export and conversion (plan 4)
20. Batch export a folder.
21. Export controls: frame rate, GIF palette optimisation, size limits.
22. Export as HTML (colored text).
23. Convert to modern ANSI for terminals and to plain CP437 text.
24. Share sheet for exports.

### Distribution, samples, accessibility, integrations (plan 5)
28. `ansirender` command line tool shipped as a Homebrew formula.
29. Sparkle auto update for the direct download build.
30. Original bundled sample art and an Open Sample menu.
31. Browse and open art packs from 16colo.rs.
33. Open in PabloDraw / Moebius handoff.
34. VoiceOver reads the art's text content.

### Creation (plan 6)
25. Simple ANSI editor (blocks, colors, TheDraw style).
26. Convert images to block character ANSI art.

### Online (plan 7)
32. Telnet BBS terminal using the AnsiView renderer.

### iOS and iPadOS (plan 8)
27. iPhone and iPad app with a Files app Quick Look preview, reusing the core.

### Browsing, viewing and collections (plan 9)
Added 2026-10-30 at the owner's request. Status: 35 to 37 merged (16colo.rs previews plan); 38 to 47
built on branch `ansiview-2.0-plan-9` (see `docs/superpowers/plans/2026-10-30-ansiview-2.0-plan-9-browsing.md`).
35. Thumbnail grid in the 16colo.rs browser: each pack shows a grid of its files using the `tn` previews the API already lists (`/pack/<p>/tn/<f>.png`, 160 px wide), so art is seen without opening it. Click enlarges (using `x1`); opening is a separate action. Previews are cached on disk and fetched with the existing 1 s request spacing.
36. Pack list rows show the pack's first preview image.
37. Grid / list toggle in both the 16colo.rs browser and local galleries.
38. Search text inside art across a file, folder or pack.
39. Side by side compare of two pieces, with differing cells highlighted.
40. Smooth auto scroll mode for tall art at adjustable speed.
41. Minimap strip for tall art to jump anywhere.
42. Load custom palette files and switch palettes live while viewing.
43. Library: user tags, favourites, star ratings and smart folders.
44. Artist and group pages built from SAUCE data (local files, plus 16colo.rs where available).
45. Duplicate finder across folders and packs.
46. Show a pack's FILE_ID.DIZ and NFO automatically when opening it.
47. Background indexing and thumbnailing of very large packs and folders.

### Output, system integration and formats (plan 10)
48. macOS screensaver that plays a folder of art, including animation.
49. Desktop wallpaper export at the screen's exact resolution (centred or tiled).
50. Copy as a Discord / Slack ANSI colour code block.
51. MP4 export with the modem sound in sync with playback.
52. Text art generator: type words, get block letter art in original font styles.
53. Shortcuts and AppleScript actions (render to image, convert to text).
54. Finder Quick Actions: convert to PNG or GIF without opening the app.
55. Menu bar "art of the day" from the library or 16colo.rs.
56. Localization infrastructure, with string catalogs ready for translation.
57. RIPscrip viewing.
58. Sixel and Kitty graphics output from `ansirender` for modern terminals.
