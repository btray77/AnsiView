import Foundation

/// An error diffusion kernel (image import ruling 5): where a pixel's quantisation error goes.
struct DitherKernel: Equatable {
    struct Tap: Equatable {
        let dx: Int
        let dy: Int
        let weight: Float
    }

    let taps: [Tap]
    /// Odd rows run right to left with the kernel mirrored, which avoids diagonal "worms".
    let serpentine: Bool

    static func kernel(for dither: ImageToAnsi.Dither) -> DitherKernel? {
        switch dither {
        case .none, .ordered:
            return nil
        case .floydSteinberg, .serpentine:
            return DitherKernel(taps: [Tap(dx: 1, dy: 0, weight: 7 / 16), Tap(dx: -1, dy: 1, weight: 3 / 16),
                                       Tap(dx: 0, dy: 1, weight: 5 / 16), Tap(dx: 1, dy: 1, weight: 1 / 16)],
                                serpentine: dither == .serpentine)
        case .atkinson:
            // Spreads 6/8 of the error; the lost quarter keeps flat areas clean and contrast high.
            return DitherKernel(taps: [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)].map {
                Tap(dx: $0.0, dy: $0.1, weight: 1 / 8)
            }, serpentine: false)
        case .sierraLite:
            return DitherKernel(taps: [Tap(dx: 1, dy: 0, weight: 2 / 4), Tap(dx: -1, dy: 1, weight: 1 / 4),
                                       Tap(dx: 0, dy: 1, weight: 1 / 4)], serpentine: false)
        }
    }

    /// Visits every position of a `width` x `height` grid in kernel order and spreads the error
    /// `visit` returns (already scaled by strength) into `values`.
    func run(width: Int, height: Int, values: inout [SIMD3<Float>], cancel: () -> Bool,
             visit: (_ index: Int, _ value: SIMD3<Float>) -> SIMD3<Float>) -> Bool {
        for y in 0..<height {
            if cancel() { return false }
            let reverse = serpentine && y % 2 == 1
            for step in 0..<width {
                let x = reverse ? width - 1 - step : step
                let index = y * width + x
                let error = visit(index, values[index])
                if error == .zero { continue }
                for tap in taps {
                    let nx = x + (reverse ? -tap.dx : tap.dx), ny = y + tap.dy
                    guard nx >= 0, nx < width, ny < height else { continue }
                    values[ny * width + nx] += error * tap.weight
                }
            }
        }
        return true
    }
}

extension ImageToAnsi {
    static let bayer: [[Int]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

    /// Ordered dithering: a 4x4 Bayer threshold added in gamma space before quantising.
    /// `cellWidth` x `cellHeight` samples share one threshold (1 x 1: every sample has its own).
    static func applyOrdered(_ grid: inout PixelGrid, strength: Float, cellWidth: Int = 1, cellHeight: Int = 1) {
        guard strength > 0 else { return }
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                let bias = (Float(bayer[(y / cellHeight) % 4][(x / cellWidth) % 4]) / 16 - 0.5) * 0.25 * strength
                grid.srgb[y * grid.width + x] += SIMD3(repeating: bias)
            }
        }
    }
}
