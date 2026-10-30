import Foundation

/// Tooltips, status bar hints and the (?) explanations for the animation timeline (ruling 10).
public enum AnimationHelp {
    /// Every control on the timeline and in the export sheet, by id.
    public static let controlIDs = [
        "newFrame", "duplicateFrame", "deleteFrame", "previousFrame", "nextFrame", "delay", "onionSkin", "record",
        "play", "baud", "export", "import", "strip", "order", "replayPauses", "frameMarkers", "format", "sizes",
        "compatibility", "previewPlay", "previewOrder",
    ]

    public static let tooltips: [String: String] = [
        "newFrame": "New Frame: copies this frame after it, so you only draw what changes (Control-Command-N)",
        "duplicateFrame": "Duplicate Frame: an exact copy after this one, including the order it was drawn in",
        "deleteFrame": "Delete this frame (the last frame stays)",
        "previousFrame": "Edit the previous frame (Control-Command-[)",
        "nextFrame": "Edit the next frame (Control-Command-])",
        "delay": "Seconds this frame stays on screen once drawn, before the next frame starts (0 to 60)",
        "onionSkin": "Onion skin: shows the previous frame faintly over this one, so you can line up changes",
        "record": "Record: keeps the timing of your drawing, so an As drawn export replays your pauses",
        "play": "Play the animation as a caller would see it, at the chosen baud rate",
        "baud": "Modem speed for preview and export delays: lower is slower to draw and makes each delay fewer bytes",
        "export": "Export the animation as ANSI (.ans), GIF or MP4",
        "import": "Open an animated ANSI file as frames, split where the screen settles",
        "strip": "Frames: click to edit, drag to reorder, right-click to duplicate or delete",
        "order": "How each frame is written: as drawn, top down, or a full redraw",
        "replayPauses": "As drawn only: pauses recorded in record mode become delays (at most 2 seconds each)",
        "frameMarkers": "AnsiView extension (off by default): marks each frame so AnsiView can import it back exactly. Not standard ANSI",
        "format": "ANSI keeps the animation as text for BBS use; GIF and MP4 are videos of it playing at the baud rate",
        "sizes": "File size of each order for these frames, so you can pick the smallest",
        "compatibility": "Whether the file uses only standard ANSI or also an AnsiView extension",
        "previewPlay": "Play or stop the preview",
        "previewOrder": "The export order the preview plays",
    ]

    public static let explanations: [String: (title: String, text: String)] = [
        "onionSkin": ("Onion skin",
                      "Animators draw on thin paper so the previous drawing shows through. With onion skin on, the previous frame "
                      + "is drawn faintly over the frame you are editing. Cells that are the same in both frames look normal; cells "
                      + "that differ show a ghost of the previous frame, so you can see exactly what moved."),
        "orders": ("Export orders",
                   "Every frame after the first is written as only the cells that changed, with cursor positioning, so the file "
                   + "stays small and the screen updates without flicker.\n\n"
                   + "As drawn (default): the changes appear in the order you made them, like watching the artist draw.\n\n"
                   + "Top down: the changes appear row by row from the top, like a screen refresh.\n\n"
                   + "Full redraw: each frame clears the screen and is drawn whole. Biggest file and a visible flash, but it "
                   + "works even if the caller's screen was disturbed."),
        "padding": ("Delays made of padding",
                    "Plain ANSI has no command that means wait. Over a modem, though, every character takes time: at 2400 baud "
                    + "about 4 milliseconds (10 bits per character). So a delay is written as characters that change nothing "
                    + "on screen: a 1 second delay at 2400 baud is 240 of them.\n\n"
                    + "AnsiView uses the carriage return (CR, byte 0x0D). It moves the cursor to the start of the line and draws "
                    + "nothing; once the cursor is there, more of them do nothing at all. DOS ANSI.SYS, VT100 style terminals, "
                    + "SyncTERM and AnsiView all treat it this way.\n\n"
                    + "Limits: the delay only works when the file is shown at that baud rate (a real modem, a BBS that paces "
                    + "output, or a viewer that emulates the speed, like AnsiView). A viewer that shows files instantly shows no "
                    + "delays. A terminal set to add a line feed after every CR (rare, off by default) would move down. "
                    + "A delay shorter than the next frame's cursor and colour codes cannot be made; the export shows the time "
                    + "each frame really holds."),
    ]
}
