import AnsiCore
import SwiftUI

/// The SAUCE record and file facts, as the Mac's info panel shows them.
struct ArtInfoSheet: View {
    let item: ArtItem
    let file: ArtFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let info = ArtInfo(file)
        NavigationStack {
            List {
                Section {
                    LabeledContent(String(localized: "File"), value: item.name)
                    if !info.hasSauce {
                        Text(ArtInfo.noSauce).foregroundStyle(.secondary)
                    }
                }
                Section(info.hasSauce ? String(localized: "SAUCE") : String(localized: "Details")) {
                    ForEach(Array(info.rows.enumerated()), id: \.offset) { _, row in
                        LabeledContent(row.label) {
                            Text(row.value)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle(String(localized: "Info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
