import CryptoKit
import Foundation
import Testing
@testable import AnsiCore

/// Keeps the ANSI-BBS terminal byte for byte the same as it was before the terminal compatibility
/// work: a seeded stream of the sequences the emulator already handled, and (when it is on this
/// Mac) the TWSUPP corpus, are fed in small chunks and the resulting screens are digested. The
/// digests were recorded on main at 499f22c.
enum TerminalDigest {
    static func digest(_ t: TerminalEmulator) -> String {
        var data = Data()
        func add(_ rows: [[AnsiCell]]) {
            for row in rows {
                for cell in row {
                    data.append(contentsOf: [cell.code, cell.fg.r, cell.fg.g, cell.fg.b, cell.bg.r, cell.bg.g, cell.bg.b,
                                             cell.blink ? 1 : 0])
                    if let scalar = cell.scalar { data.append(contentsOf: Array(String(scalar).utf8)) }
                }
                data.append(0xFF)
            }
        }
        add(t.scrollback)
        add(t.grid)
        data.append(contentsOf: [UInt8(t.cursor.row & 0xFF), UInt8(t.cursor.column & 0xFF), t.cursorVisible ? 1 : 0,
                                 UInt8(t.bells & 0xFF)])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ bytes: [UInt8], chunk: Int = 7, encoding: TextEncoding = .cp437, ice: Bool = false) -> (String, [UInt8]) {
        var t = TerminalEmulator(columns: 80, rows: 25, encoding: encoding)
        t.iceColors = ice
        var replies: [UInt8] = []
        var i = 0
        while i < bytes.count {
            t.feed(Array(bytes[i..<min(bytes.count, i + chunk)]))
            replies += t.takeReplies()
            i += chunk
        }
        return (digest(t), replies)
    }

    /// A deterministic stream of text, controls and the CSI and ESC sequences the plan 7 emulator handled.
    static func seededStream(seed: UInt64, length: Int) -> [UInt8] {
        var state = seed
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        let finals = Array("ABCDEFGHJKLMPXSTdfrsumnc@`".utf8)
        var out: [UInt8] = []
        while out.count < length {
            switch pick(10) {
            case 0...3:
                for _ in 0..<(1 + pick(30)) { out.append(UInt8(0x20 + pick(0xE0))) }
            case 4:
                out.append([0x0D, 0x0A, 0x08, 0x09, 0x07, 0x0C, 0x00][pick(7)])
            case 5, 6:
                out += [0x1B, 0x5B]
                let count = pick(4)
                for p in 0..<count {
                    if p > 0 { out.append(0x3B) }
                    if pick(5) != 0 { out += Array(String(pick(60)).utf8) }
                }
                out.append(finals[pick(finals.count)])
            case 7:
                // SGR, including 256 and 24 bit colour.
                let options = ["0", "1", "5", "7", "22", "25", "27", "31", "42", "93", "104", "38;5;\(pick(256))",
                               "48;2;\(pick(256));\(pick(256));\(pick(256))", "1;34;47", "39;49"]
                out += Array("\u{1B}[\(options[pick(options.count)])m".utf8)
            case 8:
                let escapes = ["\u{1B}7", "\u{1B}8", "\u{1B}D", "\u{1B}E", "\u{1B}M", "\u{1B}[?25l", "\u{1B}[?25h",
                               "\u{1B}[?7l", "\u{1B}[?7h", "\u{1B}]0;title\u{07}", "\u{1B}[0;10;20;30t", "\u{1B}[1;200;100;50t"]
                out += Array(escapes[pick(escapes.count)].utf8)
            default:
                out += Array("\u{1B}[\(1 + pick(25));\(1 + pick(80))H".utf8)
            }
        }
        return out
    }

    /// The TWSUPP corpus folder (copyrighted, never committed), searched for above this file.
    static var corpusFolder: URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("extracted/TWSUPP")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

@Test func seededStreamsMatchPlan7Emulator() {
    let expected: [(UInt64, String)] = [
        (1, "f6a36c85af2de377a420df4b195791c46aa9143ca6d418b6150770a57c6f02a7"),
        (2, "7a1258c935270d475d9f5955e59bf02182add6dafae7d6b283cb5fe90efbdaaa"),
        (3, "21066bc4352cc40130006e368bbd736d2f43a6c0091eac5ab9e3026533a79fcc"),
    ]
    for (seed, digest) in expected {
        let stream = TerminalDigest.seededStream(seed: seed, length: 60_000)
        let (got, _) = TerminalDigest.run(stream)
        #expect(got == digest, "seed \(seed)")
    }
    let utf8 = TerminalDigest.run(TerminalDigest.seededStream(seed: 4, length: 40_000), encoding: .utf8).0
    #expect(utf8 == "406bb079fa101cb4741e2153ac6e5943b23b9ce14e67c8f86651940894adbef0")
    let ice = TerminalDigest.run(TerminalDigest.seededStream(seed: 5, length: 40_000), ice: true).0
    #expect(ice == "993570fd7f5d6b7b59444d3a975d9b09de42ecd881fa93de8bb318434367c1d2")
    let replies = TerminalDigest.run(Array("\u{1B}[5n\u{1B}[6n\u{1B}[c\u{1B}[0c\u{1B}[1c".utf8)).1
    #expect(String(decoding: replies, as: UTF8.self) == "\u{1B}[0n\u{1B}[1;1R\u{1B}[?1;0c\u{1B}[?1;0c")
}

@Test func corpusMatchesPlan7Emulator() throws {
    guard let folder = TerminalDigest.corpusFolder,
          let digests = try? String(contentsOf: try #require(Bundle.module.url(forResource: "terminal-corpus-digests", withExtension: "txt", subdirectory: "Fixtures")), encoding: .utf8)
    else { return }
    let expected = Dictionary(uniqueKeysWithValues: digests.split(separator: "\n").map { line -> (String, String) in
        let parts = line.split(separator: " ")
        return (String(parts[0]), String(parts[1]))
    })
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.uppercased().hasSuffix(".ANS") }.sorted()
    #expect(files.count == 61)
    for name in files {
        let bytes = [UInt8](try Data(contentsOf: folder.appendingPathComponent(name)))
        let got = TerminalDigest.run(bytes).0
        #expect(expected[name] == got, "\(name)")
    }
}
