import Foundation

/// Tooltips and (?) texts for the screen designer (item 6 of the task).
public enum ScreenDesignerHelp {
    public static func warning(_ kind: PreviewWarning.Kind) -> String {
        switch kind {
        case .lineTooLong:
            return "The caller's terminal is narrower than this line. The extra characters wrap onto the next row and push everything below down. Shorten the line or choose a wider terminal size."
        case .wrapAtLastColumn:
            return "A line that fills every column leaves the cursor past the edge. Terminals that wrap at once (ANSI.SYS, many DOS terminals) move to the next row there, so the line break that follows adds a blank row. Terminals with a delayed wrap (xterm style, SyncTERM, AnsiView's own terminal) do not. Leave the last column empty to be safe on every terminal."
        case .bottomRightScroll:
            return "Writing the bottom right cell makes most terminals scroll the whole screen up one row, so the top row disappears. Keep the last row one column short, or the screen one row shorter than the caller's terminal."
        case .tallerThanScreen:
            return "The screen has more rows than the caller's terminal. The top rows scroll away before the caller can read them, unless the BBS pauses. Keep menus to 23 rows for 80 x 24 callers, 24 rows for 80 x 25."
        case .unsupportedCode:
            return "This looks like a display code of another BBS package. The chosen BBS shows it as plain text. Use the code picker to insert the chosen BBS's own code."
        case .needsIce:
            return "The screen uses bright backgrounds (iCE colours). A terminal without iCE shows them as dark backgrounds that blink."
        case .notRepresentable:
            return "Some colours are not one of the 16 DOS colours. BBS colour codes can only send the 16 colours, so these cells use the nearest one."
        case .encodingUndocumented:
            return "No source found says this BBS package reads UTF-8 display files. Callers with CP437 terminals would see the UTF-8 bytes as pairs of odd characters. Export CP437 unless you know your BBS converts."
        case .noColourCodes:
            return "No source documents colour codes of this BBS package's own, so the profile's choice of package codes cannot be used. ANSI escape codes are written instead; every package listed shows ANSI files."
        case .animatedAsANSI:
            return "Animated screens are sent as ANSI cursor movements with padding for the delays. BBS colour codes cannot move the cursor, so this screen is exported with ANSI colours whatever the profile says."
        }
    }
}
