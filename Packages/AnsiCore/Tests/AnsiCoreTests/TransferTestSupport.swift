import Foundation
@testable import AnsiCore

/// A deterministic random source (SplitMix64) so failures reproduce.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count { out[i] = UInt8(truncatingIfNeeded: next()) }
        return out
    }
}

enum TestData {
    /// Random bytes that do not end in SUB (so plain XMODEM's padding rule cannot change them).
    static func random(_ count: Int, seed: UInt64 = 1) -> [UInt8] {
        var rng = SeededRandom(seed &+ UInt64(count))
        var data = rng.bytes(count)
        if let last = data.last, last == 0x1A { data[data.count - 1] = 0x1B }
        return data
    }

    /// Every byte value, the protocol special ones in runs, and a fake ZMODEM start inside.
    static let everyByte: [UInt8] = {
        var data = Array(0...255).map(UInt8.init)
        data += [0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x11, 0x13, 0x91, 0x93, 0xFF, 0xFF, 0xFF, 0x0D, 0x0A, 0x40, 0x0D]
        data += Array("**\u{18}B00000000000000\r\n".utf8) + [0x01, 0x23, 0x20, 0x53, 0x7E, 0x7E, 0x26, 0x23, 0x10, 0x90]
        data += Array((0...255).reversed()).map(UInt8.init)
        return data
    }()

    static let sizes = [0, 1, 127, 128, 129, 1023, 1024, 1025]
}

/// Line faults applied to one direction of a link.
struct LineFaults {
    var rng: SeededRandom
    var drop = 0.0
    var duplicate = 0.0
    var corrupt = 0.0
    var noise = 0.0
    /// Faults happen only while fewer than this many bytes have passed (so a test always ends).
    var activeBytes = Int.max
    private(set) var passed = 0
    private(set) var injected = 0

    init(seed: UInt64, drop: Double = 0, duplicate: Double = 0, corrupt: Double = 0, noise: Double = 0, activeBytes: Int = Int.max) {
        rng = SeededRandom(seed)
        self.drop = drop
        self.duplicate = duplicate
        self.corrupt = corrupt
        self.noise = noise
        self.activeBytes = activeBytes
    }

    mutating func apply(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 8)
        for byte in bytes {
            passed += 1
            guard passed < activeBytes else { out.append(byte); continue }
            let roll = Double(rng.next() % 1_000_000) / 1_000_000
            if roll < drop {
                injected += 1
                continue
            } else if roll < drop + duplicate {
                injected += 1
                out += [byte, byte]
            } else if roll < drop + duplicate + corrupt {
                injected += 1
                out.append(byte ^ UInt8(1 << (rng.next() % 8)))
            } else if roll < drop + duplicate + corrupt + noise {
                injected += 1
                out += [byte, UInt8(truncatingIfNeeded: rng.next()) | 0x20]
            } else {
                out.append(byte)
            }
        }
        return out
    }
}

struct LinkResult {
    var steps = 0
    var simulatedSeconds = 0.0
    var bytesAtoB = 0
    var bytesBtoA = 0
}

/// Runs two engines against each other in process. When nothing moves, simulated time advances
/// so timeouts fire. Stops when both have finished, or one has finished and the other has been
/// idle for `drainSeconds`.
@discardableResult
func runLink(_ a: TransferEngine, _ b: TransferEngine, clock: ManualTransferClock,
             aToB: inout LineFaults?, bToA: inout LineFaults?, chunk: Int = 4096,
             maxSimulatedSeconds: Double = 3600, drainSeconds: Double = 120) -> LinkResult {
    var result = LinkResult()
    if a.status == .idle { a.start() }
    if b.status == .idle { b.start() }
    let started = clock.now
    var idleSince: Double?
    while clock.now - started < maxSimulatedSeconds {
        result.steps += 1
        var x = a.takeOutput(max: chunk)
        var y = b.takeOutput(max: chunk)
        if !x.isEmpty {
            result.bytesAtoB += x.count
            if aToB != nil { x = aToB!.apply(x) }
            b.receive(x)
        }
        if !y.isEmpty {
            result.bytesBtoA += y.count
            if bToA != nil { y = bToA!.apply(y) }
            a.receive(y)
        }
        let moved = !x.isEmpty || !y.isEmpty
        if a.status.isFinished, b.status.isFinished, a.pendingOutputCount == 0, b.pendingOutputCount == 0 { break }
        if !moved {
            if a.status.isFinished || b.status.isFinished {
                if idleSince == nil { idleSince = clock.now }
                if clock.now - idleSince! > drainSeconds { break }
            }
            clock.advance(0.25)
            a.tick()
            b.tick()
        } else {
            idleSince = nil
            clock.advance(0.0001)
            a.tick()
            b.tick()
        }
    }
    result.simulatedSeconds = clock.now - started
    return result
}

@discardableResult
func runLink(_ a: TransferEngine, _ b: TransferEngine, clock: ManualTransferClock, chunk: Int = 4096) -> LinkResult {
    var none: LineFaults?
    var none2: LineFaults?
    return runLink(a, b, clock: clock, aToB: &none, bToA: &none2, chunk: chunk)
}

func completedFiles(_ events: [TransferEvent]) -> [TransferredFile] {
    events.compactMap { if case .fileCompleted(let file) = $0 { return file } else { return nil } }
}
