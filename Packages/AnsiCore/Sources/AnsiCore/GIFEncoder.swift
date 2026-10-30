import Foundation

/// A bitmap of palette indexes, top row first.
public struct IndexedImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

extension AnsiRenderer {
    /// Draws a screen as palette indexes, like `render` but for GIF. Colours missing from the
    /// palette take the nearest entry. At most 256 palette entries are used.
    public static func renderIndexed(_ screen: AnsiScreen, options: RenderOptions, palette: [RGB]) -> IndexedImage? {
        guard !palette.isEmpty else { return nil }
        let cellWidth = options.font.width + (options.ninePixel ? 1 : 0)
        let artWidth = screen.columns * cellWidth
        let artHeight = max(1, screen.rows.count) * options.font.height
        // The same limits as `render`, so both give the same size.
        var scale = max(1, options.scale)
        while scale > 1, artWidth * scale * artHeight * scale * 4 > maxImageBytes { scale -= 1 }
        let rowsThatFit = max(1, maxImageBytes / (4 * artWidth * options.font.height))
        let rowCount = min(max(1, screen.rows.count), rowsThatFit)
        let masks = GlyphMasks.shared(font: options.font, ninePixel: options.ninePixel, scale: scale)
        let cw = masks.cellWidth * scale
        let ch = options.font.height * scale
        let width = screen.columns * cw
        let height = rowCount * ch

        var lookup: [RGB: UInt8] = [:]
        for (index, color) in palette.prefix(256).enumerated() where lookup[color] == nil { lookup[color] = UInt8(index) }
        func index(_ color: RGB) -> UInt8 {
            if let found = lookup[color] { return found }
            let nearest = GIFColors.nearest(color, in: palette)
            lookup[color] = nearest
            return nearest
        }

        var pixels = [UInt8](repeating: index(Palette.vga[0]), count: width * height)
        pixels.withUnsafeMutableBufferPointer { out in
            for (rowIndex, row) in screen.rows.prefix(rowCount).enumerated() {
                for (colIndex, cell) in row.enumerated() where colIndex < screen.columns {
                    let hidden = cell.blink && !options.blinkVisible
                    let mask = hidden ? masks.mask(for: 0x20)
                        : cell.scalar.map { masks.mask(for: $0) } ?? masks.mask(for: cell.code)
                    let fg = index(cell.fg), bg = index(cell.bg)
                    let originX = colIndex * cw, originY = rowIndex * ch
                    for py in 0..<ch {
                        let rowStart = (originY + py) * width + originX
                        let maskStart = py * cw
                        for px in 0..<cw { out[rowStart + px] = mask[maskStart + px] ? fg : bg }
                    }
                }
            }
        }
        return IndexedImage(width: width, height: height, pixels: pixels)
    }
}

/// How an exported GIF chooses its colours.
public enum GIFPalette: String, CaseIterable {
    /// The art's exact colours (the 16 VGA colours for classic art) when there are at most 255.
    case automatic
    /// Always the 16 VGA colours; other colours become the nearest.
    case vga16
    /// The system (ImageIO) encoder's own colour reduction.
    case system

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .vga16: return "VGA 16 Colours"
        case .system: return "System"
        }
    }
}

public enum GIFColors {
    /// The palette for frames of these screens, or nil when the system encoder should be used.
    public static func palette(for screens: [AnsiScreen], mode: GIFPalette) -> [RGB]? {
        switch mode {
        case .system: return nil
        case .vga16: return Palette.vga
        case .automatic:
            // Every colour in use, in first seen order (black is always the canvas).
            var used: [RGB] = [Palette.vga[0]]
            var seen: Set<RGB> = [Palette.vga[0]]
            for screen in screens {
                for row in screen.rows {
                    for cell in row {
                        for color in [cell.fg, cell.bg] where !seen.contains(color) {
                            seen.insert(color)
                            used.append(color)
                            if used.count > 255 { return nil }
                        }
                    }
                }
            }
            let extra = used.filter { !Palette.vga.contains($0) }
            if Palette.vga.count + extra.count <= 255 { return Palette.vga + extra }
            return used
        }
    }

    /// The index of the palette entry nearest to `color`.
    public static func nearest(_ color: RGB, in palette: [RGB]) -> UInt8 {
        var best = 0, bestDistance = Int.max
        for (index, entry) in palette.prefix(256).enumerated() {
            let distance = TextConvert.squaredDistance(entry, color)
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        return UInt8(best)
    }
}

/// Writes a looping GIF89a with one global palette. Each frame stores only the rectangle that
/// changed; unchanged pixels inside it become transparent when that is smaller. Identical
/// consecutive frames merge into one longer frame.
public struct GIFEncoder {
    public let width: Int
    public let height: Int
    private let palette: [RGB]
    private let transparentIndex: UInt8
    private var output = Data()
    private var previous: IndexedImage?
    /// The last frame's image data, written once its full delay is known.
    private var pending: (blocks: Data, transparent: Bool, delay: Int)?

    /// `palette` holds at most 255 colours (one entry is kept for transparency).
    public init(width: Int, height: Int, palette: [RGB]) {
        self.width = width
        self.height = height
        self.palette = Array(palette.prefix(255))
        self.transparentIndex = UInt8(self.palette.count)
        var tableBits = 1
        while 1 << tableBits < self.palette.count + 1 { tableBits += 1 }

        output.append(contentsOf: Array("GIF89a".utf8))
        output.append(le16(width) + le16(height))
        output.append(contentsOf: [0x80 | 0x70 | UInt8(tableBits - 1), 0, 0])
        for index in 0..<(1 << tableBits) {
            let color = index < self.palette.count ? self.palette[index] : RGB(r: 0, g: 0, b: 0)
            output.append(contentsOf: [color.r, color.g, color.b])
        }
        // Loop forever.
        output.append(contentsOf: [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00])
    }

