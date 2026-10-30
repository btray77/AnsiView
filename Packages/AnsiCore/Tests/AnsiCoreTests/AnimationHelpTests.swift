import Testing
@testable import AnsiCore

@Suite struct AnimationHelpTests {
    @Test func everyControlHasATooltip() {
        for id in AnimationHelp.controlIDs {
            #expect(!(AnimationHelp.tooltips[id] ?? "").isEmpty, "\(id)")
        }
        #expect(Set(AnimationHelp.tooltips.keys) == Set(AnimationHelp.controlIDs))
    }

    @Test func theThreeExplanationsExist() {
        for topic in ["onionSkin", "orders", "padding"] {
            let entry = AnimationHelp.explanations[topic]
            #expect(entry != nil && !(entry?.text.isEmpty ?? true), "\(topic)")
        }
        let padding = AnimationHelp.explanations["padding"]!.text
        #expect(padding.contains("0x0D") && padding.contains("carriage return"))
        let orders = AnimationHelp.explanations["orders"]!.text
        for order in AnimationOrder.allCases { #expect(orders.contains(order.label)) }
    }

    @Test func noEmDashes() {
        let all = AnimationHelp.tooltips.values.joined() + AnimationHelp.explanations.values.map { $0.title + $0.text }.joined()
        #expect(!all.contains("\u{2014}"))
    }
}
