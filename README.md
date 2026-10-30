<img src="docs/icon.png" width="128" align="right" alt="AnsiView icon">

# AnsiView

View classic BBS ANSI art on your Mac. Select a `.ANS` file in Finder and press the
spacebar: AnsiView draws it the way a DOS screen did, with the VGA 16 color palette,
solid block and shade characters, and box drawing that lines up without gaps.

- **Quick Look preview.** Spacebar previews for `.ans`, `.ice`, `.diz`, `.nfo` and `.asc` files.
- **Animations play.** Files that redraw themselves replay at modem speed, from 300 baud
  to 115,200 baud or instantly. The default is 2400 baud, the speed most BBS animations
  were timed for. Click the art to skip to the end or replay.
- **Blinking text blinks**, and iCE color files (SAUCE flag or `.ice`) get bright backgrounds instead.
- **Export** the current frame as PNG, JPEG or WebP, or the whole playback as an animated
  GIF, animated WebP or MP4 video, at 1x, 2x or 3x size and any playback speed.
- **SAUCE aware.** Honors the SAUCE width and iCE color flag and hides the metadata record.

## Install

1. Download the latest `AnsiView-x.y.z.dmg` from [Releases](../../releases).
2. Drag AnsiView onto Applications.
3. Open AnsiView once. This turns on the Quick Look preview.

Requires macOS 14 or later, on Apple silicon or Intel.

## Use

| Action | How |
| --- | --- |
| Preview | Select a file in Finder and press space |
| Open in the app | Double click the file |
| Skip or replay an animation | Click the art |
| Play / pause | Space (in the app) |
| Faster / slower | Command ] and Command [ |
| Export image / animation | Command E / Shift Command E |

The playback speed you choose in the app is also used by the Quick Look preview.

## Build from source

Needs Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
./install.sh   # build, install to ~/Applications, register Quick Look
./release.sh   # signed, notarized DMG in dist/ (needs a Developer ID certificate)
```

`ansirender` is a command line build of the same renderer:

```sh
ansirender art.ans art.png
ansirender --animate gif 2400 1 art.ans art.gif
ansirender --stats *.ans
```

## Credits

WebP encoding uses [libwebp](https://chromium.googlesource.com/webm/libwebp) (BSD license)
via [libwebp-Xcode](https://github.com/SDWebImage/libwebp-Xcode).

## License

MIT. See [LICENSE](LICENSE).
