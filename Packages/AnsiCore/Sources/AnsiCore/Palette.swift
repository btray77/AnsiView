/// A 24 bit color.
public struct RGB: Hashable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public enum Palette {
    /// Standard VGA text mode palette, in VGA attribute order (1 is blue, 4 is red).
    public static let vga: [RGB] = [
        (0x00, 0x00, 0x00), (0x00, 0x00, 0xAA), (0x00, 0xAA, 0x00), (0x00, 0xAA, 0xAA),
        (0xAA, 0x00, 0x00), (0xAA, 0x00, 0xAA), (0xAA, 0x55, 0x00), (0xAA, 0xAA, 0xAA),
        (0x55, 0x55, 0x55), (0x55, 0x55, 0xFF), (0x55, 0xFF, 0x55), (0x55, 0xFF, 0xFF),
        (0xFF, 0x55, 0x55), (0xFF, 0x55, 0xFF), (0xFF, 0xFF, 0x55), (0xFF, 0xFF, 0xFF),
    ].map { RGB(r: $0.0, g: $0.1, b: $0.2) }

    /// ANSI color order (black, red, green, yellow, blue, magenta, cyan, white) to VGA attribute order.
    public static let ansiToVGA = [0, 4, 2, 6, 1, 5, 3, 7]

    /// The xterm 256 color palette: 16 classic colors (shown with the VGA values),
    /// a 6x6x6 color cube, and 24 greys.
    public static let xterm256: [RGB] = {
        var colors: [RGB] = (0..<16).map { index in
            vga[ansiToVGA[index % 8] + (index >= 8 ? 8 : 0)]
        }
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in levels { for g in levels { for b in levels { colors.append(RGB(r: r, g: g, b: b)) } } }
        for i in 0..<24 {
            let grey = UInt8(8 + 10 * i)
            colors.append(RGB(r: grey, g: grey, b: grey))
        }
        return colors
    }()
}
