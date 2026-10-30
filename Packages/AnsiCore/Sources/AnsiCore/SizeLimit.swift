import CoreGraphics

/// A limit on an exported file.
public enum SizeLimit: Equatable {
    case none
    /// At most this many bytes: scale and frame rate are lowered until the file fits.
    case maxBytes(Int)
    /// At most this many pixels wide and high.
    case maxPixels(width: Int, height: Int)
}

/// One way of exporting: pixels per font pixel (below 1 means resampled down) and frames per
/// second (0 for stills).
public struct ExportAttempt: Equatable {
    public let scale: Double
    public let fps: Double

    public init(scale: Double, fps: Double) {
        self.scale = scale
        self.fps = fps
    }
}

public enum SizeFit {
    /// Scales tried below 1x when a byte limit cannot be met at whole scales.
    public static let fractionalScales: [Double] = [0.75, 0.5, 0.25]
    /// Frame rates tried below the requested one.
    public static let fallbackFrameRates: [Double] = [10, 5]
    /// A rung is skipped when the last result scaled by pixel count predicts more than this
    /// many times the target.
    public static let hopeless = 1.25

    /// The scale for art of `artPixels` (at 1x) within `maxPixels`: the requested scale when it
    /// fits, else the largest whole scale that fits, else the exact fraction of 1x that fits.
    public static func scale(artPixels: CGSize, requestedScale: Int, maxPixels: CGSize) -> Double {
        guard artPixels.width > 0, artPixels.height > 0 else { return Double(max(1, requestedScale)) }
        func fits(_ k: Double) -> Bool {
            artPixels.width * k <= maxPixels.width && artPixels.height * k <= maxPixels.height
        }
        var k = max(1, requestedScale)
        while k >= 1 {
            if fits(Double(k)) { return Double(k) }
            k -= 1
        }
        return Double(min(maxPixels.width / artPixels.width, maxPixels.height / artPixels.height))
    }

    /// Attempts in order of quality for a byte limit: for each scale (requested down to 1, then
    /// the fractions of 1x), each frame rate from the requested one down.
    public static func ladder(requestedScale: Int, fps: Double, animated: Bool) -> [ExportAttempt] {
        let scales = stride(from: max(1, requestedScale), through: 1, by: -1).map(Double.init) + fractionalScales
        var rates: [Double] = [0]
        if animated {
            rates = [fps]
            for rate in fallbackFrameRates where rate < fps && !rates.contains(rate) { rates.append(rate) }
        }
        return scales.flatMap { scale in rates.map { ExportAttempt(scale: scale, fps: $0) } }
    }

    /// The next attempt after `attempt` produced `bytes` against `target`: the first later rung
    /// not predicted hopeless, else the last rung; nil when `attempt` was the last.
    public static func next(after attempt: ExportAttempt, bytes: Int, target: Int,
                            ladder: [ExportAttempt]) -> ExportAttempt? {
        guard let position = ladder.firstIndex(of: attempt), position + 1 < ladder.count else { return nil }
        let rest = ladder[(position + 1)...]
        for rung in rest {
            let ratio = (rung.scale / attempt.scale) * (rung.scale / attempt.scale)
            if Double(bytes) * ratio <= Double(target) * hopeless { return rung }
        }
        return rest.last
    }
}
