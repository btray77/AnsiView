import AnsiCore
import AppKit
import SwiftUI

/// The SAUCE info sheet (File > Get Info).
struct ArtInfoView: View {
    let name: String
    let info: ArtInfo
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
            if !info.hasSauce {
                Text(ArtInfo.noSauce).foregroundStyle(.secondary)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(info.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            .help(Self.terms[row.label].map { Glossary.entry($0).hint } ?? "")
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let term = Self.terms[row.label] { GlossaryLink(term: term) }
                        }
                    }
                }
            }
            HStack {
                GlossaryLink(term: .sauce, title: String(localized: "What is SAUCE?"))
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onExitCommand(perform: close)
    }

    /// Rows whose label is jargon, by `ArtInfo` label (item 62).
    static let terms: [String: GlossaryTerm] = [
        "Font": .textModeFont, "iCE Colors": .iceColours, "Letter Spacing": .letterSpacing,
        "Aspect": .aspectRatio, "Columns": .columns,
    ]
}

/// A small (?) that opens a glossary entry; its tooltip is the entry's one line hint.
struct GlossaryLink: View {
    let term: GlossaryTerm
    var title: String?

    var body: some View {
        let entry = Glossary.entry(term)
        Button {
            GlossaryWindowController.show(term: term)
        } label: {
            if let title {
                Label(title, systemImage: "questionmark.circle")
            } else {
                Image(systemName: "questionmark.circle")
            }
        }
        .buttonStyle(.borderless)
        .help(entry.hint)
        .accessibilityLabel(Text(String(localized: "Help: \(entry.title)")))
    }
}

extension AnsiPlayerViewController {
    /// File > Get Info: a sheet with the file's SAUCE fields, format and size.
    @objc func showArtInfo(_ sender: Any?) {
        let name = fileURL?.lastPathComponent ?? source.title ?? "Untitled"
        var sheet: NSViewController?
        let host = NSHostingController(rootView: ArtInfoView(name: name, info: ArtInfo(source)) { [weak self] in
            if let shown = sheet { self?.dismiss(shown) }
            sheet = nil
        })
        sheet = host
        presentAsSheet(host)
    }
}