    /// Adds a frame shown for `delayHundredths` hundredths of a second.
    public mutating func add(_ image: IndexedImage, delayHundredths: Int) {
        precondition(image.width == width && image.height == height, "frame size differs")
        guard let previous else {
            pending = (descriptor(x: 0, y: 0, w: width, h: height) + lzw(image.pixels), false, delayHundredths)
            self.previous = image
            return
        }
        guard let rect = changedRect(previous, image) else {
            pending?.delay += delayHundredths
            return
        }
        flush()
        var opaque: [UInt8] = []
        var masked: [UInt8] = []
        opaque.reserveCapacity(rect.w * rect.h)
        masked.reserveCapacity(rect.w * rect.h)
        for y in rect.y..<(rect.y + rect.h) {
            let start = y * width + rect.x
            for i in start..<(start + rect.w) {
                let pixel = image.pixels[i]
                opaque.append(pixel)
                masked.append(pixel == previous.pixels[i] ? transparentIndex : pixel)
            }
        }
        let header = descriptor(x: rect.x, y: rect.y, w: rect.w, h: rect.h)
        let plain = lzw(opaque), clear = lzw(masked)
        pending = clear.count < plain.count ? (header + clear, true, delayHundredths) : (header + plain, false, delayHundredths)
        self.previous = image
    }

    /// The finished file.
    public mutating func finish() -> Data {
        flush()
        var result = output
        result.append(0x3B)
        return result
    }

    // MARK: Writing

    private mutating func flush() {
        guard let frame = pending else { return }
        let delay = min(65535, max(0, frame.delay))
        // Graphic control: disposal 1 (leave in place), optional transparency.
        output.append(contentsOf: [0x21, 0xF9, 0x04, 0x04 | (frame.transparent ? 1 : 0)])
        output.append(le16(delay))
        output.append(contentsOf: [frame.transparent ? transparentIndex : 0, 0])
        output.append(frame.blocks)
        pending = nil
    }

    private func descriptor(x: Int, y: Int, w: Int, h: Int) -> Data {
        var data = Data([0x2C])
        data.append(le16(x) + le16(y) + le16(w) + le16(h))
        data.append(0)
        return data
    }

    private func le16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }

    private func changedRect(_ a: IndexedImage, _ b: IndexedImage) -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for y in 0..<height {
                    let row = y * width
                    var x = 0
                    while x < width {
                        if pa[row + x] != pb[row + x] {
                            minY = min(minY, y); maxY = y
                            minX = min(minX, x)
                            var last = width - 1
                            while pa[row + last] == pb[row + last] { last -= 1 }
                            maxX = max(maxX, last)
                            break
                        }
                        x += 1
                    }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// LZW image data: minimum code size, then the codes in sub-blocks of at most 255 bytes.
    private func lzw(_ pixels: [UInt8]) -> Data {
        var maxIndex = 0
        for pixel in pixels where Int(pixel) > maxIndex { maxIndex = Int(pixel) }
        var minCodeSize = 2
        while 1 << minCodeSize <= maxIndex { minCodeSize += 1 }
        let alphabet = 1 << minCodeSize
        let clearCode = alphabet, endCode = alphabet + 1

        var packed = [UInt8]()
        packed.reserveCapacity(pixels.count / 2 + 16)
        var bitBuffer = 0, bitCount = 0
        var codeSize = minCodeSize + 1
        func emit(_ code: Int) {
            bitBuffer |= code << bitCount
            bitCount += codeSize
            while bitCount >= 8 {
                packed.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }

        // children[code * alphabet + pixel] is the code for that string plus pixel, or -1.
        var children = [Int16](repeating: -1, count: 4096 * alphabet)
        var touched: [Int] = []
        touched.reserveCapacity(4096)
        var nextCode = endCode + 1
        emit(clearCode)
        if !pixels.isEmpty {
            var prefix = Int(pixels[0])
            for pixel in pixels.dropFirst() {
                let key = prefix * alphabet + Int(pixel)
                let child = children[key]
                if child >= 0 {
                    prefix = Int(child)
                    continue
                }
                emit(prefix)
                if nextCode < 4096 {
                    if nextCode == 1 << codeSize { codeSize += 1 }
                    children[key] = Int16(nextCode)
                    touched.append(key)
                    nextCode += 1
                } else {
                    emit(clearCode)
                    for k in touched { children[k] = -1 }
                    touched.removeAll(keepingCapacity: true)
                    nextCode = endCode + 1
                    codeSize = minCodeSize + 1
                }
                prefix = Int(pixel)
            }
            emit(prefix)
        }
        emit(endCode)
        if bitCount > 0 { packed.append(UInt8(bitBuffer & 0xFF)) }

        var data = Data([UInt8(minCodeSize)])
        var offset = 0
        while offset < packed.count {
            let length = min(255, packed.count - offset)
            data.append(UInt8(length))
            data.append(contentsOf: packed[offset..<(offset + length)])
            offset += length
        }
        data.append(0)
        return data
    }
}
