import Testing
@testable import AnsiCore

@Suite struct BoxDrawingTests {
    private func code(_ c: Character) -> UInt8 { CP437.code(for: c.unicodeScalars.first!)! }
    private func row(_ canvas: EditCanvas, _ y: Int, _ x0: Int, _ x1: Int) -> String {
        String((x0...x1).map { Character(CP437.unicode[Int(canvas[$0, y].code)]) })
    }

    @Test func everyBoxCodeRoundTrips() {
        for value in 0xB3...0xDA {
            let c = UInt8(value)
            let join = BoxJoin(code: c)
            #expect(join != nil, "no join for \(value)")
            #expect(join.flatMap(BoxDrawing.code(for:)) == c, "code \(value) does not round trip")
        }
        // Nothing outside the range is a box character.
        for value in 0...255 where !(0xB3...0xDA).contains(value) {
            #expect(BoxJoin(code: UInt8(value)) == nil)
        }
    }

    @Test func everyJoinMapsToABoxCodeOrNothing() {
        let weights: [BoxWeight] = [.none, .single, .double]
        var count = 0
        for u in weights { for d in weights { for l in weights { for r in weights {
            let join = BoxJoin(up: u, down: d, left: l, right: r)
            count += 1
            if join.isEmpty {
                #expect(BoxDrawing.code(for: join) == nil)
            } else {
                let c = BoxDrawing.code(for: join)
                #expect(c != nil && (0xB3...0xDA).contains(Int(c!)))
            }
        }}}}
        #expect(count == 81)
    }

