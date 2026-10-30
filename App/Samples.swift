import AppKit

/// The original sample art bundled in the app (`Samples` folder, made by
/// `Packaging/samples/generate.swift`), for File > Open Sample.
enum SampleArt {
    struct Sample {
        /// The file name without its extension, as the menu shows it.
        let title: String
        let url: URL
    }

    /// The bundled samples in file name order (Welcome first).
    static func all(in bundle: Bundle = .main) -> [Sample] {
        guard let folder = bundle.resourceURL?.appendingPathComponent("Samples"),
              let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let samples = files.map { Sample(title: $0.deletingPathExtension().lastPathComponent, url: $0) }
        return samples.sorted { a, b in
            if (a.title == "Welcome") != (b.title == "Welcome") { return a.title == "Welcome" }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Opens a sample as a document. The file is inside the signed app bundle, so it is read only.
    static func open(_ sample: Sample) {
        NSDocumentController.shared.openDocument(withContentsOf: sample.url, display: true) { _, _, error in
            if let error { NSAlert(error: error).runModal() }
        }
    }
}
