import Foundation

/// The OKLab perceptual colour space (Bjorn Ottosson, 2020) and the sRGB transfer curve.
/// Image import compares colours here (distance tracks what the eye sees, so a mustard
/// yellow no longer becomes brown) and mixes light in linear RGB.
public enum OKLab {
    /// sRGB byte to linear light, 0 to 1.
    public static func linear(_ srgbByte: UInt8) -> Float { byteToLinear[Int(srgbByte)] }

    private static let byteToLinear: [Float] = (0...255).map { linear(srgb: Float($0) / 255) }

    public static func linear(srgb v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    public static func srgb(linear v: Float) -> Float {
        let c = min(1, max(0, v))
        return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
    }

    /// A gamma encoded 0 to 1 value as a byte.
    public static func byte(srgb v: Float) -> UInt8 {
        UInt8(min(255, max(0, (v * 255).rounded())))
    }

    /// Linear RGB to OKLab (x = L, y = a, z = b).
    public static func lab(linear c: SIMD3<Float>) -> SIMD3<Float> {
        let l = cbrtf(max(0, 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z))
        let m = cbrtf(max(0, 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z))
        let s = cbrtf(max(0, 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z))
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLab back to linear RGB (may fall outside 0 to 1 for colours outside sRGB).
    public static func linearRGB(lab c: SIMD3<Float>) -> SIMD3<Float> {
        let l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z
        let m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z
        let s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return SIMD3(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                     -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                     -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }

    public static func linear(_ color: RGB) -> SIMD3<Float> {
        SIMD3(linear(color.r), linear(color.g), linear(color.b))
    }

    public static func lab(_ color: RGB) -> SIMD3<Float> { lab(linear: linear(color)) }

    /// Linear RGB to sRGB bytes, clamped.
    public static func rgb(linear c: SIMD3<Float>) -> RGB {
        RGB(r: byte(srgb: srgb(linear: c.x)), g: byte(srgb: srgb(linear: c.y)), b: byte(srgb: srgb(linear: c.z)))
    }

    /// How much more a hue or colourfulness error counts than a lightness error when choosing
    /// palette colours. With only 16 colours and four greys, plain OKLab often trades hue for
    /// lightness (a mid grey becoming cyan, skin becoming grey); weighting a and b keeps hues.
    /// Measured on the generated test images (image import plan, Task 10): 2 removes the cyan and
    /// brown specks on grey anti-aliasing at almost no cost in delta E.
    static let chromaWeight: Float = 2

    /// OKLab with a and b scaled by `chromaWeight`: the space colour matching measures in.
    public static func match(linear c: SIMD3<Float>) -> SIMD3<Float> {
        var v = lab(linear: c)
        v.y *= chromaWeight
        v.z *= chromaWeight
        return v
    }

    /// The 16 VGA colours in OKLab.
    public static let vga: [SIMD3<Float>] = Palette.vga.map { lab($0) }

    /// The palette entry in `allowed` closest to `c` (squared OKLab distance; ties keep the lower index).
    public static func nearest(_ c: SIMD3<Float>, in palette: [SIMD3<Float>], allowed: ClosedRange<Int>) -> Int {
        var best = allowed.lowerBound
        var bestDistance = Float.greatestFiniteMagnitude
        for index in allowed where index < palette.count {
            let d = c - palette[index]
            let distance = (d * d).sum()
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        return best
    }
}