    @Test func mixedJunctionsAreExact() {
        let cases: [(BoxJoin, Character)] = [
            (BoxJoin(up: .double, down: .double, left: .single, right: .single), "╫"),
            (BoxJoin(up: .single, down: .single, left: .double, right: .double), "╪"),
            (BoxJoin(up: .single, down: .single, right: .double), "╞"),
            (BoxJoin(up: .single, down: .single, left: .double), "╡"),
            (BoxJoin(down: .double, left: .single, right: .single), "╥"),
            (BoxJoin(up: .double, left: .single, right: .single), "╨"),
            (BoxJoin(down: .single, right: .double), "╒"),
            (BoxJoin(down: .double, right: .single), "╓"),
            (BoxJoin(up: .single, left: .double, right: .double), "╧"),
            (BoxJoin(down: .single, left: .double, right: .double), "╤"),
        ]
        for (join, expected) in cases { #expect(BoxDrawing.code(for: join) == code(expected)) }
    }

    @Test func lineEndsUseStraightCharacters() {
        #expect(BoxDrawing.code(for: BoxJoin(left: .single)) == code("─"))
        #expect(BoxDrawing.code(for: BoxJoin(right: .double)) == code("═"))
        #expect(BoxDrawing.code(for: BoxJoin(up: .single)) == code("│"))
        #expect(BoxDrawing.code(for: BoxJoin(down: .double)) == code("║"))
    }

    @Test func impossibleMixesFindNearest() {
        // Single up with double down has no character: nearest is a vertical line.
        let c = BoxDrawing.code(for: BoxJoin(up: .single, down: .double))
        #expect(c == code("│") || c == code("║"))
        // Single left and double right keeps the horizontal: some horizontal line.
        let h = BoxDrawing.code(for: BoxJoin(left: .single, right: .double))
        #expect(h == code("─") || h == code("═"))
    }

    @Test func drawLinesInAllStyles() {
        let expected: [(LineStyle, String, String)] = [
            (.single, "─", "│"), (.double, "═", "║"), (.singleHDoubleV, "─", "║"), (.doubleHSingleV, "═", "│"),
        ]
        for (style, h, v) in expected {
            var canvas = EditCanvas(columns: 10, height: 10)
            canvas.drawLine(path: (0...4).map { ($0, 0) }, style: style, fg: Palette.vga[14], bg: Palette.vga[1])
            #expect(row(canvas, 0, 0, 4) == String(repeating: h, count: 5))
            #expect(canvas[2, 0].fg == Palette.vga[14] && canvas[2, 0].bg == Palette.vga[1])
            canvas.drawLine(path: (2...6).map { (8, $0) }, style: style, fg: Palette.vga[7], bg: Palette.vga[0])
            #expect(String(Character(CP437.unicode[Int(canvas[8, 4].code)])) == v)
        }
    }

    @Test func cornerAndCrossJoin() {
        var canvas = EditCanvas(columns: 10, height: 10)
        // Right then down makes a ┐ at the turn.
        canvas.drawLine(path: [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2)], style: .single, fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(canvas[2, 0].code == code("┐"))
        // A horizontal line across the vertical makes a cross.
        canvas.drawLine(path: [(1, 1), (2, 1), (3, 1)], style: .single, fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(canvas[2, 1].code == code("┼"))
        // A double line across a single makes ╪ (double horizontal).
        var other = EditCanvas(columns: 10, height: 10)
        other.drawLine(path: [(2, 0), (2, 1), (2, 2)], style: .single, fg: Palette.vga[7], bg: Palette.vga[0])
        other.drawLine(path: [(1, 1), (2, 1), (3, 1)], style: .double, fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(other[2, 1].code == code("╪"))
        // A tee.
        other.drawLine(path: [(5, 0), (5, 1), (5, 2)], style: .double, fg: Palette.vga[7], bg: Palette.vga[0])
        other.drawLine(path: [(5, 1), (6, 1)], style: .single, fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(other[5, 1].code == code("╟"))
    }

    @Test func mergesIntoExistingCharacters() {
        var canvas = EditCanvas(columns: 10, height: 5)
        canvas.set(AnsiCell(code: code("┌")), x: 3, y: 2)
        canvas.drawLine(path: [(1, 2), (2, 2), (3, 2)], style: .single, fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(canvas[3, 2].code == code("┬"))
        // A letter in the way counts as empty and is replaced.
        canvas.set(AnsiCell(code: 0x41), x: 6, y: 2)
        canvas.drawLine(path: [(5, 2), (6, 2)], style: .single, fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(canvas[6, 2].code == code("─"))
    }

    @Test func eraseRemovesSegmentAndFixesNeighbours() {
        var canvas = EditCanvas(columns: 10, height: 10)
        canvas.drawLine(path: [(2, 0), (2, 1), (2, 2)], style: .single, fg: Palette.vga[7], bg: Palette.vga[0])
        canvas.drawLine(path: [(1, 1), (2, 1), (3, 1)], style: .single, fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(canvas[2, 1].code == code("┼"))
        // Erase the left arm: (1,1) loses everything, the cross becomes ├.
        canvas.eraseLine(path: [(1, 1), (2, 1)], fg: Palette.vga[7], bg: Palette.vga[1])
        #expect(canvas[2, 1].code == code("├"))
        #expect(canvas[1, 1].code == 0x20 && canvas[1, 1].bg == Palette.vga[1])
        // Erasing where nothing is drawn leaves other characters alone.
        canvas.set(AnsiCell(code: 0x41), x: 7, y: 7)
        canvas.eraseLine(path: [(6, 7), (7, 7)], fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(canvas[7, 7].code == 0x41)
    }

    @Test func manhattanPathGoesHorizontalFirst() {
        let path = BoxDrawing.manhattanPath(from: (1, 1), to: (3, 3))
        #expect(path.map { [$0.0, $0.1] } == [[1, 1], [2, 1], [3, 1], [3, 2], [3, 3]])
        #expect(BoxDrawing.manhattanPath(from: (2, 2), to: (2, 2)).count == 1)
    }

    @Test func linesClipAtCanvasEdges() {
        var canvas = EditCanvas(columns: 3, height: 2)
        canvas.drawLine(path: [(1, 0), (2, 0), (3, 0), (4, 0)], style: .single, fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(canvas.columns == 3)
        #expect(canvas[2, 0].code == code("─"))
        canvas.drawLine(path: [(0, -1), (0, 0)], style: .single, fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(canvas[0, 0].code == code("│"))
    }
}
