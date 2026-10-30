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
                        Text(row.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onExitCommand(perform: close)
    }
}

extension AnsiPlayerViewController {
    /// File > Get Info: a sheet with the file's SAUCE fields, format and size.
    @objc func showArtInfo(_ sender: Any?) {
        let name = fileURL?.lastPathComponent ?? source.title ?? "Untitled"
        var sheet: NSViewController?
        let host = NSHostingController(rootView: ArtInfoView(name: name, info: ArtInfo(source)) { [weak self] in
            if let sheet { self?.dismiss(sheet) }
        })
        sheet = host
        presentAsSheet(host)
    }
}
