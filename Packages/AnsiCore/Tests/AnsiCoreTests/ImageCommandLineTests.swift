import CoreGraphics
import Foundation
import Testing
@testable import AnsiCore

@Suite struct ImageCommandLineTests {
    @Test func parsesAllFlags() throws {
        let c = try ImageCommand.parse(["a.png", "--width", "120", "--mode", "shade", "--palette", "xbin", "--dither", "atkinson",
                                        "--strength", "40", "--extended-glyphs", "--no-ice", "--no-aspect", "--nearest",
                                        "--levels", "--brightness", "10", "--contrast", "-20", "--saturation", "30",
                                        "--gamma", "1.5", "--sharpen", "50", "--remove-background", "12",
                                        "--crop", "1,2,30,40", "b.jpg", "-o", "out"])
        let o = c.options(imageWidth: 100, imageHeight: 100)
        #expect(c.inputs == ["a.png", "b.jpg"] && c.output == "out")
        #expect(o.columns == 120 && o.mode == .shades && o.palette == .imagePalette && o.dither == .atkinson)
        #expect(o.ditherStrength == 0.4 && o.extendedGlyphs && !o.iceColors && !o.aspectCorrection && o.nearestNeighbour)
        let a = o.adjustments
        #expect(a.autoLevels && a.brightness == 0.1 && a.contrast == -0.2 && a.saturation == 0.3 && a.gamma == 1.5)
        #expect(a.sharpen == 0.5 && a.removeBackground && a.backgroundTolerance == 0.12)
        #expect(o.crop == CGRect(x: 1, y: 2, width: 30, height: 40))
    }

    @Test func removeBackgroundValueIsOptional() throws {
        let c = try ImageCommand.parse(["--remove-background", "a.png"])
        #expect(c.inputs == ["a.png"])
        let o = c.options(imageWidth: 1, imageHeight: 1)
        #expect(o.adjustments.removeBackground && o.adjustments.backgroundTolerance == ImageAdjustments().backgroundTolerance)
    }

    @Test func oldFlagsStillWork() throws {
        let c = try ImageCommand.parse(["x.gif", "--mode", "half", "--palette", "truecolor", "--dither", "fs", "--ice"])
        let o = c.options(imageWidth: 1, imageHeight: 1)
        #expect(o.mode == .halfBlocks && o.palette == .trueColor && o.dither == .floydSteinberg && o.iceColors)
        #expect(c.output == nil && c.inputs == ["x.gif"])
    }

    @Test func presetThenExplicitFlagsWin() throws {
        let c = try ImageCommand.parse(["--dither", "ordered", "--preset", "logo", "a.png"])
        #expect(c.preset == .logo)
        let o = c.options(imageWidth: 10, imageHeight: 10)
        #expect(o.mode == .glyphs && o.dither == .ordered)
        let pixel = try ImageCommand.parse(["--preset", "pixel", "a.png"]).options(imageWidth: 37, imageHeight: 10)
        #expect(pixel.columns == 37 && pixel.mode == .halfBlocks)
        #expect(try ImageCommand.parse(["--preset", "auto", "a.png"]).preset == .auto)
    }

    @Test func stdinInput() throws {
        #expect(try ImageCommand.parse(["-"]).inputs == ["-"])
    }

    @Test func badValuesThrow() {
        for args in [["--width", "0", "a"], ["--width", "1001", "a"], ["--mode", "x", "a"], ["--palette", "x", "a"],
                     ["--dither", "x", "a"], ["--strength", "101", "a"], ["--gamma", "9", "a"], ["--crop", "1,2,3", "a"],
                     ["--preset", "x", "a"], ["--bogus", "a"], [], ["--width"], ["--brightness", "-101", "a"]] {
            #expect(throws: ImageCommand.ParseError.self, "\(args)") { try ImageCommand.parse(args) }
        }
    }

    @Test func batchSkipsNonImagesAndAvoidsClashes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imgbatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["b.png", "a.png", "a.jpg", "notes.txt", "c.GIF"] {
            try Data([0]).write(to: dir.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let expanded = ImageBatch.expand([dir])
        #expect(expanded.images.map(\.lastPathComponent) == ["a.jpg", "a.png", "b.png", "c.GIF"])
        #expect(expanded.skipped.map(\.lastPathComponent) == ["notes.txt"])
        let out = URL(fileURLWithPath: "/tmp/out")
        let plan = ImageBatch.plan(expanded.images, outputFolder: out, fileExtension: "ans", existing: ["b.ans"])
        #expect(plan.map(\.output.lastPathComponent) == ["a.ans", "a 2.ans", "b 2.ans", "c.ans"])
        #expect(plan.allSatisfy { $0.output.deletingLastPathComponent().path == "/tmp/out" })
    }

    @Test func isImageByExtension() {
        #expect(ImageBatch.isImage(URL(fileURLWithPath: "/x/a.PNG")))
        #expect(ImageBatch.isImage(URL(fileURLWithPath: "/x/a.jpeg")))
        #expect(!ImageBatch.isImage(URL(fileURLWithPath: "/x/a.ans")))
        #expect(!ImageBatch.isImage(URL(fileURLWithPath: "/x/a")))
    }
}
