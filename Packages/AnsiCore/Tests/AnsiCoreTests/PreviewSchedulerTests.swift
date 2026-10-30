import Foundation
import Testing
@testable import AnsiCore

/// Collects values from other threads.
private final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite struct PreviewSchedulerTests {
    @Test func debounceCoalesces() {
        let scheduler = PreviewScheduler<Int>(delay: 0.1, deliver: DispatchQueue(label: "test.deliver"))
        let runs = Collected<Int>(), delivered = Collected<Int>()
        for i in 1...5 {
            scheduler.request({ _ in runs.add(i); return i }, completion: { delivered.add($0) })
        }
        Thread.sleep(forTimeInterval: 0.6)
        #expect(runs.all == [5])
        #expect(delivered.all == [5])
    }

    @Test func staleResultsAreDropped() {
        let scheduler = PreviewScheduler<String>(delay: 0, deliver: DispatchQueue(label: "test.deliver"))
        let delivered = Collected<String>()
        scheduler.request({ _ in Thread.sleep(forTimeInterval: 0.2); return "old" }, completion: { delivered.add($0) })
        Thread.sleep(forTimeInterval: 0.05)
        scheduler.request({ _ in "new" }, completion: { delivered.add($0) })
        Thread.sleep(forTimeInterval: 0.6)
        #expect(delivered.all == ["new"])
    }

    @Test func cancelFlagSeenByOldWork() {
        let scheduler = PreviewScheduler<Bool>(delay: 0, deliver: DispatchQueue(label: "test.deliver"))
        let seen = Collected<Bool>()
        scheduler.request({ isCancelled in
            let start = Date()
            while !isCancelled(), Date().timeIntervalSince(start) < 2 { Thread.sleep(forTimeInterval: 0.005) }
            seen.add(isCancelled())
            return nil
        }, completion: { _ in })
        Thread.sleep(forTimeInterval: 0.05)
        scheduler.request({ _ in true }, completion: { _ in })
        Thread.sleep(forTimeInterval: 0.3)
        #expect(seen.all == [true])
    }

    @Test func cancelStopsDelivery() {
        let scheduler = PreviewScheduler<Int>(delay: 0.05, deliver: DispatchQueue(label: "test.deliver"))
        let delivered = Collected<Int>()
        scheduler.request({ _ in 1 }, completion: { delivered.add($0) })
        scheduler.cancel()
        Thread.sleep(forTimeInterval: 0.3)
        #expect(delivered.all.isEmpty)
    }
}

@Suite struct ImageImportHelpTests {
    @Test func everySettingHasTooltip() {
        for id in ImageImportHelp.settingIDs {
            #expect(!(ImageImportHelp.tooltips[id] ?? "").isEmpty, "\(id)")
        }
        for id in ["ice", "dither", "oklab", "xbin", "glyph", "aspect"] {
            let entry = ImageImportHelp.explanations[id]
            #expect(entry != nil && !entry!.title.isEmpty && entry!.text.count > 40, "\(id)")
        }
    }

    @Test func noEmDashes() {
        let all = Array(ImageImportHelp.tooltips.values) + ImageImportHelp.explanations.values.flatMap { [$0.title, $0.text] }
            + ImageToAnsi.Mode.allCases.map(\.label) + ImageToAnsi.Dither.allCases.map(\.label)
            + ImageToAnsi.PaletteChoice.allCases.map(\.label) + ImagePreset.allCases.map(\.label)
        #expect(all.allSatisfy { !$0.contains("\u{2014}") })
    }
}
