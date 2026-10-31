import Foundation

/// Tooltips and short explanations for the image import window (the owner asked for hints).
public enum ImageImportHelp {
    /// Every control in the window, by id.
    public static let settingIDs = [
        "preset", "method", "width", "palette", "dither", "strength", "ice", "aspect", "extended", "nearest",
        "levels", "brightness", "contrast", "saturation", "gamma", "sharpen", "background", "tolerance",
        "crop", "resetCrop", "view", "split", "zoomIn", "zoomOut", "zoomFit", "candidates", "save", "open", "status",
    ]

    public static let tooltips: [String: String] = [
        "preset": "A starting point for the kind of picture. Auto tries several methods and shows the three that look closest to your image.",
        "method": "How each character cell is drawn. Best character tries blocks, half blocks and shades for every cell and keeps the closest.",
        "width": "Width of the result in characters (1 to 1000). 80 fits a classic DOS screen.",
        "palette": "16 VGA colours work everywhere; Fitted makes an XBin file with its own 16 colour palette. Truecolor (24 bit ANSI) is not shown by every viewer.",
        "dither": "Mixes neighbouring colours to suggest shades the palette lacks. None gives flat, clean areas.",
        "strength": "How much dithering to apply: 0% is none, 100% is full strength.",
        "ice": "Allow bright background colours (iCE colours). Turn off for viewers that blink instead.",
        "aspect": "Keep the picture's proportions on the tall 8x16 character cell.",
        "extended": "Best character also tries line, box and dot characters (good for line art).",
        "nearest": "Scale without smoothing, so each picture pixel stays a sharp block (pixel art).",
        "levels": "Stretch the picture's darkest and lightest tones to black and white.",
        "brightness": "Lighten or darken the picture before converting.",
        "contrast": "Increase or reduce the difference between light and dark.",
        "saturation": "More or less colour. All the way left is greyscale.",
        "gamma": "Above 1 lightens the mid tones, below 1 darkens them.",
        "sharpen": "Crisper edges before converting (an unsharp mask).",
        "background": "Turn the background of a logo black: the colour around the edges is flood filled from the borders.",
        "tolerance": "How different a colour may be from the edge colour and still count as background.",
        "crop": "Drag a rectangle on the original to convert only that part.",
        "resetCrop": "Convert the whole picture again.",
        "view": "Split shows the original and the result in one frame with a divider; Side by side shows both; or show one alone.",
        "split": "Drag to move the divider between the original (left) and the result (right).",
        "zoomIn": "Zoom in (also: pinch or Command scroll). Both images zoom and pan together.",
        "zoomOut": "Zoom out.",
        "zoomFit": "Fit the whole picture in the window.",
        "candidates": "The three methods Auto found closest to your picture. Click one to use it; lower difference is better.",
        "save": "Save the result as a file without opening the editor.",
        "open": "Open the result in a new editor window to touch it up.",
        "status": "Result size in characters and bytes, how close it looks to the picture, and how long the preview took.",
    ]

    public static let explanations: [String: (title: String, text: String)] = [
        "ice": ("iCE colours",
                "Text mode normally uses the top bit of a cell's colour for blinking, which leaves only 8 dark background colours. "
                + "iCE colours reuse that bit for 8 bright backgrounds instead. Most ANSI viewers and editors support it; "
                + "a real DOS screen or an old terminal shows those cells blinking."),
        "dither": ("Dithering",
                   "With only 16 colours, a smooth gradient turns into bands. Dithering scatters nearby palette colours so that, "
                   + "from a little distance, they blend into the missing shade. Floyd-Steinberg is smooth, serpentine avoids "
                   + "diagonal streaks, Atkinson keeps more contrast and cleaner flat areas, Sierra Lite is light, ordered gives "
                   + "a regular pattern. Lower the strength if it looks noisy."),
        "oklab": ("Perceptual colour matching (OKLab)",
                  "AnsiView picks colours by how different they look to the eye, measured in the OKLab colour space, not by "
                  + "raw red, green and blue numbers. That is why a mustard yellow no longer turns brown. Hue counts double, "
                  + "so grey edges stay grey instead of picking up cyan or brown specks."),
        "xbin": ("XBin palette",
                 "Classic .ans files can only use the 16 standard VGA colours. An XBin (.xb) file stores its own 16 colour "
                 + "palette, so AnsiView can fit the 16 colours to your picture. XBin opens in AnsiView, PabloDraw, Moebius "
                 + "and most ANSI viewers, but not in a plain terminal."),
        "glyph": ("Best character",
                  "For every cell AnsiView tries the space, full block, the four half blocks and the three shades (and, if "
                  + "you allow, line and box characters) with every pair of colours, compares each with that part of the "
                  + "picture at the font's 8x16 resolution, and keeps the closest. Shades count as the colour they blend to."),
        "aspect": ("Aspect correction",
                   "A character cell is twice as tall as it is wide (8x16 pixels). Without correction a circle comes out as a "
                   + "tall oval. With half blocks each cell holds two square pixels, so the picture keeps its shape."),
        "score": ("Difference score",
                  "Auto compares each result with your picture as the eye sees it from a little distance (both blurred "
                  + "slightly, compared in OKLab). The number is the average colour difference: about 1 is barely visible, "
                  + "lower is better."),
    ]
}
